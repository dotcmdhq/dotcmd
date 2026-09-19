#include "exec.h"
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wchar.h>
typedef wchar_t NativeChar;
#else
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
extern char** environ;
typedef char NativeChar;
#endif
extern "C" {
#include "lua.h"
#include "lauxlib.h"
}

struct Buffer { char* data; size_t size; size_t capacity; };
enum Mode { Inherit, Capture, Discard, File, Merge };
struct Stream {
    Mode mode;
    NativeChar* path;
    Buffer buffer;
    int error;
#ifdef _WIN32
    HANDLE read;
    HANDLE write;
    HANDLE thread;
#else
    int read;
    int write;
#endif
};
struct Process {
    char** args;
    size_t count;
    NativeChar** env;
    NativeChar* cwd;
    Buffer command;
    Stream streams[2];
    bool check;
#ifdef _WIN32
    wchar_t* application;
    wchar_t* command_line;
    wchar_t* environment;
    HANDLE process;
    HANDLE input;
    LPPROC_THREAD_ATTRIBUTE_LIST attributes;
    bool attributes_ready;
#else
    pid_t pid;
    int error_pipe[2];
#endif
};

static bool Append(Buffer* b, const void* data, size_t size) {
    if (size > SIZE_MAX - b->size) return false;
    size_t needed = b->size + size;
    if (needed > b->capacity) {
        size_t capacity = needed <= SIZE_MAX / 2 ? needed * 2 : needed;
        void* memory = realloc(b->data, capacity);
        if (!memory) return false;
        b->data = (char*)memory;
        b->capacity = capacity;
    }
    if (size) memcpy(b->data + b->size, data, size);
    b->size = needed;
    return true;
}

#ifdef _WIN32
static void Close(HANDLE* handle) {
    if (*handle && *handle != INVALID_HANDLE_VALUE) CloseHandle(*handle);
    *handle = NULL;
}
#else
static void Close(int* fd) {
    if (*fd >= 0) close(*fd);
    *fd = -1;
}
#endif

static int Cleanup(lua_State* L) {
    Process* p = (Process*)lua_touserdata(L, 1);
#ifdef _WIN32
    if (p->process) {
        TerminateProcess(p->process, 1);
        WaitForSingleObject(p->process, INFINITE);
        Close(&p->process);
    }
    Close(&p->input);
    for (int i = 0; i < 2; ++i) {
        Stream* s = &p->streams[i];
        Close(&s->write);
        if (s->thread) {
            CancelSynchronousIo(s->thread);
            WaitForSingleObject(s->thread, INFINITE);
            Close(&s->thread);
        }
        Close(&s->read);
    }
    if (p->attributes_ready) DeleteProcThreadAttributeList(p->attributes);
    p->attributes_ready = false;
    free(p->attributes); p->attributes = NULL;
    free(p->application); p->application = NULL;
    free(p->command_line); p->command_line = NULL;
    free(p->environment); p->environment = NULL;
#else
    if (p->pid > 0) {
        kill(p->pid, SIGKILL);
        while (waitpid(p->pid, NULL, 0) < 0 && errno == EINTR) {}
        p->pid = 0;
    }
    Close(&p->error_pipe[0]);
    Close(&p->error_pipe[1]);
    for (int i = 0; i < 2; ++i) {
        Close(&p->streams[i].read);
        Close(&p->streams[i].write);
    }
#endif
    if (p->args) {
        for (size_t i = 0; i < p->count; ++i) free(p->args[i]);
        free(p->args); p->args = NULL;
    }
    if (p->env) {
        for (size_t i = 0; p->env[i]; ++i) free(p->env[i]);
        free(p->env); p->env = NULL;
    }
    free(p->cwd); p->cwd = NULL;
    free(p->command.data); p->command = {};
    for (int i = 0; i < 2; ++i) {
        free(p->streams[i].path); p->streams[i].path = NULL;
        free(p->streams[i].buffer.data); p->streams[i].buffer = {};
    }
    return 0;
}

static void* Allocate(lua_State* L, size_t size) {
    void* memory = malloc(size);
    if (!memory) luaL_error(L, "exec: out of memory");
    return memory;
}

static const char* String(lua_State* L, int index) {
    luaL_checktype(L, index, LUA_TSTRING);
    size_t size;
    const char* value = lua_tolstring(L, index, &size);
    if (memchr(value, 0, size)) luaL_error(L, "exec: strings must not contain NUL bytes");
    return value;
}

static NativeChar* Native(lua_State* L, const char* text) {
#ifdef _WIN32
    int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, NULL, 0);
    if (!size) luaL_error(L, "exec: invalid UTF-8");
    wchar_t* value = (wchar_t*)Allocate(L, (size_t)size * sizeof(wchar_t));
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, value, size);
    return value;
#else
    size_t size = strlen(text) + 1;
    char* value = (char*)Allocate(L, size);
    memcpy(value, text, size);
    return value;
#endif
}

static size_t Length(const NativeChar* text) {
#ifdef _WIN32
    return wcslen(text);
#else
    return strlen(text);
#endif
}

static bool NameMatches(const NativeChar* entry, const NativeChar* name, size_t size) {
    if (Length(entry) <= size || entry[size] != '=') return false;
#ifdef _WIN32
    return CompareStringOrdinal(entry, (int)size, name, (int)size, TRUE) == CSTR_EQUAL;
#else
    return memcmp(entry, name, size) == 0;
#endif
}

static const NativeChar* Environment(Process* p, const NativeChar* name) {
    size_t size = Length(name);
    for (size_t i = 0; p->env[i]; ++i)
        if (NameMatches(p->env[i], name, size)) return p->env[i] + size + 1;
    return NULL;
}

static void ReadEnvironment(lua_State* L, Process* p, int options) {
    // Reserve room for all inherited entries and all Lua overrides.
    size_t extra = 0;
    if (options) {
        lua_getfield(L, options, "env");
        if (!lua_isnil(L, -1)) {
            luaL_checktype(L, -1, LUA_TTABLE);
            lua_pushnil(L);
            while (lua_next(L, -2)) { ++extra; lua_pop(L, 1); }
        }
    } else lua_pushnil(L);
    int overrides = lua_gettop(L);
    size_t count = 0;
#ifdef _WIN32
    wchar_t* inherited = GetEnvironmentStringsW();
    if (!inherited) luaL_error(L, "exec: cannot read environment");
    for (const wchar_t* e = inherited; *e; e += wcslen(e) + 1) ++count;
#else
    char** inherited = environ;
    while (inherited[count]) ++count;
#endif
    p->env = (NativeChar**)calloc(count + extra + 1, sizeof(NativeChar*));
    bool copied = p->env != NULL;
#ifdef _WIN32
    const wchar_t* e = inherited;
#endif
    for (size_t i = 0; copied && i < count; ++i) {
#ifndef _WIN32
        const char* e = inherited[i];
#endif
        size_t bytes = (Length(e) + 1) * sizeof(NativeChar);
        p->env[i] = (NativeChar*)malloc(bytes);
        if (!p->env[i]) copied = false;
        else memcpy(p->env[i], e, bytes);
#ifdef _WIN32
        e += wcslen(e) + 1;
#endif
    }
#ifdef _WIN32
    FreeEnvironmentStringsW(inherited);
#endif
    if (!copied) luaL_error(L, "exec: out of memory");
    if (lua_isnil(L, overrides)) { lua_pop(L, 1); return; }
    lua_pushnil(L);
    while (lua_next(L, overrides)) {
        const char* name = String(L, -2);
        if (!*name || strchr(name, '=')) luaL_error(L, "exec: invalid environment variable name");
        bool remove = lua_isboolean(L, -1) && !lua_toboolean(L, -1);
        if (remove) lua_pushfstring(L, "%s=", name);
        else lua_pushfstring(L, "%s=%s", name, String(L, -1));
        // Own the new entry before doing anything else that can raise.
        p->env[count] = Native(L, lua_tostring(L, -1));
        NativeChar* entry = p->env[count];
        size_t name_size = 0;
        while (entry[name_size] != '=') ++name_size;
        size_t match = 0;
        while (match < count && !NameMatches(p->env[match], entry, name_size)) ++match;
        if (match < count) {
            free(p->env[match]);
            p->env[match] = p->env[--count];
            p->env[count] = entry;
            p->env[count + 1] = NULL;
        }
        if (remove) { free(p->env[count]); p->env[count] = NULL; }
        else ++count;
        lua_pop(L, 2);
    }
    lua_pop(L, 1);
}

static void ReadStream(lua_State* L, int options, const char* name, Stream* stream, bool merge) {
    lua_getfield(L, options, name);
    if (lua_istable(L, -1)) {
        lua_getfield(L, -1, "path");
        stream->path = Native(L, String(L, -1));
        stream->mode = File;
        lua_pop(L, 1);
    } else if (!lua_isnil(L, -1)) {
        const char* mode = String(L, -1);
        if (strcmp(mode, "inherit") == 0) stream->mode = Inherit;
        else if (strcmp(mode, "capture") == 0) stream->mode = Capture;
        else if (strcmp(mode, "discard") == 0) stream->mode = Discard;
        else if (merge && strcmp(mode, "stdout") == 0) stream->mode = Merge;
        else luaL_error(L, "exec: invalid %s mode: %s", name, mode);
    }
    lua_pop(L, 1);
}

#ifndef _WIN32
static void Pipe(lua_State* L, int fds[2]) {
    if (pipe(fds) < 0) luaL_error(L, "exec: pipe: %s", strerror(errno));
    for (int i = 0; i < 2; ++i) {
        // Keep internal descriptors away from stdin/stdout/stderr, even when
        // the caller closed one of those. No descriptors leak through execve.
        int fd = fcntl(fds[i], F_DUPFD_CLOEXEC, 3);
        if (fd < 0) luaL_error(L, "exec: pipe: %s", strerror(errno));
        Close(&fds[i]); fds[i] = fd;
    }
}

struct ChildError { int number; const char* operation; };
static void ChildFail(Process* p, const char* operation) {
    ChildError error = {errno, operation};
    ssize_t result;
    do { result = write(p->error_pipe[1], &error, sizeof(error)); } while (result < 0 && errno == EINTR);
    _exit(127);
}

static int RunProcess(lua_State* L, Process* p) {
    const char* path = Environment(p, "PATH");
    if (!path) path = "/bin:/usr/bin";
    // Prepare PATH candidates before fork. Relative entries are evaluated after
    // chdir in the child; the child uses only async-signal-safe operations.
    if (strchr(p->args[0], '/')) {
        if (!Append(&p->command, p->args[0], strlen(p->args[0]) + 1)) luaL_error(L, "exec: out of memory");
    } else {
        const char* start = path;
        do {
            const char* end = strchr(start, ':');
            size_t size = end ? (size_t)(end - start) : strlen(start);
            if ((size && (!Append(&p->command, start, size) || !Append(&p->command, "/", 1))) ||
                !Append(&p->command, p->args[0], strlen(p->args[0]) + 1)) luaL_error(L, "exec: out of memory");
            start = end ? end + 1 : NULL;
        } while (start);
    }
    Pipe(L, p->error_pipe);
    for (int i = 0; i < 2; ++i) {
        if (p->streams[i].mode == Capture) {
            int fds[2] = {-1, -1};
            if (pipe(fds) < 0) luaL_error(L, "exec: pipe: %s", strerror(errno));
            p->streams[i].read = fds[0]; p->streams[i].write = fds[1];
            for (int j = 0; j < 2; ++j) {
                int fd = fcntl(fds[j], F_DUPFD_CLOEXEC, 3);
                if (fd < 0) luaL_error(L, "exec: pipe: %s", strerror(errno));
                int* slot = j ? &p->streams[i].write : &p->streams[i].read;
                Close(slot); *slot = fd;
            }
        }
    }
    fflush(NULL);
    p->pid = fork();
    if (p->pid < 0) { p->pid = 0; luaL_error(L, "exec: fork: %s", strerror(errno)); }
    if (p->pid == 0) {
        close(p->error_pipe[0]);
        if (p->cwd && chdir(p->cwd) < 0) ChildFail(p, "chdir");
        for (int i = 0; i < 2; ++i) {
            Stream* s = &p->streams[i];
            int fd = -1;
            if (s->mode == Capture) fd = s->write;
            else if (s->mode == Merge) fd = STDOUT_FILENO;
            else if (s->mode == File || s->mode == Discard) {
                fd = open(s->mode == File ? s->path : "/dev/null", O_WRONLY | O_CREAT | O_TRUNC, 0666);
                if (fd < 0) ChildFail(p, "open output");
            }
            if (fd >= 0 && fd != i + 1 && dup2(fd, i + 1) < 0) ChildFail(p, "redirect output");
            if ((s->mode == File || s->mode == Discard) && fd != i + 1) close(fd);
        }
        int denied = 0;
        for (size_t offset = 0; offset < p->command.size;) {
            const char* candidate = p->command.data + offset;
            execve(candidate, p->args, p->env);
            if (errno == EACCES) denied = EACCES;
            else if (errno != ENOENT && errno != ENOTDIR) ChildFail(p, "start");
            offset += strlen(candidate) + 1;
        }
        errno = denied ? denied : ENOENT;
        ChildFail(p, "start");
    }
    Close(&p->error_pipe[1]);
    for (int i = 0; i < 2; ++i) Close(&p->streams[i].write);
    ChildError error = {};
    ssize_t size;
    do { size = read(p->error_pipe[0], &error, sizeof(error)); } while (size < 0 && errno == EINTR);
    if (size < 0) luaL_error(L, "exec: start: %s", strerror(errno));
    Close(&p->error_pipe[0]);
    if (size) luaL_error(L, "exec: %s %s: %s", error.operation, p->args[0], strerror(error.number));
    // Drain both pipes together: a child may fill either pipe before writing to
    // the other. Sequential reads (or waiting first) can deadlock.
    while (p->streams[0].read >= 0 || p->streams[1].read >= 0) {
        struct pollfd fds[2] = {{p->streams[0].read, POLLIN, 0}, {p->streams[1].read, POLLIN, 0}};
        int ready;
        do { ready = poll(fds, 2, -1); } while (ready < 0 && errno == EINTR);
        if (ready < 0) luaL_error(L, "exec: poll: %s", strerror(errno));
        for (int i = 0; i < 2; ++i) {
            if (!fds[i].revents) continue;
            char data[16384];
            ssize_t n;
            do { n = read(fds[i].fd, data, sizeof(data)); } while (n < 0 && errno == EINTR);
            if (n < 0) luaL_error(L, "exec: read: %s", strerror(errno));
            if (!n) Close(&p->streams[i].read);
            else if (!Append(&p->streams[i].buffer, data, (size_t)n)) luaL_error(L, "exec: out of memory");
        }
    }
    int status;
    pid_t waited;
    do { waited = waitpid(p->pid, &status, 0); } while (waited < 0 && errno == EINTR);
    if (waited < 0) luaL_error(L, "exec: wait: %s", strerror(errno));
    p->pid = 0;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
#else
static void WindowsError(lua_State* L, const char* operation, DWORD error) {
    char message[512] = {};
    FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL, error, 0, message, sizeof(message), NULL);
    luaL_error(L, "exec: %s: %s (Windows error %d)", operation, message, (int)error);
}

static wchar_t* FullPath(lua_State* L, const wchar_t* path) {
    DWORD size = GetFullPathNameW(path, 0, NULL, NULL);
    if (!size) { WindowsError(L, "resolve path", GetLastError()); return NULL; }
    wchar_t* result = (wchar_t*)Allocate(L, (size_t)size * sizeof(wchar_t));
    if (!GetFullPathNameW(path, size, result, NULL)) {
        DWORD error = GetLastError(); free(result); WindowsError(L, "resolve path", error);
    }
    return result;
}

static wchar_t* ChildPath(lua_State* L, Process* p, const wchar_t* path) {
    if (path[0] == '/' || path[0] == '\\' || (path[0] && path[1] == ':')) {
        size_t bytes = (wcslen(path) + 1) * sizeof(wchar_t);
        wchar_t* result = (wchar_t*)Allocate(L, bytes);
        memcpy(result, path, bytes);
        return result;
    }
    size_t a = wcslen(p->cwd), b = wcslen(path);
    wchar_t* result = (wchar_t*)Allocate(L, (a + b + 2) * sizeof(wchar_t));
    memcpy(result, p->cwd, a * sizeof(wchar_t));
    result[a] = '/';
    memcpy(result + a + 1, path, (b + 1) * sizeof(wchar_t));
    return result;
}

static int CompareEnvironment(const void* a, const void* b) {
    return CompareStringOrdinal(*(const wchar_t* const*)a, -1, *(const wchar_t* const*)b, -1, TRUE) - CSTR_EQUAL;
}

static DWORD WINAPI ReadPipe(void* context) {
    Stream* s = (Stream*)context;
    char data[16384];
    DWORD size;
    for (;;) {
        if (!ReadFile(s->read, data, sizeof(data), &size, NULL)) {
            DWORD error = GetLastError();
            if (error != ERROR_BROKEN_PIPE && !s->error) s->error = (int)error;
            break;
        }
        if (!size) break;
        if (!s->error && !Append(&s->buffer, data, size)) s->error = ERROR_NOT_ENOUGH_MEMORY;
    }
    return 0;
}

static HANDLE InheritedHandle(lua_State* L, DWORD id, DWORD access) {
    HANDLE source = GetStdHandle(id), copy = NULL;
    if (source && source != INVALID_HANDLE_VALUE) {
        if (!DuplicateHandle(GetCurrentProcess(), source, GetCurrentProcess(), &copy, 0, TRUE, DUPLICATE_SAME_ACCESS))
            WindowsError(L, "duplicate standard handle", GetLastError());
    } else {
        SECURITY_ATTRIBUTES security = {sizeof(security), NULL, TRUE};
        copy = CreateFileW(L"NUL", access, FILE_SHARE_READ | FILE_SHARE_WRITE, &security, OPEN_EXISTING, 0, NULL);
        if (copy == INVALID_HANDLE_VALUE) WindowsError(L, "open NUL", GetLastError());
    }
    return copy;
}

static int RunProcess(lua_State* L, Process* p) {
    wchar_t* absolute = FullPath(L, p->cwd ? p->cwd : L".");
    free(p->cwd); p->cwd = absolute;
    // Quote according to the Windows C runtime argv rules, including trailing
    // backslashes and empty arguments. cmd.exe is never involved.
    for (size_t i = 0; i < p->count; ++i) {
        if (!Append(&p->command, i ? " \"" : "\"", i ? 2 : 1)) luaL_error(L, "exec: out of memory");
        const char* arg = p->args[i];
        for (;;) {
            size_t slashes = 0;
            while (*arg == '\\') { ++slashes; ++arg; }
            size_t copies = (*arg == '"' || !*arg) ? slashes * 2 : slashes;
            for (size_t j = 0; j < copies; ++j)
                if (!Append(&p->command, "\\", 1)) luaL_error(L, "exec: out of memory");
            if (!*arg) break;
            if (*arg == '"' && !Append(&p->command, "\\", 1)) luaL_error(L, "exec: out of memory");
            if (!Append(&p->command, arg++, 1)) luaL_error(L, "exec: out of memory");
        }
        if (!Append(&p->command, "\"", 1)) luaL_error(L, "exec: out of memory");
    }
    if (!Append(&p->command, "", 1)) luaL_error(L, "exec: out of memory");
    p->command_line = Native(L, p->command.data);
    p->application = Native(L, p->args[0]);
    if (wcspbrk(p->application, L"/\\:")) {
        wchar_t* path = ChildPath(L, p, p->application);
        free(p->application); p->application = path;
    } else {
        // Search the child's PATH, including overrides and relative entries.
        const wchar_t* path = Environment(p, L"PATH");
        Buffer search = {};
        // Use the already owned buffer as scratch so Lua errors free it.
        free(p->command.data); p->command = search;
        while (path) {
            const wchar_t* end = wcschr(path, ';');
            size_t size = end ? (size_t)(end - path) : wcslen(path);
            if (size >= 2 && path[0] == '"' && path[size - 1] == '"') { ++path; size -= 2; }
            bool absolute_path = size && (path[0] == '/' || path[0] == '\\' || (size > 1 && path[1] == ':'));
            if (!absolute_path && (!Append(&p->command, p->cwd, wcslen(p->cwd) * sizeof(wchar_t)) ||
                !Append(&p->command, L"/", sizeof(wchar_t)))) luaL_error(L, "exec: out of memory");
            if (!Append(&p->command, path, size * sizeof(wchar_t)) || !Append(&p->command, L";", sizeof(wchar_t)))
                luaL_error(L, "exec: out of memory");
            path = end ? end + 1 : NULL;
        }
        if (!p->command.size) WindowsError(L, "find executable in PATH", ERROR_FILE_NOT_FOUND);
        // Replace the trailing separator to avoid searching the parent's cwd.
        ((wchar_t*)p->command.data)[p->command.size / sizeof(wchar_t) - 1] = 0;
        DWORD size = SearchPathW((wchar_t*)p->command.data, p->application, L".exe", 0, NULL, NULL);
        if (!size) WindowsError(L, "find executable in PATH", GetLastError());
        wchar_t* found = (wchar_t*)Allocate(L, (size_t)size * sizeof(wchar_t));
        if (!SearchPathW((wchar_t*)p->command.data, p->application, L".exe", size, found, NULL)) {
            DWORD error = GetLastError(); free(found); WindowsError(L, "find executable in PATH", error);
        }
        free(p->application); p->application = found;
    }
    size_t count = 0, total = 1;
    while (p->env[count]) { total += wcslen(p->env[count]) + 1; ++count; }
    qsort(p->env, count, sizeof(wchar_t*), CompareEnvironment);
    p->environment = (wchar_t*)Allocate(L, (total + 1) * sizeof(wchar_t));
    wchar_t* cursor = p->environment;
    for (size_t i = 0; i < count; ++i) {
        size_t size = wcslen(p->env[i]) + 1;
        memcpy(cursor, p->env[i], size * sizeof(wchar_t)); cursor += size;
    }
    cursor[0] = cursor[1] = 0;
    p->input = InheritedHandle(L, STD_INPUT_HANDLE, GENERIC_READ);
    SECURITY_ATTRIBUTES security = {sizeof(security), NULL, TRUE};
    for (int i = 0; i < 2; ++i) {
        Stream* s = &p->streams[i];
        if (s->mode == Inherit) s->write = InheritedHandle(L, i ? STD_ERROR_HANDLE : STD_OUTPUT_HANDLE, GENERIC_WRITE);
        else if (s->mode == Capture) {
            if (!CreatePipe(&s->read, &s->write, &security, 0) || !SetHandleInformation(s->read, HANDLE_FLAG_INHERIT, 0))
                WindowsError(L, "create pipe", GetLastError());
        } else if (s->mode == Merge) {
            if (!DuplicateHandle(GetCurrentProcess(), p->streams[0].write, GetCurrentProcess(), &s->write, 0, TRUE, DUPLICATE_SAME_ACCESS))
                WindowsError(L, "merge stderr", GetLastError());
        } else {
            if (s->mode == File) {
                wchar_t* path = ChildPath(L, p, s->path);
                free(s->path); s->path = path;
            }
            s->write = CreateFileW(s->mode == File ? s->path : L"NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                &security, s->mode == File ? CREATE_ALWAYS : OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
            if (s->write == INVALID_HANDLE_VALUE) WindowsError(L, "open output", GetLastError());
        }
    }
    STARTUPINFOEXW startup = {};
    startup.StartupInfo.cb = sizeof(startup);
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = p->input;
    startup.StartupInfo.hStdOutput = p->streams[0].write;
    startup.StartupInfo.hStdError = p->streams[1].write;
    HANDLE handles[] = {p->input, p->streams[0].write, p->streams[1].write};
    SIZE_T size = 0;
    InitializeProcThreadAttributeList(NULL, 1, 0, &size);
    p->attributes = (LPPROC_THREAD_ATTRIBUTE_LIST)Allocate(L, size);
    if (!InitializeProcThreadAttributeList(p->attributes, 1, 0, &size)) WindowsError(L, "initialize process attributes", GetLastError());
    p->attributes_ready = true;
    if (!UpdateProcThreadAttribute(p->attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, handles, sizeof(handles), NULL, NULL))
        WindowsError(L, "set inherited handles", GetLastError());
    startup.lpAttributeList = p->attributes;
    PROCESS_INFORMATION info = {};
    fflush(NULL);
    if (!CreateProcessW(p->application, p->command_line, NULL, NULL, TRUE,
        EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT, p->environment, p->cwd, &startup.StartupInfo, &info))
        WindowsError(L, p->args[0], GetLastError());
    p->process = info.hProcess;
    CloseHandle(info.hThread);
    Close(&p->input);
    for (int i = 0; i < 2; ++i) {
        Stream* s = &p->streams[i];
        Close(&s->write);
        if (s->mode == Capture) {
            s->thread = CreateThread(NULL, 0, ReadPipe, s, 0, NULL);
            if (!s->thread) WindowsError(L, "start capture reader", GetLastError());
        }
    }
    if (WaitForSingleObject(p->process, INFINITE) != WAIT_OBJECT_0) WindowsError(L, "wait", GetLastError());
    DWORD code;
    if (!GetExitCodeProcess(p->process, &code)) WindowsError(L, "exit code", GetLastError());
    Close(&p->process);
    for (int i = 0; i < 2; ++i) {
        Stream* s = &p->streams[i];
        if (s->thread) {
            if (WaitForSingleObject(s->thread, INFINITE) != WAIT_OBJECT_0) WindowsError(L, "wait for capture", GetLastError());
            Close(&s->thread);
            Close(&s->read);
            if (s->error) WindowsError(L, "read output", (DWORD)s->error);
        }
    }
    // Windows exit codes are unsigned 32-bit values; preserve them in Lua.
    return (int)code;
}
#endif

static int Exec(lua_State* L) {
    int supplied = lua_gettop(L);
    bool options = lua_istable(L, 1);
    size_t count = options ? lua_rawlen(L, 1) : (size_t)supplied;
    if (!count) return luaL_error(L, "exec: executable is required");
    Process* p = (Process*)lua_newuserdatauv(L, sizeof(Process), 0);
    memset(p, 0, sizeof(*p));
#ifndef _WIN32
    p->error_pipe[0] = p->error_pipe[1] = -1;
    for (int i = 0; i < 2; ++i) p->streams[i].read = p->streams[i].write = -1;
#endif
    luaL_setmetatable(L, "dotcmd.exec");
    lua_toclose(L, -1);
    p->count = count;
    p->args = (char**)calloc(count + 1, sizeof(char*));
    if (!p->args) return luaL_error(L, "exec: out of memory");
    for (size_t i = 0; i < count; ++i) {
        if (options) lua_rawgeti(L, 1, (lua_Integer)i + 1);
        const char* value = String(L, options ? -1 : (int)i + 1);
        size_t size = strlen(value) + 1;
        p->args[i] = (char*)Allocate(L, size);
        memcpy(p->args[i], value, size);
        if (options) lua_pop(L, 1);
    }
    if (!p->args[0][0]) return luaL_error(L, "exec: executable must not be empty");
    if (options) {
        if (supplied != 1) return luaL_error(L, "exec: table form accepts one argument");
        lua_getfield(L, 1, "cwd");
        if (!lua_isnil(L, -1)) p->cwd = Native(L, String(L, -1));
        lua_pop(L, 1);
        lua_getfield(L, 1, "check");
        if (!lua_isnil(L, -1)) { luaL_checktype(L, -1, LUA_TBOOLEAN); p->check = lua_toboolean(L, -1); }
        lua_pop(L, 1);
        ReadStream(L, 1, "stdout", &p->streams[0], false);
        ReadStream(L, 1, "stderr", &p->streams[1], true);
    }
    ReadEnvironment(L, p, options ? 1 : 0);
#ifdef _WIN32
    lua_Integer code = (uint32_t)RunProcess(L, p);
#else
    lua_Integer code = RunProcess(L, p);
#endif
    if (p->check && code != 0) {
        lua_pushfstring(L, "exec: %s exited with code %I", p->args[0], code);
        Stream* error = &p->streams[p->streams[1].mode == Merge ? 0 : 1];
        if (error->mode == Capture && error->buffer.size) {
            lua_pushliteral(L, "\n");
            lua_pushlstring(L, error->buffer.data, error->buffer.size);
            lua_concat(L, 3);
        }
        return lua_error(L);
    }
    lua_pushinteger(L, code);
    for (int i = 0; i < 2; ++i) {
        Stream* s = &p->streams[i];
        if (s->mode == Capture) lua_pushlstring(L, s->buffer.data ? s->buffer.data : "", s->buffer.size);
        else lua_pushnil(L);
    }
    return 3;
}

void RegisterExec(lua_State* L) {
    if (luaL_newmetatable(L, "dotcmd.exec")) {
        lua_pushcfunction(L, Cleanup); lua_setfield(L, -2, "__close");
        lua_pushcfunction(L, Cleanup); lua_setfield(L, -2, "__gc");
    }
    lua_pop(L, 1);
    lua_pushcfunction(L, Exec);
    lua_setglobal(L, "exec");
}
