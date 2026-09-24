#pragma once
struct lua_State;
// extract(path, to?) or extract({path, to?, strip_components=0, include?, if_exists="error"}) -> boolean.
// A missing `to` removes the archive suffix (or appends .unpacked).
// Selection uses exact paths/directory prefixes before stripping components.
// if_exists accepts error/skip/replace. Returns true on success, false when skipped.
// Its parent must already exist. New directories publish atomically. Replacement
// exchanges trees on Unix; Windows moves the old tree aside with rollback on failure.
void RegisterExtract(lua_State* L);
