#include "http.h"
#include <curl/curl.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>
#include <fcntl.h>
#include <io.h>
#else
#include <unistd.h>
#endif
extern "C" {
#include "lua.h"
#include "lauxlib.h"
}

struct Buffer {
    char* data;
    size_t size;
    size_t capacity;
};

struct Request {
    CURL* curl;
    curl_slist* headers;
    Buffer body;
    Buffer response_headers;
    FILE* file;
#ifdef _WIN32
    wchar_t* temporary;
    wchar_t* destination;
#else
    char* temporary;
#endif
    bool owns_temporary;
    char error[CURL_ERROR_SIZE];
};

// No Lua calls inside libcurl callbacks: a Lua allocation error must not jump
// past libcurl's cleanup. The request owns every native allocation instead.
static bool Append(Buffer* buffer, const char* data, size_t size) {
    if (size > SIZE_MAX - buffer->size) return false;
    size_t needed = buffer->size + size;
    if (needed > buffer->capacity) {
        size_t capacity = needed <= SIZE_MAX / 2 ? needed * 2 : needed;
        void* allocation = realloc(buffer->data, capacity);
        if (!allocation) return false;
        buffer->data = (char*)allocation;
        buffer->capacity = capacity;
    }
    if (size) memcpy(buffer->data + buffer->size, data, size);
    buffer->size = needed;
    return true;
}

static size_t WriteBody(char* data, size_t size, size_t count, void* context) {
    Request* request = (Request*)context;
    size_t bytes = size * count;
    if (request->file) return fwrite(data, 1, bytes, request->file);
    return Append(&request->body, data, bytes) ? bytes : CURL_WRITEFUNC_ERROR;
}

static size_t WriteHeader(char* data, size_t size, size_t count, void* context) {
    Request* request = (Request*)context;
    size_t bytes = size * count;
    // Drop proxy CONNECT, informational and redirect response headers/bodies.
    if (bytes >= 5 && memcmp(data, "HTTP/", 5) == 0) {
        request->response_headers.size = 0;
        request->body.size = 0;
        if (request->file) {
            if (fflush(request->file) != 0 || fseek(request->file, 0, SEEK_SET) != 0)
                return CURL_WRITEFUNC_ERROR;
#ifdef _WIN32
            if (_chsize_s(_fileno(request->file), 0) != 0) return CURL_WRITEFUNC_ERROR;
#else
            if (ftruncate(fileno(request->file), 0) != 0) return CURL_WRITEFUNC_ERROR;
#endif
        }
        return bytes;
    }
    return Append(&request->response_headers, data, bytes) ? bytes : CURL_WRITEFUNC_ERROR;
}

static int CloseRequest(lua_State* L) {
    Request* request = (Request*)lua_touserdata(L, 1);
    if (request->curl) curl_easy_cleanup(request->curl);
    curl_slist_free_all(request->headers);
    if (request->file) fclose(request->file);
    if (request->owns_temporary) {
#ifdef _WIN32
        DeleteFileW(request->temporary);
#else
        unlink(request->temporary);
#endif
    }
    free(request->temporary);
#ifdef _WIN32
    free(request->destination);
#endif
    free(request->body.data);
    free(request->response_headers.data);
    memset(request, 0, sizeof(*request));
    return 0;
}

static const char* StringField(lua_State* L, const char* name, const char* fallback) {
    lua_getfield(L, 1, name);
    const char* value = fallback;
    if (!lua_isnil(L, -1)) {
        luaL_checktype(L, -1, LUA_TSTRING);
        size_t length;
        value = lua_tolstring(L, -1, &length);
        if (memchr(value, 0, length)) luaL_error(L, "http: %s contains a NUL byte", name);
    }
    // Keep values rooted even when the options table uses __index.
    return value;
}

static long TimeoutField(lua_State* L, const char* name, long fallback) {
    lua_getfield(L, 1, name);
    if (lua_isnil(L, -1)) return fallback;
    lua_Integer value = luaL_checkinteger(L, -1);
    if (value < 0 || (uint64_t)value > LONG_MAX)
        luaL_error(L, "http: %s must be a nonnegative integer in seconds", name);
    return (long)value;
}

static bool Token(const char* value) {
    if (!*value) return false;
    for (const unsigned char* c = (const unsigned char*)value; *c; ++c) {
        if ((*c >= 'a' && *c <= 'z') || (*c >= 'A' && *c <= 'Z') ||
            (*c >= '0' && *c <= '9') || strchr("!#$%&'*+-.^_`|~", *c)) continue;
        return false;
    }
    return true;
}

#ifdef _WIN32
static wchar_t* WidePath(lua_State* L, const char* path) {
    int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
    if (!length) luaL_error(L, "http: output path is not valid UTF-8");
    wchar_t* wide = (wchar_t*)malloc((size_t)length * sizeof(wchar_t));
    if (!wide) luaL_error(L, "http: out of memory");
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide, length);
    return wide;
}
#endif

static void OpenOutput(lua_State* L, Request* request, const char* output) {
#ifdef _WIN32
    request->destination = WidePath(L, output);
    size_t length = wcslen(request->destination);
    request->temporary = (wchar_t*)malloc((length + 48) * sizeof(wchar_t));
    if (!request->temporary) luaL_error(L, "http: out of memory");
    memcpy(request->temporary, request->destination, length * sizeof(wchar_t));
    memcpy(request->temporary + length, L".download-", 10 * sizeof(wchar_t));
    HANDLE handle;
    do {
        unsigned char random[16];
        if (BCryptGenRandom(NULL, random, sizeof(random), BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0)
            luaL_error(L, "http: cannot generate temporary filename");
        for (size_t i = 0; i < sizeof(random); ++i) {
            request->temporary[length + 10 + i * 2] = L"0123456789abcdef"[random[i] >> 4];
            request->temporary[length + 11 + i * 2] = L"0123456789abcdef"[random[i] & 15];
        }
        request->temporary[length + 42] = 0;
        handle = CreateFileW(request->temporary, GENERIC_WRITE, 0, NULL, CREATE_NEW,
                             FILE_ATTRIBUTE_NORMAL, NULL);
    } while (handle == INVALID_HANDLE_VALUE && GetLastError() == ERROR_FILE_EXISTS);
    if (handle == INVALID_HANDLE_VALUE)
        luaL_error(L, "http: cannot create output file (Windows error %d)", (int)GetLastError());
    request->owns_temporary = true;
    int descriptor = _open_osfhandle((intptr_t)handle, _O_WRONLY | _O_BINARY);
    if (descriptor == -1) { CloseHandle(handle); luaL_error(L, "http: cannot open output file"); }
    request->file = _fdopen(descriptor, "wb");
    if (!request->file) _close(descriptor);
#else
    size_t length = strlen(output);
    request->temporary = (char*)malloc(length + sizeof(".download-XXXXXX"));
    if (!request->temporary) luaL_error(L, "http: out of memory");
    memcpy(request->temporary, output, length);
    strcpy(request->temporary + length, ".download-XXXXXX");
    int descriptor = mkstemp(request->temporary);
    if (descriptor == -1) luaL_error(L, "http: cannot create output file: %s", strerror(errno));
    request->owns_temporary = true;
    request->file = fdopen(descriptor, "wb");
    if (!request->file) close(descriptor);
#endif
    if (!request->file) luaL_error(L, "http: cannot open output file: %s", strerror(errno));
}

static void ResponseHeaders(lua_State* L, Buffer* buffer) {
    lua_newtable(L);
    size_t offset = 0;
    while (offset < buffer->size) {
        char* line = buffer->data + offset;
        char* newline = (char*)memchr(line, '\n', buffer->size - offset);
        size_t length = newline ? (size_t)(newline - line) : buffer->size - offset;
        offset += length + (newline ? 1 : 0);
        char* colon = (char*)memchr(line, ':', length);
        if (!colon) continue;
        size_t name_length = (size_t)(colon - line);
        for (size_t i = 0; i < name_length; ++i)
            if (line[i] >= 'A' && line[i] <= 'Z') line[i] += 'a' - 'A';
        char* value = colon + 1;
        char* end = line + length;
        while (value < end && (*value == ' ' || *value == '\t')) ++value;
        while (end > value && (end[-1] == '\r' || end[-1] == ' ' || end[-1] == '\t')) --end;
        lua_pushlstring(L, line, name_length);
        lua_pushvalue(L, -1);
        lua_rawget(L, -3);
        if (lua_isnil(L, -1)) { lua_pop(L, 1); lua_newtable(L); }
        lua_pushlstring(L, value, (size_t)(end - value));
        lua_rawseti(L, -2, (lua_Integer)lua_rawlen(L, -2) + 1);
        lua_rawset(L, -3);
    }
}

static void AddHeader(lua_State* L, Request* request, const char* name) {
    luaL_checktype(L, -1, LUA_TSTRING);
    size_t length;
    const char* value = lua_tolstring(L, -1, &length);
    if (memchr(value, 0, length) || memchr(value, '\r', length) || memchr(value, '\n', length))
        luaL_error(L, "http: invalid request header value");
    // A trailing semicolon tells libcurl to send an empty header value.
    lua_pushfstring(L, length ? "%s: %s" : "%s;%s", name, value);
    curl_slist* headers = curl_slist_append(request->headers, lua_tostring(L, -1));
    if (!headers) luaL_error(L, "http: out of memory");
    request->headers = headers;
    lua_pop(L, 1);
}

static int Http(lua_State* L) {
    if (lua_type(L, 1) == LUA_TSTRING) {
        lua_newtable(L);
        lua_pushvalue(L, 1);
        lua_setfield(L, -2, "url");
        lua_replace(L, 1);
    }
    luaL_checktype(L, 1, LUA_TTABLE);
    const char* url = StringField(L, "url", NULL);
    if (!url) return luaL_error(L, "http: url is required");
    const char* method = StringField(L, "method", "GET");
    if (!Token(method)) return luaL_error(L, "http: invalid method");
    const char* output = StringField(L, "path", NULL);
    long connect_timeout = TimeoutField(L, "connect_timeout", 30);
    long timeout = TimeoutField(L, "timeout", 0);
    lua_getfield(L, 1, "check");
    bool check = lua_toboolean(L, -1);
    lua_pop(L, 1);
    lua_getfield(L, 1, "body");
    size_t body_length = 0;
    const char* body = NULL;
    if (!lua_isnil(L, -1)) {
        luaL_checktype(L, -1, LUA_TSTRING);
        body = lua_tolstring(L, -1, &body_length);
    }

    Request* request = (Request*)lua_newuserdatauv(L, sizeof(Request), 0);
    memset(request, 0, sizeof(*request));
    luaL_setmetatable(L, "dotcmd.http.request");
    lua_toclose(L, -1);
    request->curl = curl_easy_init();
    if (!request->curl) return luaL_error(L, "http: cannot initialize libcurl");

#define OPTION(key, value) do { \
    CURLcode code = curl_easy_setopt(request->curl, key, value); \
    if (code != CURLE_OK) return luaL_error(L, "http: %s", curl_easy_strerror(code)); \
} while (0)
    OPTION(CURLOPT_ERRORBUFFER, request->error);
    OPTION(CURLOPT_URL, url);
    OPTION(CURLOPT_PROTOCOLS_STR, "https");
    OPTION(CURLOPT_REDIR_PROTOCOLS_STR, "https");
    OPTION(CURLOPT_FOLLOWLOCATION, CURLFOLLOW_OBEYCODE);
    OPTION(CURLOPT_MAXREDIRS, 10L);
    OPTION(CURLOPT_SSL_VERIFYPEER, 1L);
    OPTION(CURLOPT_SSL_VERIFYHOST, 2L);
    const char* ca_file = getenv("SSL_CERT_FILE");
#ifdef __APPLE__
    OPTION(CURLOPT_SSL_OPTIONS, ca_file ? 0L : (long)CURLSSLOPT_NATIVE_CA);
    OPTION(CURLOPT_PROXY_SSL_OPTIONS, (long)CURLSSLOPT_NATIVE_CA);
#endif
#if !defined(_WIN32) && !defined(__APPLE__)
    // Resolve trust on the running machine, not the machine that built dotcmd.
    if (!ca_file) {
        const char* candidates[] = {
            "/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt",
            "/etc/ssl/ca-bundle.pem", "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
            "/etc/ssl/cert.pem"
        };
        for (size_t i = 0; i < sizeof(candidates) / sizeof(*candidates); ++i) {
            if (access(candidates[i], R_OK) == 0) { ca_file = candidates[i]; break; }
        }
    }
    const char* ca_directory = getenv("SSL_CERT_DIR");
    if (ca_directory) OPTION(CURLOPT_CAPATH, ca_directory);
#endif
    if (ca_file) OPTION(CURLOPT_CAINFO, ca_file);
    OPTION(CURLOPT_CONNECTTIMEOUT, connect_timeout);
    OPTION(CURLOPT_TIMEOUT, timeout);
    OPTION(CURLOPT_NOSIGNAL, 1L);
    OPTION(CURLOPT_WRITEFUNCTION, WriteBody);
    OPTION(CURLOPT_WRITEDATA, request);
    OPTION(CURLOPT_HEADERFUNCTION, WriteHeader);
    OPTION(CURLOPT_HEADERDATA, request);
    if (strcmp(method, "POST") == 0) OPTION(CURLOPT_POST, 1L);
    if (body) {
        OPTION(CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)body_length);
        OPTION(CURLOPT_POSTFIELDS, body);
        // Preserve explicitly selected methods and bodies on 301/302 redirects.
        // A 303 still switches to GET, except for HEAD, as HTTP specifies.
        if (strcmp(method, "POST") != 0) OPTION(CURLOPT_POSTREDIR, (long)(CURL_REDIR_POST_301 | CURL_REDIR_POST_302));
    }
    OPTION(CURLOPT_CUSTOMREQUEST, method);
    if (strcmp(method, "HEAD") == 0) OPTION(CURLOPT_NOBODY, 1L);

    lua_getfield(L, 1, "headers");
    if (!lua_isnil(L, -1)) {
        luaL_checktype(L, -1, LUA_TTABLE);
        lua_pushnil(L);
        while (lua_next(L, -2)) {
            luaL_checktype(L, -2, LUA_TSTRING);
            size_t name_length;
            const char* name = lua_tolstring(L, -2, &name_length);
            if (memchr(name, 0, name_length) || !Token(name))
                return luaL_error(L, "http: invalid request header name");
            if (lua_istable(L, -1)) {
                lua_Integer count = (lua_Integer)lua_rawlen(L, -1);
                for (lua_Integer i = 1; i <= count; ++i) {
                    lua_rawgeti(L, -1, i);
                    AddHeader(L, request, name);
                    lua_pop(L, 1);
                }
            } else {
                AddHeader(L, request, name);
            }
            lua_pop(L, 1);
        }
    }
    OPTION(CURLOPT_HTTPHEADER, request->headers);
#undef OPTION
    if (output) OpenOutput(L, request, output);
    CURLcode code = curl_easy_perform(request->curl);
    if (code != CURLE_OK)
        return luaL_error(L, "http: %s", *request->error ? request->error : curl_easy_strerror(code));
    long status = 0;
    code = curl_easy_getinfo(request->curl, CURLINFO_RESPONSE_CODE, &status);
    if (code != CURLE_OK) return luaL_error(L, "http: %s", curl_easy_strerror(code));
    if (check && (status < 200 || status >= 300))
        return luaL_error(L, "http: HTTP status %d", (int)status);
    if (request->file) {
        int result = fclose(request->file);
        request->file = NULL;
        if (result != 0) return luaL_error(L, "http: cannot close output file: %s", strerror(errno));
    }
    lua_createtable(L, 0, output ? 2 : 3);
    lua_pushinteger(L, status);
    lua_setfield(L, -2, "status");
    ResponseHeaders(L, &request->response_headers);
    lua_setfield(L, -2, "headers");
    if (!output) {
        lua_pushlstring(L, request->body.data ? request->body.data : "", request->body.size);
        lua_setfield(L, -2, "body");
    } else if (status >= 200 && status < 300) {
#ifdef _WIN32
        if (!MoveFileExW(request->temporary, request->destination, MOVEFILE_REPLACE_EXISTING))
            return luaL_error(L, "http: cannot replace output file (Windows error %d)", (int)GetLastError());
#else
        if (rename(request->temporary, output) != 0)
            return luaL_error(L, "http: cannot replace output file: %s", strerror(errno));
#endif
        request->owns_temporary = false;
    }
    return 1;
}

void RegisterHttp(lua_State* L) {
    if (luaL_newmetatable(L, "dotcmd.http.request")) {
        lua_pushcfunction(L, CloseRequest);
        lua_setfield(L, -2, "__gc");
        lua_pushcfunction(L, CloseRequest);
        lua_setfield(L, -2, "__close");
    }
    lua_pop(L, 1);
    lua_pushcfunction(L, Http);
    lua_setglobal(L, "http");
}
