// Procedural C++ host. Lua is compiled separately as C; no C++ unwinding.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>
#include <direct.h>
#include <wchar.h>
#elif defined(__APPLE__)
#include <mach-o/dyld.h>
#include <unistd.h>
#else
#include <unistd.h>
#endif
extern "C" {
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
}
#include "build_config.h"
#include "api.h"
#include "main_lua.h"
#include "lua_modules.h"
#include "completion_bash.h"
#include "completion_zsh.h"
#include "completion_fish.h"
#include "completion_powershell.h"
#include "licenses.h"
#include "http.h"
#include "exec.h"
#include "sha256.h"
#include "json.h"
#include "fs.h"
#include "extract.h"
#include "terminal.h"

#if defined(_WIN32)
#define DOTCMD_OS "windows"
#elif defined(__APPLE__)
#define DOTCMD_OS "macos"
#else
#define DOTCMD_OS "linux"
#endif
#if defined(__aarch64__) || defined(_M_ARM64)
#define DOTCMD_ARCH "arm64"
#elif defined(__x86_64__) || defined(_M_X64)
#define DOTCMD_ARCH "x64"
#else
#error Unsupported architecture
#endif

struct Invocation {
    int argc;
#ifdef _WIN32
    wchar_t** argv;
#else
    char** argv;
#endif
};

#ifdef _WIN32
static char* Utf8(const wchar_t* text) {
    int n = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text, -1, NULL, 0, NULL, NULL);
    if (!n) return NULL;
    char* out = (char*)malloc((size_t)n);
    if (out && !WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text, -1, out, n, NULL, NULL)) {
        free(out);
        return NULL;
    }
    return out;
}

static const char* DetectedShell() {
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return NULL;
    DWORD process = GetCurrentProcessId();
    const char* shell = NULL;
    for (int depth = 0; depth < 3 && process; ++depth) {
        PROCESSENTRY32W entry;
        memset(&entry, 0, sizeof(entry));
        entry.dwSize = sizeof(entry);
        BOOL found = Process32FirstW(snapshot, &entry);
        while (found && entry.th32ProcessID != process) found = Process32NextW(snapshot, &entry);
        if (!found) break;
        if (depth) {
            if (!_wcsicmp(entry.szExeFile, L"pwsh.exe")) { shell = "pwsh"; break; }
            if (!_wcsicmp(entry.szExeFile, L"powershell.exe")) { shell = "powershell"; break; }
            if (!_wcsicmp(entry.szExeFile, L"bash.exe")) { shell = "bash"; break; }
            if (!_wcsicmp(entry.szExeFile, L"zsh.exe")) { shell = "zsh"; break; }
            if (!_wcsicmp(entry.szExeFile, L"fish.exe")) { shell = "fish"; break; }
        }
        process = entry.th32ParentProcessID;
    }
    CloseHandle(snapshot);
    return shell;
}

static int DetectShell(lua_State* L) {
    const char* shell = DetectedShell();
    if (shell) lua_pushstring(L, shell); else lua_pushnil(L);
    return 1;
}
#endif

static char* WorkingDirectory() {
#ifdef _WIN32
    wchar_t* wide = _wgetcwd(NULL, 0);
    if (!wide) return NULL;
    char* path = Utf8(wide);
    free(wide);
    return path;
#else
    size_t size = 256;
    for (;;) {
        char* path = (char*)malloc(size);
        if (!path) return NULL;
        if (getcwd(path, size)) return path;
        int error = errno;
        free(path);
        if (error != ERANGE) return NULL;
        size *= 2;
    }
#endif
}

static void ChangeDirectory(lua_State* L, const char* path) {
#ifdef _WIN32
    int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
    if (!size) luaL_error(L, "cannot convert working directory path");
    wchar_t* wide = (wchar_t*)malloc((size_t)size * sizeof(wchar_t));
    if (!wide) luaL_error(L, "out of memory");
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide, size)) {
        free(wide);
        luaL_error(L, "cannot convert working directory path");
    }
    int result = _wchdir(wide);
    int error = errno;
    free(wide);
#else
    int result = chdir(path);
    int error = errno;
#endif
    if (result != 0) luaL_error(L, "cannot change working directory to '%s': %s", path, strerror(error));
}

static char* ExecutablePath() {
#ifdef _WIN32
    wchar_t* wide = (wchar_t*)malloc(32768 * sizeof(wchar_t));
    if (!wide) return NULL;
    DWORD n = GetModuleFileNameW(NULL, wide, 32768);
    char* path = (n && n < 32768) ? Utf8(wide) : NULL;
    free(wide);
    return path;
#elif defined(__APPLE__)
    uint32_t size = 0;
    _NSGetExecutablePath(NULL, &size);
    char* path = (char*)malloc(size);
    if (!path) return NULL;
    if (_NSGetExecutablePath(path, &size)) { free(path); return NULL; }
    char* resolved = realpath(path, NULL);
    free(path);
    return resolved;
#else
    size_t size = 256;
    for (;;) {
        char* path = (char*)malloc(size + 1);
        if (!path) return NULL;
        ssize_t n = readlink("/proc/self/exe", path, size);
        if (n >= 0 && (size_t)n < size) { path[n] = 0; return path; }
        free(path);
        if (n < 0) return NULL;
        size *= 2;
    }
#endif
}

static void SetString(lua_State* L, const char* key, const char* value) {
    lua_pushstring(L, value);
    lua_setfield(L, -2, key);
}

static bool PathSeparator(char c) {
#ifdef _WIN32
    return c == '/' || c == '\\';
#else
    return c == '/';
#endif
}

static bool AbsolutePath(const char* path) {
#ifdef _WIN32
    bool drive = ((path[0] >= 'A' && path[0] <= 'Z') || (path[0] >= 'a' && path[0] <= 'z'))
        && path[1] == ':' && PathSeparator(path[2]);
    return drive || (PathSeparator(path[0]) && PathSeparator(path[1]));
#else
    return path[0] == '/';
#endif
}

// Keep environment strings on the Lua stack while assembling paths.
static const char* Environment(lua_State* L, const char* name) {
#ifdef _WIN32
    wchar_t wide_name[32];
    size_t i = 0;
    do { wide_name[i] = (wchar_t)name[i]; } while (name[i++]);
    const wchar_t* wide = _wgetenv(wide_name);
    if (!wide || !wide[0]) return NULL;
    char* value = Utf8(wide);
    if (!value) luaL_error(L, "cannot convert %s to UTF-8", name);
    lua_pushstring(L, value);
    free(value);
#else
    const char* value = getenv(name);
    if (!value || !value[0]) return NULL;
    lua_pushstring(L, value);
#endif
    return lua_tostring(L, -1);
}

static void SetCacheDirectory(lua_State* L) {
    int host = lua_gettop(L);
    const char* path = Environment(L, "DOTCMD_CACHE_DIR");
    if (path) {
        if (!AbsolutePath(path)) luaL_error(L, "DOTCMD_CACHE_DIR must be an absolute path");
        lua_pushstring(L, path);
    } else {
#ifdef _WIN32
        path = Environment(L, "LOCALAPPDATA");
        if (path) {
            lua_pushfstring(L, "%s\\dotcmd\\Cache", path);
        } else {
            path = Environment(L, "USERPROFILE");
            if (!path) luaL_error(L, "neither LOCALAPPDATA nor USERPROFILE is set");
            lua_pushfstring(L, "%s\\AppData\\Local\\dotcmd\\Cache", path);
        }
#else
#if !defined(__APPLE__)
        path = Environment(L, "XDG_CACHE_HOME");
        if (path && AbsolutePath(path)) {
            lua_pushfstring(L, "%s/dotcmd", path);
        } else
#endif
        {
            path = Environment(L, "HOME");
            if (!path) luaL_error(L, "HOME is not set");
#ifdef __APPLE__
            lua_pushfstring(L, "%s/Library/Caches/dotcmd", path);
#else
            lua_pushfstring(L, "%s/.cache/dotcmd", path);
#endif
        }
#endif
    }
    lua_setfield(L, host, "cache_dir");
    lua_settop(L, host);
}

static const char* InitializeHost(lua_State* L, Invocation* invocation) {
    char* path = ExecutablePath();
    if (!path) luaL_error(L, "cannot determine executable path");
    lua_pushstring(L, path);
    free(path);
    const char* executable = lua_tostring(L, -1);
    path = WorkingDirectory();
    if (!path) luaL_error(L, "cannot determine working directory");
    lua_pushstring(L, path);
    free(path);
    const char* invocation_dir = lua_tostring(L, -1);
#ifdef _WIN32
    DWORD size = GetFullPathNameW(invocation->argv[1], 0, NULL, NULL);
    if (!size) luaL_error(L, "cannot resolve launcher path");
    wchar_t* wide = (wchar_t*)malloc((size_t)size * sizeof(wchar_t));
    if (!wide) luaL_error(L, "out of memory");
    DWORD length = GetFullPathNameW(invocation->argv[1], size, wide, NULL);
    path = (length && length < size) ? Utf8(wide) : NULL;
    free(wide);
    if (!path) luaL_error(L, "cannot resolve launcher path");
    lua_pushstring(L, path);
    free(path);
#else
    const char* argument = invocation->argv[1];
    if (AbsolutePath(argument)) lua_pushstring(L, argument);
    else lua_pushfstring(L, "%s/%s", invocation_dir, argument);
#endif
    const char* launcher = lua_tostring(L, -1);
    const char* separator = launcher;
    for (const char* p = launcher; *p; ++p) {
        if (PathSeparator(*p)) separator = p;
    }
    size_t directory_size = (size_t)(separator - launcher);
    if (directory_size == 0) directory_size = 1;
#ifdef _WIN32
    if (directory_size == 2 && launcher[1] == ':') directory_size = 3;
#endif
    lua_pushlstring(L, launcher, directory_size);
    ChangeDirectory(L, lua_tostring(L, -1));
    lua_pop(L, 1);
    path = WorkingDirectory();
    if (!path) luaL_error(L, "cannot determine working directory");
    lua_pushstring(L, path);
    free(path);
    const char* project_dir = lua_tostring(L, -1);

    lua_createtable(L, 0, 9);
    SetString(L, "os", DOTCMD_OS);
    SetString(L, "arch", DOTCMD_ARCH);
#ifdef _WIN32
    SetString(L, "exe_suffix", ".exe");
    SetString(L, "path_sep", ";");
    SetString(L, "dir_sep", "\\");
#else
    SetString(L, "exe_suffix", "");
    SetString(L, "path_sep", ":");
    SetString(L, "dir_sep", "/");
#endif
    SetString(L, "invocation_dir", invocation_dir);
    SetString(L, "project_dir", project_dir);
    SetString(L, "executable", executable);
    SetCacheDirectory(L);
    lua_setglobal(L, "host");
    return launcher;
}

static int FormatError(lua_State* L) {
    if (lua_istable(L, 1)) {
        // Read actual fields, without invoking an error object's __index.
        lua_pushliteral(L, "exit_code");
        lua_rawget(L, 1);
        lua_pushliteral(L, "message");
        lua_rawget(L, 1);
        if (!lua_isnil(L, -2) || !lua_isnil(L, -1)) {
            lua_Integer code = lua_isinteger(L, -2) ? lua_tointeger(L, -2) : 1;
            if (code < 0 || code > 255) code = 1;
            if (!lua_isnil(L, -1)) {
                luaL_tolstring(L, -1, NULL);
                lua_remove(L, -2);
            }
            // Copy the fields before unwinding: __close handlers may mutate the original.
            lua_createtable(L, 0, 2);
            lua_pushinteger(L, code);
            lua_setfield(L, -2, "exit_code");
            lua_pushvalue(L, -2);
            lua_setfield(L, -2, "message");
            return 1;
        }
    }
    luaL_tolstring(L, 1, NULL);
    return 1;
}

static int SearchBuiltin(lua_State* L) {
    const char* name = luaL_checkstring(L, 1);
    for (size_t i = 0; i < sizeof(lua_modules) / sizeof(lua_modules[0]); ++i) {
        const EmbeddedModule* module = &lua_modules[i];
        if (strcmp(name, module->name) != 0) continue;
        if (luaL_loadbufferx(L, (const char*)module->source, module->size, module->path, "t") != LUA_OK)
            return lua_error(L);
        return 1;
    }
    if (strncmp(name, "dotcmd.", 7) == 0)
        return luaL_error(L, "no embedded module '%s'", name);
    lua_pushfstring(L, "no embedded module '%s'", name);
    return 1;
}

// The whole initialization/call runs inside lua_pcall, including allocations.
static int Run(lua_State* L) {
    Invocation* invocation = (Invocation*)lua_touserdata(L, 1);
    if (invocation->argc < 2 || !invocation->argv[1][0]) {
        fputs("dotcmd: invoke the project's .cmd launcher\n", stderr);
        lua_pushinteger(L, 2);
        return 1;
    }
    const char* launcher = InitializeHost(L, invocation);
    luaL_openlibs(L);
    RegisterHttp(L);
    RegisterExec(L);
    RegisterSha256(L);
    RegisterJson(L);
    RegisterFs(L);
    RegisterExtract(L);
    RegisterTerminal(L);
    // Built-in modules remain available. Do not pick up an installed Lua tree.
    lua_getglobal(L, "package");
    SetString(L, "path", "./?.lua;./?/init.lua");
    SetString(L, "cpath", "");
    lua_getfield(L, -1, "searchers");
    for (int i = 4; i >= 2; --i) {
        lua_rawgeti(L, -1, i);
        lua_rawseti(L, -2, i + 1);
    }
    lua_pushcfunction(L, SearchBuiltin);
    lua_rawseti(L, -2, 2); // Search embedded modules before filesystem modules.
    lua_pop(L, 2);
    if (luaL_loadbufferx(L, (const char*)main_lua, sizeof(main_lua), "@embedded/main.lua", "t") != LUA_OK)
        return lua_error(L);
    // Pass private resources as one table to the main.lua chunk.
    lua_createtable(L, 0, 6);
    SetString(L, "launcher", launcher);
    SetString(L, "version", DOTCMD_VERSION);
#ifdef _WIN32
    lua_pushcfunction(L, DetectShell);
    lua_setfield(L, -2, "detect_shell");
#endif
    lua_pushcfunction(L, NativeFunctionName);
    lua_setfield(L, -2, "native_function_name");
    lua_pushlstring(L, (const char*)licenses, sizeof(licenses));
    lua_setfield(L, -2, "licenses");
    lua_createtable(L, 0, 4);
    lua_pushlstring(L, (const char*)completion_bash, sizeof(completion_bash));
    lua_setfield(L, -2, "bash");
    lua_pushlstring(L, (const char*)completion_zsh, sizeof(completion_zsh));
    lua_setfield(L, -2, "zsh");
    lua_pushlstring(L, (const char*)completion_fish, sizeof(completion_fish));
    lua_setfield(L, -2, "fish");
    lua_pushlstring(L, (const char*)completion_powershell, sizeof(completion_powershell));
    lua_setfield(L, -2, "powershell");
    lua_setfield(L, -2, "completion_scripts");
    lua_call(L, 1, 1);
    lua_createtable(L, invocation->argc - 2, 0);
    for (int i = 2; i < invocation->argc; ++i) {
#ifdef _WIN32
        char* argument = Utf8(invocation->argv[i]);
        if (!argument) return luaL_error(L, "cannot convert argument to UTF-8");
        lua_pushstring(L, argument);
        free(argument);
#else
        lua_pushstring(L, invocation->argv[i]);
#endif
        lua_rawseti(L, -2, i - 1);
    }
    lua_call(L, 1, 1);
    if (!lua_isinteger(L, -1)) return luaL_error(L, "main must return an integer exit code");
    lua_Integer code = lua_tointeger(L, -1);
    if (code < 0 || code > 255) return luaL_error(L, "main exit code must be between 0 and 255");
    return 1;
}

#ifdef _WIN32
int wmain(int argc, wchar_t** argv) {
    SetConsoleOutputCP(CP_UTF8);
#else
int main(int argc, char** argv) {
#endif
    lua_State* L = luaL_newstate();
    if (!L) { fprintf(stderr, "dotcmd: cannot create Lua state\n"); return 1; }
    Invocation invocation = {argc, argv};
    lua_pushcfunction(L, FormatError);
    lua_pushcfunction(L, Run);
    lua_pushlightuserdata(L, &invocation);
    int code = 1;
    if (lua_pcall(L, 1, 1, 1) == LUA_OK) {
        code = (int)lua_tointeger(L, -1);
    } else if (lua_istable(L, -1)) {
        lua_getfield(L, -1, "exit_code");
        code = (int)lua_tointeger(L, -1);
        lua_pop(L, 1);
        lua_getfield(L, -1, "message");
        if (!lua_isnil(L, -1)) {
            size_t size;
            const char* message = lua_tolstring(L, -1, &size);
            fputs("dotcmd: ", stderr);
            fwrite(message, 1, size, stderr);
            fputc('\n', stderr);
        }
    } else {
        fprintf(stderr, "dotcmd: %s\n", lua_tostring(L, -1));
    }
    lua_close(L);
    CleanupHttp();
    return code;
}
