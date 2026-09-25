// Procedural C++ host. Lua is compiled separately as C; no C++ unwinding.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <direct.h>
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
    for (const auto& module : lua_modules) {
        if (strcmp(name, module.name) != 0) continue;
        if (luaL_loadbufferx(L, (const char*)module.source, module.size, module.path, "t") != LUA_OK)
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
    luaL_openlibs(L);
    RegisterHttp(L);
    RegisterExec(L);
    RegisterSha256(L);
    RegisterFs(L);
    RegisterExtract(L);
    RegisterTerminal(L);
    // Built-in modules remain available. Do not pick up an installed Lua tree.
    lua_getglobal(L, "package");
    SetString(L, "path", "");
    SetString(L, "cpath", "");
    lua_getfield(L, -1, "searchers");
    lua_pushcfunction(L, SearchBuiltin);
    lua_rawseti(L, -2, 2); // Replace the Lua filesystem searcher.
    lua_pop(L, 2);
    lua_createtable(L, 0, 8);
    SetString(L, "version", DOTCMD_VERSION);
    SetString(L, "os", DOTCMD_OS);
    SetString(L, "arch", DOTCMD_ARCH);
    SetString(L, "build", DOTCMD_BUILD);
    SetString(L, "lua_version", LUA_RELEASE);
    SetString(L, "compiler", DOTCMD_COMPILER);
    char* path = ExecutablePath();
    if (!path) return luaL_error(L, "cannot determine executable path");
    SetString(L, "executable", path);
    free(path);
    path = WorkingDirectory();
    if (!path) return luaL_error(L, "cannot determine working directory");
    SetString(L, "cwd", path);
    free(path);
    lua_setglobal(L, "host");
    if (luaL_loadbufferx(L, (const char*)main_lua, sizeof(main_lua), "@embedded/main.lua", "t") != LUA_OK)
        return lua_error(L);
    // Pass private resources as one table to the main.lua chunk.
    lua_createtable(L, 0, 3);
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
    lua_call(L, 1, 0);
    lua_getglobal(L, "main");
    if (!lua_isfunction(L, -1)) return luaL_error(L, "main.lua must define main(args)");
    lua_createtable(L, invocation->argc - 1, 0);
    for (int i = 1; i < invocation->argc; ++i) {
#ifdef _WIN32
        char* argument = Utf8(invocation->argv[i]);
        if (!argument) return luaL_error(L, "cannot convert argument to UTF-8");
        lua_pushstring(L, argument);
        free(argument);
#else
        lua_pushstring(L, invocation->argv[i]);
#endif
        lua_rawseti(L, -2, i);
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
