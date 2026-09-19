#include "fs.h"
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wchar.h>
typedef wchar_t PathChar;
typedef DWORD FsError;
#else
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
typedef char PathChar;
typedef int FsError;
#endif
extern "C" {
#include "lua.h"
#include "lauxlib.h"
}

struct State {
    PathChar* paths[2];
#ifdef _WIN32
    HANDLE directory;
    WIN32_FIND_DATAW entry;
    bool first;
#else
    DIR* directory;
#endif
};

static void CloseDirectory(State* state) {
#ifdef _WIN32
    if (state->directory != INVALID_HANDLE_VALUE) FindClose(state->directory);
    state->directory = INVALID_HANDLE_VALUE;
#else
    if (state->directory) closedir(state->directory);
    state->directory = NULL;
#endif
}

static int Cleanup(lua_State* L) {
    State* state = (State*)lua_touserdata(L, 1);
    CloseDirectory(state);
    for (int i = 0; i < 2; ++i) { free(state->paths[i]); state->paths[i] = NULL; }
    return 0;
}

static State* NewState(lua_State* L, bool closing = true) {
    State* state = (State*)lua_newuserdatauv(L, sizeof(State), 0);
    memset(state, 0, sizeof(*state));
#ifdef _WIN32
    state->directory = INVALID_HANDLE_VALUE;
#endif
    luaL_setmetatable(L, "dotcmd.fs");
    if (closing) lua_toclose(L, -1);
    return state;
}

static int Fail(lua_State* L, const char* operation, const char* path, FsError error) {
#ifdef _WIN32
    wchar_t wide[512] = {};
    char message[2048] = {};
    FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL, error, 0, wide, 512, NULL);
    WideCharToMultiByte(CP_UTF8, 0, wide, -1, message, sizeof(message), NULL, NULL);
    size_t size = strlen(message);
    while (size && (message[size - 1] == '\r' || message[size - 1] == '\n')) message[--size] = 0;
    return luaL_error(L, "fs.%s: %s: %s (Windows error %d)", operation, path, message, (int)error);
#else
    return luaL_error(L, "fs.%s: %s: %s", operation, path, strerror(error));
#endif
}

static bool Missing(FsError error) {
#ifdef _WIN32
    return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND;
#else
    return error == ENOENT;
#endif
}

static bool Option(lua_State* L, int index, const char* name, bool fallback) {
    if (lua_isnoneornil(L, index)) return fallback;
    luaL_checktype(L, index, LUA_TTABLE);
    lua_getfield(L, index, name);
    if (!lua_isnil(L, -1)) { luaL_checktype(L, -1, LUA_TBOOLEAN); fallback = lua_toboolean(L, -1); }
    lua_pop(L, 1);
    return fallback;
}

static PathChar* Path(lua_State* L, State* state, int slot, int index) {
    luaL_checktype(L, index, LUA_TSTRING);
    size_t size;
    const char* value = lua_tolstring(L, index, &size);
    if (!size || memchr(value, 0, size)) luaL_error(L, "fs: paths must be nonempty strings without NUL bytes");
#ifdef _WIN32
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, NULL, 0);
    if (!count) luaL_error(L, "fs: path is not valid UTF-8");
    wchar_t* wide = (wchar_t*)malloc((size_t)count * sizeof(wchar_t));
    if (!wide) luaL_error(L, "fs: out of memory");
    state->paths[slot] = wide;
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, wide, count);
    // Normalize drive/UNC roots and relative paths before creating parents.
    DWORD needed = GetFullPathNameW(wide, 0, NULL, NULL);
    if (!needed) Fail(L, "path", value, GetLastError());
    wchar_t* absolute = (wchar_t*)malloc((size_t)needed * sizeof(wchar_t));
    if (!absolute) luaL_error(L, "fs: out of memory");
    if (!GetFullPathNameW(wide, needed, absolute, NULL)) {
        FsError error = GetLastError(); free(absolute); Fail(L, "path", value, error);
    }
    free(wide); state->paths[slot] = absolute;
#else
    state->paths[slot] = (char*)malloc(size + 1);
    if (!state->paths[slot]) luaL_error(L, "fs: out of memory");
    memcpy(state->paths[slot], value, size + 1);
#endif
    return state->paths[slot];
}

#ifdef _WIN32
static size_t RootLength(const wchar_t* path);
#endif

static void TrimTrailingSeparators(PathChar* path) {
#ifdef _WIN32
    size_t size = wcslen(path), root = RootLength(path);
    while (size > root && (path[size - 1] == '\\' || path[size - 1] == '/')) path[--size] = 0;
#else
    size_t size = strlen(path);
    while (size > 1 && path[size - 1] == '/') path[--size] = 0;
#endif
}

static void Attributes(lua_State* L, const char* type, uint64_t size) {
    lua_createtable(L, 0, 2);
    lua_pushstring(L, type); lua_setfield(L, -2, "type");
    lua_pushinteger(L, (lua_Integer)size); lua_setfield(L, -2, "size");
}

static int Stat(lua_State* L) {
    bool follow = Option(L, 2, "follow", true);
    State* state = NewState(L);
    PathChar* path = Path(L, state, 0, 1);
    if (!follow) TrimTrailingSeparators(path);
#ifdef _WIN32
    DWORD flags = FILE_FLAG_BACKUP_SEMANTICS | (follow ? 0 : FILE_FLAG_OPEN_REPARSE_POINT);
    HANDLE file = CreateFileW(path, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL, OPEN_EXISTING, flags, NULL);
    if (file == INVALID_HANDLE_VALUE) {
        FsError error = GetLastError();
        if (Missing(error)) { lua_pushnil(L); return 1; }
        return Fail(L, "stat", lua_tostring(L, 1), error);
    }
    BY_HANDLE_FILE_INFORMATION info = {};
    FILE_ATTRIBUTE_TAG_INFO tag = {};
    FsError error = 0;
    if (!GetFileInformationByHandle(file, &info)) error = GetLastError();
    if (!error && !follow && (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) &&
        !GetFileInformationByHandleEx(file, FileAttributeTagInfo, &tag, sizeof(tag))) error = GetLastError();
    DWORD file_type = GetFileType(file);
    CloseHandle(file);
    if (error) return Fail(L, "stat", lua_tostring(L, 1), error);
    const char* type;
    if (!follow && (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT))
        type = tag.ReparseTag == IO_REPARSE_TAG_SYMLINK || tag.ReparseTag == IO_REPARSE_TAG_MOUNT_POINT ? "symlink" : "other";
    else if (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) type = "directory";
    else type = file_type == FILE_TYPE_DISK ? "file" : "other";
    Attributes(L, type, ((uint64_t)info.nFileSizeHigh << 32) | info.nFileSizeLow);
#else
    struct stat info;
    if ((follow ? stat(path, &info) : lstat(path, &info)) < 0) {
        if (Missing(errno)) { lua_pushnil(L); return 1; }
        return Fail(L, "stat", lua_tostring(L, 1), errno);
    }
    const char* type = S_ISREG(info.st_mode) ? "file" : S_ISDIR(info.st_mode) ? "directory" : S_ISLNK(info.st_mode) ? "symlink" : "other";
    Attributes(L, type, (uint64_t)info.st_size);
#endif
    return 1;
}

static int Next(lua_State* L) {
    State* state = (State*)luaL_checkudata(L, 1, "dotcmd.fs");
#ifdef _WIN32
    if (state->directory == INVALID_HANDLE_VALUE) return 0;
    for (;;) {
        if (state->first) state->first = false;
        else if (!FindNextFileW(state->directory, &state->entry)) {
            FsError error = GetLastError();
            CloseDirectory(state);
            if (error != ERROR_NO_MORE_FILES) return Fail(L, "list", "read directory", error);
            return 0;
        }
        const wchar_t* name = state->entry.cFileName;
        if (wcscmp(name, L".") == 0 || wcscmp(name, L"..") == 0) continue;
        char utf8[MAX_PATH * 4];
        int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, name, -1, utf8, sizeof(utf8), NULL, NULL);
        if (!size) return Fail(L, "list", "convert entry name to UTF-8", GetLastError());
        lua_pushlstring(L, utf8, (size_t)size - 1);
        return 1;
    }
#else
    if (!state->directory) return 0;
    for (;;) {
        errno = 0;
        struct dirent* entry = readdir(state->directory);
        if (!entry) {
            FsError error = errno;
            CloseDirectory(state);
            if (error) return Fail(L, "list", state->paths[0], error);
            return 0;
        }
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        lua_pushstring(L, entry->d_name);
        return 1;
    }
#endif
}

#ifdef _WIN32
static wchar_t* Join(const wchar_t* parent, const wchar_t* name) {
    size_t a = wcslen(parent), b = wcslen(name);
    wchar_t* path = (wchar_t*)malloc((a + b + 2) * sizeof(wchar_t));
    if (!path) return NULL;
    memcpy(path, parent, a * sizeof(wchar_t));
    path[a] = '\\';
    memcpy(path + a + 1, name, (b + 1) * sizeof(wchar_t));
    return path;
}
#endif

static int List(lua_State* L) {
    State* state = NewState(L, false);
    int index = lua_gettop(L);
    PathChar* path = Path(L, state, 0, 1);
    // The fourth generic-for result is closed by Lua on EOF, break, or errors.
    // Prepare these values before opening the directory (Lua may allocate).
    lua_pushcfunction(L, Next);
    lua_pushvalue(L, index);
    lua_pushnil(L);
    lua_pushvalue(L, index);
#ifdef _WIN32
    DWORD attributes = GetFileAttributesW(path);
    if (attributes == INVALID_FILE_ATTRIBUTES) return Fail(L, "list", lua_tostring(L, 1), GetLastError());
    if (!(attributes & FILE_ATTRIBUTE_DIRECTORY)) return Fail(L, "list", lua_tostring(L, 1), ERROR_DIRECTORY);
    state->paths[1] = Join(path, L"*");
    if (!state->paths[1]) return luaL_error(L, "fs: out of memory");
    state->directory = FindFirstFileW(state->paths[1], &state->entry);
    if (state->directory == INVALID_HANDLE_VALUE) {
        FsError error = GetLastError();
        if (error != ERROR_FILE_NOT_FOUND) return Fail(L, "list", lua_tostring(L, 1), error);
    } else state->first = true;
#else
    state->directory = opendir(path);
    if (!state->directory) return Fail(L, "list", lua_tostring(L, 1), errno);
#endif
    return 4;
}

static FsError MakeDirectory(const PathChar* path) {
#ifdef _WIN32
    if (CreateDirectoryW(path, NULL)) return 0;
    FsError error = GetLastError();
    if (error != ERROR_ALREADY_EXISTS) return error;
    DWORD attributes = GetFileAttributesW(path);
    if (attributes == INVALID_FILE_ATTRIBUTES) return GetLastError();
    return (attributes & FILE_ATTRIBUTE_DIRECTORY) ? 0 : ERROR_DIRECTORY;
#else
    if (mkdir(path, 0777) == 0) return 0;
    if (errno != EEXIST) return errno;
    struct stat info;
    if (stat(path, &info) < 0) return errno;
    return S_ISDIR(info.st_mode) ? 0 : ENOTDIR;
#endif
}

#ifdef _WIN32
static size_t RootLength(const wchar_t* path) {
    if (path[0] == '\\' && path[1] == '\\') {
        size_t start = 2;
        if (wcsncmp(path, L"\\\\?\\UNC\\", 8) == 0) start = 8;
        else if (wcsncmp(path, L"\\\\?\\", 4) == 0 && wcslen(path) >= 7 && path[5] == ':') return 7;
        const wchar_t* server = wcschr(path + start, '\\');
        if (!server) return wcslen(path);
        const wchar_t* share = wcschr(server + 1, '\\');
        return share ? (size_t)(share - path) + 1 : wcslen(path);
    }
    return path[0] && path[1] == ':' ? 3 : 1;
}
#endif

static int Mkdir(lua_State* L) {
    State* state = NewState(L);
    PathChar* path = Path(L, state, 0, 1);
#ifdef _WIN32
    size_t start = RootLength(path);
#else
    size_t start = 1;
#endif
    for (size_t i = start; path[i]; ++i) {
#ifdef _WIN32
        bool separator = path[i] == '\\' || path[i] == '/';
#else
        bool separator = path[i] == '/';
#endif
        if (!separator) continue;
        PathChar saved = path[i]; path[i] = 0;
        FsError error = MakeDirectory(path);
        path[i] = saved;
        if (error) return Fail(L, "mkdir", lua_tostring(L, 1), error);
    }
    FsError error = MakeDirectory(path);
    if (error) return Fail(L, "mkdir", lua_tostring(L, 1), error);
    return 0;
}

#ifndef _WIN32
// Traverse through directory descriptors. O_NOFOLLOW also prevents following a
// link substituted between inspecting a child and opening it for recursion.
static FsError RemoveAt(int parent, const char* name, bool recursive) {
    struct stat info;
    if (fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) < 0) return Missing(errno) ? 0 : errno;
    if (!S_ISDIR(info.st_mode)) return unlinkat(parent, name, 0) == 0 || Missing(errno) ? 0 : errno;
    if (recursive) {
        int fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (fd < 0) return Missing(errno) ? 0 : errno;
        DIR* directory = fdopendir(fd);
        if (!directory) { FsError error = errno; close(fd); return error; }
        FsError error = 0;
        for (;;) {
            errno = 0;
            struct dirent* entry = readdir(directory);
            if (!entry) { error = errno; break; }
            if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
            error = RemoveAt(dirfd(directory), entry->d_name, true);
            if (error) break;
        }
        if (closedir(directory) < 0 && !error) error = errno;
        if (error) return error;
    }
    return unlinkat(parent, name, AT_REMOVEDIR) == 0 || Missing(errno) ? 0 : errno;
}
#else
static FsError RemoveTree(const wchar_t* path, bool recursive) {
    // Hold the entry without sharing writes/deletes while traversing it, so it
    // cannot be replaced by a junction during enumeration. Open the link itself.
    HANDLE entry = CreateFileW(path, FILE_READ_ATTRIBUTES, FILE_SHARE_READ, NULL, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (entry == INVALID_HANDLE_VALUE) { FsError error = GetLastError(); return Missing(error) ? 0 : error; }
    BY_HANDLE_FILE_INFORMATION info;
    FsError error = GetFileInformationByHandle(entry, &info) ? 0 : GetLastError();
    if (!error && recursive && (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) &&
        !(info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
        wchar_t* pattern = Join(path, L"*");
        if (!pattern) error = ERROR_NOT_ENOUGH_MEMORY;
        else {
            WIN32_FIND_DATAW data;
            HANDLE find = FindFirstFileW(pattern, &data);
            free(pattern);
            if (find == INVALID_HANDLE_VALUE) {
                error = GetLastError();
                if (error == ERROR_FILE_NOT_FOUND) error = 0;
            } else {
                for (;;) {
                    if (wcscmp(data.cFileName, L".") != 0 && wcscmp(data.cFileName, L"..") != 0) {
                        wchar_t* child = Join(path, data.cFileName);
                        if (!child) error = ERROR_NOT_ENOUGH_MEMORY;
                        else { error = RemoveTree(child, true); free(child); }
                        if (error) break;
                    }
                    if (!FindNextFileW(find, &data)) {
                        error = GetLastError();
                        if (error == ERROR_NO_MORE_FILES) error = 0;
                        break;
                    }
                }
                FindClose(find);
            }
        }
    }
    CloseHandle(entry);
    if (error) return error;
    BOOL removed = (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? RemoveDirectoryW(path) : DeleteFileW(path);
    if (removed) return 0;
    error = GetLastError();
    return Missing(error) ? 0 : error;
}
#endif

static int Remove(lua_State* L) {
    bool recursive = Option(L, 2, "recursive", false);
    State* state = NewState(L);
    PathChar* path = Path(L, state, 0, 1);
    // Trailing separators must not turn a symlink into a traversal of its target.
    TrimTrailingSeparators(path);
#ifdef _WIN32
    FsError error = RemoveTree(path, recursive);
#else
    FsError error = RemoveAt(AT_FDCWD, path, recursive);
#endif
    if (error) return Fail(L, "remove", lua_tostring(L, 1), error);
    return 0;
}

static int Rename(lua_State* L) {
    State* state = NewState(L);
    PathChar* from = Path(L, state, 0, 1);
    PathChar* to = Path(L, state, 1, 2);
#ifdef _WIN32
    if (!MoveFileExW(from, to, MOVEFILE_REPLACE_EXISTING)) return Fail(L, "rename", lua_tostring(L, 1), GetLastError());
#else
    if (rename(from, to) < 0) return Fail(L, "rename", lua_tostring(L, 1), errno);
#endif
    return 0;
}

static int MakeExecutable(lua_State* L) {
    State* state = NewState(L);
    PathChar* path = Path(L, state, 0, 1);
#ifndef _WIN32
    struct stat info;
    if (stat(path, &info) < 0) return Fail(L, "make_executable", lua_tostring(L, 1), errno);
    if (chmod(path, info.st_mode | S_IXUSR | S_IXGRP | S_IXOTH) < 0)
        return Fail(L, "make_executable", lua_tostring(L, 1), errno);
#else
    (void)path;
#endif
    return 0;
}

void RegisterFs(lua_State* L) {
    if (luaL_newmetatable(L, "dotcmd.fs")) {
        lua_pushcfunction(L, Cleanup); lua_setfield(L, -2, "__close");
        lua_pushcfunction(L, Cleanup); lua_setfield(L, -2, "__gc");
    }
    lua_pop(L, 1);
    const luaL_Reg functions[] = {
        {"stat", Stat}, {"list", List}, {"mkdir", Mkdir}, {"remove", Remove},
        {"rename", Rename}, {"make_executable", MakeExecutable}, {NULL, NULL},
    };
    luaL_newlib(L, functions);
    lua_setglobal(L, "fs");
}
