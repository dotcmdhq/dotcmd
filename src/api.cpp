#include "api.h"

void RegisterFunction(lua_State* L, const char* name, lua_CFunction function) {
    lua_pushstring(L, name);
    lua_pushcclosure(L, function, 1);
    lua_setglobal(L, name);
}

int NativeFunctionName(lua_State* L) {
    if (!lua_iscfunction(L, 1) || !lua_getupvalue(L, 1, 1)) return 0;
    if (lua_type(L, -1) == LUA_TSTRING) return 1;
    lua_pop(L, 1);
    return 0;
}
