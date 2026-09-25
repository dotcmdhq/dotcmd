#pragma once
extern "C" {
#include "lua.h"
}

// Registers a global native API function and retains its symbolic name.
void RegisterFunction(lua_State* L, const char* name, lua_CFunction function);

// Returns the registered name of the function at index 1, if it has one.
int NativeFunctionName(lua_State* L);
