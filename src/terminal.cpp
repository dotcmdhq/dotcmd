#include "terminal.h"

#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <stdint.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <io.h>
#else
#include <unistd.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <poll.h>
#include <signal.h>
#include <time.h>
#endif
extern "C" {
#include "lua.h"
#include "lauxlib.h"
}

bool IsTerminal(FILE* file) {
#ifdef _WIN32
    int descriptor = _fileno(file);
    intptr_t native = descriptor < 0 ? -1 : _get_osfhandle(descriptor);
    HANDLE handle = native == -1 ? INVALID_HANDLE_VALUE : (HANDLE)native;
    DWORD mode;
    if (handle == INVALID_HANDLE_VALUE || !GetConsoleMode(handle, &mode)) return false;
    CONSOLE_SCREEN_BUFFER_INFO info;
    if (GetConsoleScreenBufferInfo(handle, &info)
        && !SetConsoleMode(handle, mode | ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING)) return false;
    return true;
#else
    return isatty(fileno(file));
#endif
}

static int LuaIsTerminal(lua_State* L) {
    luaL_Stream* stream = (luaL_Stream*)luaL_checkudata(L, 1, LUA_FILEHANDLE);
    luaL_argcheck(L, stream->f != NULL, 1, "closed file");
    lua_pushboolean(L, IsTerminal(stream->f));
    return 1;
}

static int OpenTerminal(lua_State* L) {
    lua_pushcfunction(L, LuaIsTerminal);
    return 1;
}

// One session owns raw mode only while the Lua editor is reading input. Its
// close metamethod restores the terminal before evaluation, including errors.
struct Console {
    bool active;
#ifdef _WIN32
    HANDLE input;
    HANDLE output;
    DWORD input_mode;
    DWORD output_mode;
    WORD repeats;
    char pending[16];
    size_t pending_size;
    WCHAR surrogate;
#else
    int input_fd;
    int output_fd;
    struct termios original;
    struct sigaction signals[4];
#endif
};

#ifndef _WIN32
static Console* active_console;
static const int console_signals[] = {SIGINT, SIGTERM, SIGHUP, SIGQUIT};

static void BlockConsoleSignals(sigset_t* previous) {
    sigset_t blocked;
    sigemptyset(&blocked);
    for (size_t i = 0; i < sizeof(console_signals) / sizeof(console_signals[0]); ++i)
        sigaddset(&blocked, console_signals[i]);
    sigprocmask(SIG_BLOCK, &blocked, previous);
}
#endif

static void CloseConsole(Console* console) {
    if (!console->active) return;
#ifndef _WIN32
    sigset_t previous;
    BlockConsoleSignals(&previous);
#endif
    console->active = false;
    const char reset[] = "\x1b[?2004l\x1b[0m";
#ifdef _WIN32
    DWORD written;
    WriteFile(console->output, reset, (DWORD)(sizeof(reset) - 1), &written, NULL);
    SetConsoleMode(console->input, console->input_mode);
    SetConsoleMode(console->output, console->output_mode);
#else
    ssize_t written = write(console->output_fd, reset, sizeof(reset) - 1);
    (void)written;
    tcsetattr(console->input_fd, TCSANOW, &console->original);
    for (size_t i = 0; i < sizeof(console_signals) / sizeof(console_signals[0]); ++i)
        sigaction(console_signals[i], &console->signals[i], NULL);
    active_console = NULL;
    sigprocmask(SIG_SETMASK, &previous, NULL);
#endif
}

#ifndef _WIN32
static void ConsoleSignal(int number) {
    if (active_console) CloseConsole(active_console);
    raise(number);
}
#endif

static int LuaConsoleClose(lua_State* L) {
    CloseConsole((Console*)luaL_checkudata(L, 1, "dotcmd.console"));
    return 0;
}

static int LuaConsoleSize(lua_State* L) {
    Console* console = (Console*)luaL_checkudata(L, 1, "dotcmd.console");
    int columns = 80, rows = 24;
#ifdef _WIN32
    CONSOLE_SCREEN_BUFFER_INFO info;
    if (GetConsoleScreenBufferInfo(console->output, &info)) {
        columns = info.srWindow.Right - info.srWindow.Left + 1;
        rows = info.srWindow.Bottom - info.srWindow.Top + 1;
    }
#else
    struct winsize size;
    if (ioctl(console->output_fd, TIOCGWINSZ, &size) == 0) {
        if (size.ws_col) columns = size.ws_col;
        if (size.ws_row) rows = size.ws_row;
    }
#endif
    lua_pushinteger(L, columns);
    lua_pushinteger(L, rows);
    return 2;
}

static int LuaConsoleMilliseconds(lua_State* L) {
#ifdef _WIN32
    uint64_t milliseconds = (uint64_t)GetTickCount64();
#else
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    uint64_t milliseconds = (uint64_t)time.tv_sec * 1000 + (uint64_t)time.tv_nsec / 1000000;
#endif
    lua_pushinteger(L, (lua_Integer)milliseconds);
    return 1;
}

static int LuaConsoleRead(lua_State* L) {
    Console* console = (Console*)luaL_checkudata(L, 1, "dotcmd.console");
    luaL_argcheck(L, console->active, 1, "closed console");
    int timeout = (int)luaL_optinteger(L, 2, -1);
#ifdef _WIN32
    if (console->repeats) {
        --console->repeats;
        lua_pushlstring(L, console->pending, console->pending_size);
        return 1;
    }
    for (;;) {
        DWORD ready = WaitForSingleObject(console->input, timeout < 0 ? INFINITE : (DWORD)timeout);
        if (ready == WAIT_TIMEOUT) { lua_pushliteral(L, ""); return 1; }
        if (ready != WAIT_OBJECT_0) return luaL_error(L, "terminal: cannot wait for input");
        INPUT_RECORD record;
        DWORD count;
        if (!ReadConsoleInputW(console->input, &record, 1, &count))
            return luaL_error(L, "terminal: cannot read input");
        if (record.EventType == WINDOW_BUFFER_SIZE_EVENT) { lua_pushliteral(L, ""); return 1; }
        if (record.EventType != KEY_EVENT || !record.Event.KeyEvent.bKeyDown) continue;
        KEY_EVENT_RECORD* key = &record.Event.KeyEvent;
        // VT input already encodes arrows, modifiers, and paste boundaries.
        WCHAR character = key->uChar.UnicodeChar;
        if (!character) continue;
        if (character >= 0xd800 && character <= 0xdbff) { console->surrogate = character; continue; }
        WCHAR text[2] = {character, 0};
        int length = 1;
        if (console->surrogate && character >= 0xdc00 && character <= 0xdfff) {
            text[0] = console->surrogate; text[1] = character; length = 2;
        }
        console->surrogate = 0;
        int bytes = WideCharToMultiByte(CP_UTF8, 0, text, length, console->pending,
            (int)sizeof(console->pending), NULL, NULL);
        if (!bytes) return luaL_error(L, "terminal: cannot encode input");
        console->pending_size = (size_t)bytes;
        console->repeats = key->wRepeatCount ? (WORD)(key->wRepeatCount - 1) : 0;
        lua_pushlstring(L, console->pending, console->pending_size);
        return 1;
    }
#else
    struct pollfd descriptor = {console->input_fd, POLLIN, 0};
    int ready;
    do { ready = poll(&descriptor, 1, timeout); } while (ready < 0 && errno == EINTR);
    if (ready < 0) return luaL_error(L, "terminal: poll: %s", strerror(errno));
    if (!ready) { lua_pushliteral(L, ""); return 1; }
    // Do not read ahead past Enter: evaluated code may read stdin itself.
    char bytes[1];
    ssize_t count;
    do { count = read(console->input_fd, bytes, sizeof(bytes)); } while (count < 0 && errno == EINTR);
    if (count < 0) return luaL_error(L, "terminal: read: %s", strerror(errno));
    if (!count) { lua_pushnil(L); return 1; }
    lua_pushlstring(L, bytes, (size_t)count);
    return 1;
#endif
}

static int LuaConsoleOpen(lua_State* L) {
    luaL_Stream* input = (luaL_Stream*)luaL_checkudata(L, 1, LUA_FILEHANDLE);
    luaL_Stream* output = (luaL_Stream*)luaL_checkudata(L, 2, LUA_FILEHANDLE);
    Console* console = (Console*)lua_newuserdatauv(L, sizeof(Console), 0);
    memset(console, 0, sizeof(*console));
    luaL_setmetatable(L, "dotcmd.console");
#ifdef _WIN32
    console->input = (HANDLE)_get_osfhandle(_fileno(input->f));
    console->output = (HANDLE)_get_osfhandle(_fileno(output->f));
    if (!GetConsoleMode(console->input, &console->input_mode)
        || !GetConsoleMode(console->output, &console->output_mode))
        return luaL_error(L, "terminal: cannot read console modes");
    DWORD mode = (console->input_mode | ENABLE_EXTENDED_FLAGS | ENABLE_WINDOW_INPUT | ENABLE_VIRTUAL_TERMINAL_INPUT)
        & ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT
            | ENABLE_QUICK_EDIT_MODE);
    if (!SetConsoleMode(console->input, mode)) return luaL_error(L, "terminal: cannot set input mode");
    console->active = true;
    if (!SetConsoleMode(console->output, console->output_mode
        | ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING)) {
        CloseConsole(console);
        return luaL_error(L, "terminal: cannot set output mode");
    }
#else
    console->input_fd = fileno(input->f); console->output_fd = fileno(output->f);
    if (tcgetattr(console->input_fd, &console->original) < 0)
        return luaL_error(L, "terminal: tcgetattr: %s", strerror(errno));
    struct termios mode = console->original;
    mode.c_iflag &= ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
    mode.c_cflag = (mode.c_cflag & ~(CSIZE | PARENB)) | CS8;
    mode.c_lflag &= ~(ECHO | ICANON | IEXTEN | ISIG);
    mode.c_cc[VMIN] = 1; mode.c_cc[VTIME] = 0;
    // A signal must not observe partially installed/restored modes or handlers.
    sigset_t previous;
    BlockConsoleSignals(&previous);
    for (size_t i = 0; i < sizeof(console_signals) / sizeof(console_signals[0]); ++i) {
        struct sigaction action = {};
        action.sa_handler = ConsoleSignal;
        sigemptyset(&action.sa_mask);
        sigaction(console_signals[i], &action, &console->signals[i]);
    }
    console->active = true;
    active_console = console;
    if (tcsetattr(console->input_fd, TCSANOW, &mode) < 0) {
        int failure = errno;
        CloseConsole(console);
        sigprocmask(SIG_SETMASK, &previous, NULL);
        return luaL_error(L, "terminal: tcsetattr: %s", strerror(failure));
    }
    sigprocmask(SIG_SETMASK, &previous, NULL);
#endif
    return 1;
}

static int OpenConsole(lua_State* L) {
    luaL_newmetatable(L, "dotcmd.console");
    lua_pushvalue(L, -1); lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, LuaConsoleClose); lua_setfield(L, -2, "__close");
    lua_pushcfunction(L, LuaConsoleClose); lua_setfield(L, -2, "__gc");
    lua_pushcfunction(L, LuaConsoleRead); lua_setfield(L, -2, "read");
    lua_pushcfunction(L, LuaConsoleSize); lua_setfield(L, -2, "size");
    lua_pushcfunction(L, LuaConsoleMilliseconds); lua_setfield(L, -2, "milliseconds");
    lua_pop(L, 1);
    lua_newtable(L);
    lua_pushcfunction(L, LuaConsoleOpen); lua_setfield(L, -2, "open");
    return 1;
}

void RegisterTerminal(lua_State* L) {
    luaL_getsubtable(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
    lua_pushcfunction(L, OpenTerminal);
    lua_setfield(L, -2, "dotcmd._terminal");
    lua_pushcfunction(L, OpenConsole);
    lua_setfield(L, -2, "dotcmd._console");
    lua_pop(L, 1);
}
