#pragma once

struct lua_State;
// Installs json.decode(text) and json.encode(value, options?). Decoded tables
// carry __jsontype hints; null becomes nil. Encoding infers untagged nonempty
// tables and rejects ambiguous empty tables. Invalid inputs raise Lua errors.
void RegisterJson(lua_State* L);
