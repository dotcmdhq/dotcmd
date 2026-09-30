#pragma once

struct lua_State;
// sha256{bytes="contents"} or sha256{path="file"}, returning lowercase hexadecimal.
// Strings are binary-safe; files are streamed relative to the current directory.
// sha256() returns a consumer: one string argument updates it, no arguments
// finalizes it and returns the digest. Calls after completion raise.
// File and hashing failures raise Lua errors.
void RegisterSha256(lua_State* L);
