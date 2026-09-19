#pragma once

struct lua_State;
// exec(program, ...) or exec{program, ..., cwd, env, stdout, stderr, check=false}.
// env overlays the inherited environment; false removes a variable.
// Streams accept "inherit", "capture", "discard", or {path="file"}; stderr also
// accepts "stdout". File paths are relative to the child's cwd and are truncated.
// Returns exit code, captured stdout or nil, captured stderr or nil.
// Start/I/O failures always raise; check=true also raises on a nonzero exit.
void RegisterExec(lua_State* L);
