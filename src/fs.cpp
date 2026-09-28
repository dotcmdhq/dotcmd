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
#include <bcrypt.h>
#include <fcntl.h>
#include <io.h>
typedef wchar_t PathChar;
typedef DWORD FsError;
#else
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/syscall.h>
#endif
typedef char PathChar;
typedef int FsError;
#endif
extern "C" {
#include "lua.h"
#include "lauxlib.h"
}

struct State {
    PathChar* paths[3];
    FILE* file;
    bool temporary;
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
    if (state->file) { fclose(state->file); state->file = NULL; }
    if (state->temporary) {
#ifdef _WIN32
        DeleteFileW(state->paths[2]);
#else
        unlink(state->paths[2]);
#endif
        state->temporary = false;
    }
    for (int i = 0; i < 3; ++i) { free(state->paths[i]); state->paths[i] = NULL; }
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
    lua_pushinteger(L, 0); lua_setfield(L, -2, "mode");
#else
    struct stat info;
    if ((follow ? stat(path, &info) : lstat(path, &info)) < 0) {
        if (Missing(errno)) { lua_pushnil(L); return 1; }
        return Fail(L, "stat", lua_tostring(L, 1), errno);
    }
    const char* type = S_ISREG(info.st_mode) ? "file" : S_ISDIR(info.st_mode) ? "directory" : S_ISLNK(info.st_mode) ? "symlink" : "other";
    Attributes(L, type, (uint64_t)info.st_size);
    lua_pushinteger(L, info.st_mode & 0777); lua_setfield(L, -2, "mode");
#endif
    return 1;
}

static int Realpath(lua_State* L) {
    State* state = NewState(L);
    PathChar* path = Path(L, state, 0, 1);
#ifdef _WIN32
    HANDLE file = CreateFileW(path, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
    if (file == INVALID_HANDLE_VALUE) return Fail(L, "realpath", lua_tostring(L, 1), GetLastError());
    DWORD needed = GetFinalPathNameByHandleW(file, NULL, 0, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    if (!needed) {
        FsError error = GetLastError(); CloseHandle(file);
        return Fail(L, "realpath", lua_tostring(L, 1), error);
    }
    state->paths[1] = (wchar_t*)malloc((size_t)needed * sizeof(wchar_t));
    if (!state->paths[1]) { CloseHandle(file); return luaL_error(L, "fs: out of memory"); }
    DWORD size = GetFinalPathNameByHandleW(file, state->paths[1], needed, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    FsError error = !size ? GetLastError() : size >= needed ? ERROR_INSUFFICIENT_BUFFER : 0;
    CloseHandle(file);
    if (error) return Fail(L, "realpath", lua_tostring(L, 1), error);
    int bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, state->paths[1], -1, NULL, 0, NULL, NULL);
    if (!bytes) return Fail(L, "realpath", lua_tostring(L, 1), GetLastError());
    luaL_Buffer buffer;
    char* utf8 = luaL_buffinitsize(L, &buffer, (size_t)bytes);
    if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, state->paths[1], -1, utf8, bytes, NULL, NULL))
        return Fail(L, "realpath", lua_tostring(L, 1), GetLastError());
    luaL_pushresultsize(&buffer, (size_t)bytes - 1);
#else
    state->paths[1] = realpath(path, NULL);
    if (!state->paths[1]) return Fail(L, "realpath", lua_tostring(L, 1), errno);
    lua_pushstring(L, state->paths[1]);
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

static FsError CreateParents(PathChar* path) {
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
        if (error) return error;
    }
    return 0;
}

static int Mkdir(lua_State* L) {
    State* state = NewState(L);
    PathChar* path = Path(L, state, 0, 1);
    FsError error = CreateParents(path);
    if (error) return Fail(L, "mkdir", lua_tostring(L, 1), error);
    error = MakeDirectory(path);
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

static FsError MovePath(const PathChar* from, const PathChar* to, bool replace) {
#ifdef _WIN32
    return MoveFileExW(from, to, replace ? MOVEFILE_REPLACE_EXISTING : 0) ? 0 : GetLastError();
#else
#ifdef __linux__
    int result = replace ? rename(from, to)
        : (int)syscall(SYS_renameat2, AT_FDCWD, from, AT_FDCWD, to, 1 /* RENAME_NOREPLACE */);
#else
    int result = replace ? rename(from, to) : renamex_np(from, to, RENAME_EXCL);
#endif
    return result == 0 ? 0 : errno;
#endif
}

static bool Exists(FsError error) {
#ifdef _WIN32
    return error == ERROR_ALREADY_EXISTS || error == ERROR_FILE_EXISTS;
#else
    return error == EEXIST || error == ENOTEMPTY;
#endif
}

static int Rename(lua_State* L) {
    static const char* const policies[] = {"error", "skip", "replace", NULL};
    if (lua_isnoneornil(L, 3)) lua_pushnil(L); else lua_getfield(L, 3, "if_exists");
    int policy = luaL_checkoption(L, -1, "error", policies); lua_pop(L, 1);
    State* state = NewState(L);
    PathChar* from = Path(L, state, 0, 1);
    PathChar* to = Path(L, state, 1, 2);
    FsError error = MovePath(from, to, policy == 2);
    if (error) {
        if (policy == 1 && Exists(error)) {
            lua_pushboolean(L, false);
            return 1;
        }
        return Fail(L, "rename", lua_tostring(L, 1), error);
    }
    lua_pushboolean(L, true);
    return 1;
}

// stdio reports errno on every platform, unlike the native path operations.
static int FileError(lua_State* L, const char* operation, int error) {
    return luaL_error(L, "fs.%s: %s: %s", operation, lua_tostring(L, 1), strerror(error));
}

static int CloseFile(State* state) {
    FILE* file = state->file;
    state->file = NULL;
    return fclose(file) == 0 ? 0 : errno;
}

static int Read(lua_State* L) {
    State* state = NewState(L);
    PathChar* path = Path(L, state, 0, 1);
#ifdef _WIN32
    state->file = _wfopen(path, L"rb");
#else
    state->file = fopen(path, "rb");
#endif
    if (!state->file) {
        int error = errno;
        if (error == ENOENT) { lua_pushnil(L); return 1; }
        return FileError(L, "read", error);
    }
    luaL_Buffer buffer;
    luaL_buffinit(L, &buffer);
    for (;;) {
        char* block = luaL_prepbuffsize(&buffer, 65536);
        size_t size = fread(block, 1, 65536, state->file);
        if (ferror(state->file)) return FileError(L, "read", errno);
        luaL_addsize(&buffer, size);
        if (feof(state->file)) break;
    }
    int error = CloseFile(state);
    if (error) return FileError(L, "read", error);
    luaL_pushresult(&buffer);
    return 1;
}

static void OpenTemporary(lua_State* L, State* state) {
#ifdef _WIN32
    size_t length = wcslen(state->paths[0]);
    state->paths[2] = (wchar_t*)malloc((length + 38) * sizeof(wchar_t));
    if (!state->paths[2]) luaL_error(L, "fs.write: out of memory");
    memcpy(state->paths[2], state->paths[0], length * sizeof(wchar_t));
    memcpy(state->paths[2] + length, L".tmp-", 5 * sizeof(wchar_t));
    HANDLE handle;
    do {
        unsigned char random[16];
        if (BCryptGenRandom(NULL, random, sizeof(random), BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0)
            luaL_error(L, "fs.write: cannot generate temporary filename");
        for (size_t i = 0; i < sizeof(random); ++i) {
            state->paths[2][length + 5 + i * 2] = L"0123456789abcdef"[random[i] >> 4];
            state->paths[2][length + 6 + i * 2] = L"0123456789abcdef"[random[i] & 15];
        }
        state->paths[2][length + 37] = 0;
        handle = CreateFileW(state->paths[2], GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    } while (handle == INVALID_HANDLE_VALUE && Exists(GetLastError()));
    if (handle == INVALID_HANDLE_VALUE) Fail(L, "write", lua_tostring(L, 1), GetLastError());
    state->temporary = true;
    int descriptor = _open_osfhandle((intptr_t)handle, _O_WRONLY | _O_BINARY | _O_NOINHERIT);
    if (descriptor == -1) {
        int error = errno; CloseHandle(handle); FileError(L, "write", error);
    }
    state->file = _fdopen(descriptor, "wb");
    if (!state->file) { int error = errno; _close(descriptor); FileError(L, "write", error); }
#else
    size_t length = strlen(state->paths[0]);
    state->paths[2] = (char*)malloc(length + sizeof(".tmp-XXXXXX"));
    if (!state->paths[2]) luaL_error(L, "fs.write: out of memory");
    memcpy(state->paths[2], state->paths[0], length);
    strcpy(state->paths[2] + length, ".tmp-XXXXXX");
    int descriptor = mkstemp(state->paths[2]);
    if (descriptor == -1) FileError(L, "write", errno);
    state->temporary = true;
    if (fcntl(descriptor, F_SETFD, FD_CLOEXEC) < 0) {
        int error = errno; close(descriptor); FileError(L, "write", error);
    }
    state->file = fdopen(descriptor, "wb");
    if (!state->file) { int error = errno; close(descriptor); FileError(L, "write", error); }
#endif
}

static int Inspect(lua_State* L, int path, bool follow) {
    lua_pushcfunction(L, Stat);
    lua_pushvalue(L, path);
    lua_createtable(L, 0, 1);
    lua_pushboolean(L, follow); lua_setfield(L, -2, "follow");
    lua_call(L, 2, 1);
    return lua_gettop(L);
}

static int Write(lua_State* L) {
    luaL_checktype(L, 2, LUA_TSTRING);
    size_t size;
    const char* bytes = lua_tolstring(L, 2, &size);
    bool parents = Option(L, 3, "parents", true);
    static const char* const policies[] = {"error", "skip", "replace", NULL};
    if (lua_isnoneornil(L, 3)) lua_pushnil(L); else lua_getfield(L, 3, "if_exists");
    int policy = luaL_checkoption(L, -1, "replace", policies); lua_pop(L, 1);
    State* state = NewState(L);
    PathChar* path = Path(L, state, 0, 1);
#ifdef _WIN32
    size_t length = wcslen(path);
    bool trailing_separator = path[length - 1] == '/' || path[length - 1] == '\\';
#else
    size_t length = strlen(path);
    bool trailing_separator = path[length - 1] == '/';
#endif
    if (trailing_separator) return luaL_error(L, "fs.write: %s: expected a file path", lua_tostring(L, 1));
    int info = Inspect(L, 1, false);
    if (!lua_isnil(L, info)) {
        if (policy == 1) { lua_pushboolean(L, false); return 1; }
        if (policy == 0) return luaL_error(L, "fs.write: %s already exists", lua_tostring(L, 1));
        lua_getfield(L, info, "type");
        bool link = strcmp(lua_tostring(L, -1), "symlink") == 0;
        lua_pop(L, 1);
        if (link) {
            lua_pushcfunction(L, Realpath); lua_pushvalue(L, 1); lua_call(L, 1, 1);
            int resolved = lua_gettop(L);
            free(state->paths[0]); state->paths[0] = NULL;
            path = Path(L, state, 0, resolved);
            info = Inspect(L, resolved, true);
        }
        lua_getfield(L, info, "type");
        bool regular = strcmp(lua_tostring(L, -1), "file") == 0;
        lua_pop(L, 1);
        if (!regular) return luaL_error(L, "fs.write: %s: expected a regular file", lua_tostring(L, 1));
    }
#ifndef _WIN32
    mode_t mode;
    if (lua_isnil(L, info)) {
        mode_t mask = umask(0); umask(mask);
        mode = 0666 & ~mask;
    } else {
        lua_getfield(L, info, "mode"); mode = (mode_t)lua_tointeger(L, -1); lua_pop(L, 1);
    }
#endif
    if (parents) {
        FsError error = CreateParents(path);
        if (error) return Fail(L, "write", lua_tostring(L, 1), error);
    }
    OpenTemporary(L, state);
    if (fwrite(bytes, 1, size, state->file) != size) return FileError(L, "write", errno);
    // Publish only after both buffered output and closing have succeeded.
    if (fflush(state->file) != 0) return FileError(L, "write", errno);
#ifndef _WIN32
    if (fchmod(fileno(state->file), mode) < 0) return FileError(L, "write", errno);
#endif
    int close_error = CloseFile(state);
    if (close_error) return FileError(L, "write", close_error);
    FsError error = MovePath(state->paths[2], path, policy == 2);
    if (error) {
        if (policy == 1 && Exists(error)) { lua_pushboolean(L, false); return 1; }
        return Fail(L, "write", lua_tostring(L, 1), error);
    }
    state->temporary = false;
    lua_pushboolean(L, true);
    return 1;
}

static int Chmod(lua_State* L) {
    bool add_execute = lua_type(L, 2) == LUA_TSTRING;
    lua_Integer mode = 0;
    if (add_execute) {
        size_t size;
        const char* symbolic = lua_tolstring(L, 2, &size);
        luaL_argcheck(L, size == 2 && memcmp(symbolic, "+x", 2) == 0, 2, "expected numeric mode or '+x'");
    } else {
        mode = luaL_checkinteger(L, 2);
        luaL_argcheck(L, mode >= 0 && mode <= 0777, 2, "expected permission bits between 0 and 0777");
    }
    State* state = NewState(L);
    PathChar* path = Path(L, state, 0, 1);
#ifndef _WIN32
    if (add_execute) {
        struct stat info;
        if (stat(path, &info) < 0) return Fail(L, "chmod", lua_tostring(L, 1), errno);
        mode_t mask = umask(0);
        umask(mask);
        mode = info.st_mode | ((S_IXUSR | S_IXGRP | S_IXOTH) & ~mask);
    }
    if (chmod(path, (mode_t)mode) < 0) return Fail(L, "chmod", lua_tostring(L, 1), errno);
#else
    (void)path;
#endif
    return 0;
}

bool RemoveFsTree(const char* path) {
#ifdef _WIN32
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
    if (!count) return false;
    wchar_t* wide = (wchar_t*)malloc((size_t)count * sizeof(wchar_t));
    if (!wide) return false;
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide, count);
    for (wchar_t* p = wide; *p; ++p) if (*p == L'/') *p = L'\\';
    FsError error = RemoveTree(wide, true);
    free(wide);
#else
    FsError error = RemoveAt(AT_FDCWD, path, true);
#endif
    return error == 0;
}

void RegisterFs(lua_State* L) {
    if (luaL_newmetatable(L, "dotcmd.fs")) {
        lua_pushcfunction(L, Cleanup); lua_setfield(L, -2, "__close");
        lua_pushcfunction(L, Cleanup); lua_setfield(L, -2, "__gc");
    }
    lua_pop(L, 1);
    const luaL_Reg functions[] = {
        {"stat", Stat}, {"realpath", Realpath}, {"list", List}, {"mkdir", Mkdir}, {"remove", Remove},
        {"rename", Rename}, {"chmod", Chmod}, {"read", Read}, {"write", Write}, {NULL, NULL},
    };
    luaL_newlib(L, functions);
    lua_setglobal(L, "fs");
}
