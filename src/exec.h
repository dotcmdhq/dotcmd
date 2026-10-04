#pragma once

struct lua_State;
// exec(program, ...) or exec{command, ..., cwd, env, stdin, stdout, stderr, check=true}.
// A table command may contain another command at index 1. Arguments append,
// environments merge with outer values winning, and the outermost specified cwd wins.
// Environment functions update the effective inner value and receive nil when absent;
// nil or false results remove a variable. Direct false values remove one too. Only the
// outer table supplies streams and check.
// Output streams accept "inherit", "capture", "discard", or {path="file"}; stderr
// also accepts "stdout". Input accepts "inherit", "discard", or {path="file"}.
// File paths are relative to the child's cwd; output files are truncated.
// Returns {exit_code, stdout, stderr}; output fields are present only when captured.
// Start/I/O failures always raise. On a nonzero exit, check=true raises
// {exit_code}; message is included unless the effective stderr stream is inherited.
// spawn(program, ...) or spawn{command, ..., cwd, env, stdin, stdout, stderr}
// returns a process with wait{check=true}, poll, kill, and close methods.
// "pipe" streams are Lua file handles; "capture" streams drain in the background.
// On Unix, synchronous startup and blocking waits ignore SIGINT/SIGQUIT in the parent so
// foreground children can finish their interrupt cleanup before dotcmd returns.
// Windows similarly handles Ctrl+C/Ctrl+Break only in the parent.
// <close> stops and waits for the direct child, then closes its streams.
void RegisterExec(lua_State* L);
