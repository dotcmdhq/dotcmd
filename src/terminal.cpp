#include "terminal.h"

#include <stdio.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <io.h>
#else
#include <unistd.h>
#endif
extern "C" {
#include "lua.h"
#include "lauxlib.h"
}

static int IsTerminal(lua_State* L) {
    luaL_Stream* stream = (luaL_Stream*)luaL_checkudata(L, 1, LUA_FILEHANDLE);
    luaL_argcheck(L, stream->f != NULL, 1, "closed file");
#ifdef _WIN32
    int descriptor = _fileno(stream->f);
    intptr_t native = descriptor < 0 ? -1 : _get_osfhandle(descriptor);
    HANDLE handle = native == -1 ? INVALID_HANDLE_VALUE : (HANDLE)native;
    DWORD mode;
    if (handle == INVALID_HANDLE_VALUE || !GetConsoleMode(handle, &mode)
        || !SetConsoleMode(handle, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING)) {
        lua_pushboolean(L, 0);
    } else {
        lua_pushboolean(L, 1);
    }
#else
    lua_pushboolean(L, isatty(fileno(stream->f)));
#endif
    return 1;
}

static int OpenTerminal(lua_State* L) {
    lua_pushcfunction(L, IsTerminal);
    return 1;
}

void RegisterTerminal(lua_State* L) {
    luaL_getsubtable(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
    lua_pushcfunction(L, OpenTerminal);
    lua_setfield(L, -2, "dotcmd._terminal");
    lua_pop(L, 1);
}
