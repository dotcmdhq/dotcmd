#pragma once

struct lua_State;
// Global fs: stat(path, {follow=true}) -> {type, size} or nil when missing;
// list(path) -> unsorted generic-for iterator with automatic directory cleanup;
// mkdir(path) creates parents; remove(path, {recursive=false}) ignores missing
// paths and never traverses symlinks; rename(from, to, {if_exists="error"}) has no copy fallback;
// if_exists accepts error/skip/replace; rename returns true on success, false when skipped;
// chmod(path, mode) sets Unix permissions; "+x" adds execute bits allowed by umask (no-op on Windows).
// UTF-8 paths are relative to cwd. Other mutations return nothing; failures raise.
// read(path) -> binary string or nil when missing; write(path, bytes,
// {parents=true, if_exists="replace"}) atomically publishes a complete file.
// write follows existing symlinks when replacing, preserves Unix permissions,
// and returns true on success, false only for if_exists="skip" on an existing path.
// Writes check flushing and closing but do not sync to durable storage.
void RegisterFs(lua_State* L);

// Internal cleanup for temporary extraction trees; never follows links.
bool RemoveFsTree(const char* path);
