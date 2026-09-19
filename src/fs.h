#pragma once

struct lua_State;
// Global fs: stat(path, {follow=true}) -> {type, size} or nil when missing;
// list(path) -> unsorted generic-for iterator with automatic directory cleanup;
// mkdir(path) creates parents; remove(path, {recursive=false}) ignores missing
// paths and never traverses symlinks; rename(from, to, {if_exists="error"}) has no copy fallback;
// if_exists accepts error/skip/replace; rename returns true on success, false when skipped;
// make_executable(path) adds Unix execute bits (no-op on Windows).
// UTF-8 paths are relative to cwd. Other mutations return nothing; failures raise.
void RegisterFs(lua_State* L);

// Internal cleanup for temporary extraction trees; never follows links.
bool RemoveFsTree(const char* path);
