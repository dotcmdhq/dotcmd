#include "sha256.h"
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>
#else
#include <openssl/sha.h>
#endif
extern "C" {
#include "lua.h"
#include "lauxlib.h"
}

struct Hash {
    FILE* file;
#ifdef _WIN32
    BCRYPT_ALG_HANDLE algorithm;
    BCRYPT_HASH_HANDLE hash;
    wchar_t* path;
#else
    SHA256_CTX context;
#endif
};

static int Cleanup(lua_State* L) {
    Hash* hash = (Hash*)lua_touserdata(L, 1);
    if (hash->file) { fclose(hash->file); hash->file = NULL; }
#ifdef _WIN32
    if (hash->hash) { BCryptDestroyHash(hash->hash); hash->hash = NULL; }
    if (hash->algorithm) { BCryptCloseAlgorithmProvider(hash->algorithm, 0); hash->algorithm = NULL; }
    free(hash->path); hash->path = NULL;
#endif
    return 0;
}

#ifdef _WIN32
static void Check(lua_State* L, NTSTATUS status, const char* operation) {
    if (status < 0) luaL_error(L, "sha256: %s failed (status %d)", operation, (int)status);
}
#endif

static void Update(lua_State* L, Hash* hash, const char* data, size_t size) {
#ifdef _WIN32
    // BCrypt takes a 32-bit length, but a Lua string can be larger.
    while (size) {
        ULONG count = size > ULONG_MAX ? ULONG_MAX : (ULONG)size;
        Check(L, BCryptHashData(hash->hash, (PUCHAR)data, count, 0), "BCryptHashData");
        data += count;
        size -= count;
    }
#else
    if (!SHA256_Update(&hash->context, data, size)) luaL_error(L, "sha256: update failed");
#endif
}

static int Sha256(lua_State* L) {
    if (lua_gettop(L) != 1) return luaL_error(L, "sha256 expects a string or {path=...}");
    bool from_file = lua_istable(L, 1);
    if (from_file) lua_getfield(L, 1, "path");
    int input = lua_gettop(L);
    luaL_checktype(L, input, LUA_TSTRING);
    size_t size;
    const char* value = lua_tolstring(L, input, &size);
    if (from_file && memchr(value, 0, size)) return luaL_error(L, "sha256: path must not contain NUL bytes");

    Hash* hash = (Hash*)lua_newuserdatauv(L, sizeof(Hash), 0);
    memset(hash, 0, sizeof(*hash));
    luaL_setmetatable(L, "dotcmd.sha256");
    lua_toclose(L, -1);
#ifdef _WIN32
    Check(L, BCryptOpenAlgorithmProvider(&hash->algorithm, BCRYPT_SHA256_ALGORITHM, NULL, 0), "BCryptOpenAlgorithmProvider");
    Check(L, BCryptCreateHash(hash->algorithm, &hash->hash, NULL, 0, NULL, 0, 0), "BCryptCreateHash");
#else
    if (!SHA256_Init(&hash->context)) return luaL_error(L, "sha256: initialization failed");
#endif

    if (from_file) {
#ifdef _WIN32
        int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, NULL, 0);
        if (!count) return luaL_error(L, "sha256: path is not valid UTF-8");
        hash->path = (wchar_t*)malloc((size_t)count * sizeof(wchar_t));
        if (!hash->path) return luaL_error(L, "sha256: out of memory");
        MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, hash->path, count);
        hash->file = _wfopen(hash->path, L"rb");
#else
        hash->file = fopen(value, "rb");
#endif
        if (!hash->file) return luaL_error(L, "sha256: cannot open %s: %s", value, strerror(errno));
        char buffer[65536];
        for (;;) {
            size_t count = fread(buffer, 1, sizeof(buffer), hash->file);
            if (count) Update(L, hash, buffer, count);
            if (count < sizeof(buffer)) {
                if (ferror(hash->file)) return luaL_error(L, "sha256: cannot read %s: %s", value, strerror(errno));
                break;
            }
        }
        int closed = fclose(hash->file);
        hash->file = NULL;
        if (closed != 0) return luaL_error(L, "sha256: cannot close %s: %s", value, strerror(errno));
    } else {
        Update(L, hash, value, size);
    }

    unsigned char digest[32];
#ifdef _WIN32
    Check(L, BCryptFinishHash(hash->hash, digest, sizeof(digest), 0), "BCryptFinishHash");
#else
    if (!SHA256_Final(digest, &hash->context)) return luaL_error(L, "sha256: finalization failed");
#endif
    const char* digits = "0123456789abcdef";
    char hex[64];
    for (size_t i = 0; i < sizeof(digest); ++i) {
        hex[i * 2] = digits[digest[i] >> 4];
        hex[i * 2 + 1] = digits[digest[i] & 15];
    }
    lua_pushlstring(L, hex, sizeof(hex));
    return 1;
}

void RegisterSha256(lua_State* L) {
    if (luaL_newmetatable(L, "dotcmd.sha256")) {
        lua_pushcfunction(L, Cleanup); lua_setfield(L, -2, "__close");
        lua_pushcfunction(L, Cleanup); lua_setfield(L, -2, "__gc");
    }
    lua_pop(L, 1);
    lua_pushcfunction(L, Sha256);
    lua_setglobal(L, "sha256");
}
