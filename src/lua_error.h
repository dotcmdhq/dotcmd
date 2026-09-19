#pragma once
extern "C" {
#include "lua.h"
}

static int DestinationExists(lua_State* L, const char* operation, const char* path) {
    lua_newtable(L);
    lua_pushliteral(L, "destination_exists"); lua_setfield(L, -2, "code");
    lua_pushfstring(L, "%s: destination already exists: %s", operation, path);
    lua_setfield(L, -2, "message");
    lua_newtable(L);
    lua_pushcfunction(L, [](lua_State* state) -> int {
        lua_getfield(state, 1, "message");
        return 1;
    });
    lua_setfield(L, -2, "__tostring");
    lua_setmetatable(L, -2);
    return lua_error(L);
}
