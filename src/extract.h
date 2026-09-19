#pragma once
struct lua_State;
// extract(path | {path, to?, strip_components=0, include?}) -> no values.
// A missing `to` removes the archive suffix (or appends .unpacked).
// Selection uses exact paths/directory prefixes before stripping components.
// Publishes a new directory atomically; its parent must already exist.
void RegisterExtract(lua_State* L);
