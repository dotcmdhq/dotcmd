#pragma once

struct lua_State;
// Installs global http(url | {url, method="GET", headers={}, body, path,
// connect_timeout=30, timeout=0, check=false}). Header values accept a string or string array.
// Returns {status, headers, body}; response headers always contain string arrays.
// With path, body is absent and only a successful 2xx response replaces the file.
// Transport/filesystem failures raise Lua errors. check=true also raises on non-2xx statuses.
void RegisterHttp(lua_State* L);
// Called after Lua closes, so any request userdata has released its CURL handle.
void CleanupHttp();
