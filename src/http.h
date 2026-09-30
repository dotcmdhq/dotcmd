#pragma once

struct lua_State;
// Installs global http(url | {url, method="GET", headers={}, body, to, progress=false,
// connect_timeout=30, timeout=0, check=true}). Header values accept a string or string array.
// Returns {url, status, headers, body}; response headers always contain string arrays.
// With a file path to, body is absent and only a successful 2xx response replaces the file.
// With a factory to, call to() once, feed binary chunks to its returned function,
// then call it without arguments after success and put its first return value in body.
// Consumer errors abort the transfer and propagate; failures skip completion.
// Transport/filesystem failures raise Lua errors. check=true also raises on non-2xx statuses.
void RegisterHttp(lua_State* L);
// Called after Lua closes, so any request userdata has released its CURL handle.
void CleanupHttp();
