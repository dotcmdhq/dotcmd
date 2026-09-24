#pragma once

struct lua_State;
// exec(program, ...) or exec{program, ..., cwd, env, stdin, stdout, stderr, check=true}.
// env overlays the inherited environment; false removes a variable.
// Output streams accept "inherit", "capture", "discard", or {path="file"}; stderr
// also accepts "stdout". Input accepts "inherit", "discard", or {path="file"}.
// File paths are relative to the child's cwd; output files are truncated.
// Returns {code, stdout, stderr}; output fields are present only when captured.
// Start/I/O failures always raise; check=true also raises on a nonzero exit.
// spawn(program, ...) or spawn{program, ..., cwd, env, stdin, stdout, stderr}
// returns a process with wait{check=true}, poll, kill, and close methods.
// "pipe" streams are Lua file handles; "capture" streams drain in the background.
// <close> stops and waits for the direct child, then closes its streams.
void RegisterExec(lua_State* L);
