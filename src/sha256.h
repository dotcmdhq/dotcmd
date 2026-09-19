#pragma once

struct lua_State;
// sha256(bytes) or sha256{path="file"}, returning lowercase hexadecimal.
// Strings are binary-safe; files are streamed relative to the current directory.
// File and hashing failures raise Lua errors.
void RegisterSha256(lua_State* L);
