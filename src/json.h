#pragma once

struct lua_State;
// Installs json.decode(text). Objects become string-keyed tables, arrays become
// one-based tables, and null becomes nil. Invalid JSON raises a Lua error.
void RegisterJson(lua_State* L);
