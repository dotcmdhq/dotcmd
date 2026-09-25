#include "extract.h"
#include "api.h"
#include "fs.h"
#include <archive.h>
#include <archive_entry.h>
#include <errno.h>
#include <locale.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>
#else
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/syscall.h>
#endif
#endif
extern "C" {
#include "lua.h"
#include "lauxlib.h"
}

struct Link {
    Link* next;
    struct archive_entry* entry;
    char* target;
    bool hard;
    bool done;
};
struct State {
    struct archive* reader;
    struct archive* writer;
    Link* links;
    char* destination;
    char* temporary;
    char* scratch[4];
    bool staged;
    int if_exists;
#ifdef _WIN32
    char* previous_locale;
    int previous_locale_mode;
    bool locale_changed;
#else
    locale_t locale;
    locale_t previous_locale;
#endif
};

static int Cleanup(lua_State* L) {
    State* s = (State*)lua_touserdata(L, 1);
    if (s->reader) { archive_read_free(s->reader); s->reader = NULL; }
    if (s->writer) { archive_write_free(s->writer); s->writer = NULL; }
#ifdef _WIN32
    if (s->previous_locale) { setlocale(LC_CTYPE, s->previous_locale); free(s->previous_locale); s->previous_locale = NULL; }
    if (s->locale_changed) { _configthreadlocale(s->previous_locale_mode); s->locale_changed = false; }
#else
    if (s->locale) { uselocale(s->previous_locale); freelocale(s->locale); s->locale = (locale_t)0; }
#endif
    while (s->links) {
        Link* link = s->links; s->links = link->next;
        archive_entry_free(link->entry); free(link->target); free(link);
    }
    bool removed = !s->staged || RemoveFsTree(s->temporary);
    if (!removed) lua_pushstring(L, s->temporary);
    s->staged = false;
    free(s->temporary); s->temporary = NULL;
    free(s->destination); s->destination = NULL;
    for (int i = 0; i < 4; ++i) { free(s->scratch[i]); s->scratch[i] = NULL; }
    if (!removed) return luaL_error(L, "extract: cannot clean up temporary directory %s", lua_tostring(L, -1));
    return 0;
}

static char* Copy(lua_State* L, char** slot, const char* text) {
    size_t size = strlen(text) + 1;
    char* copy = (char*)malloc(size);
    if (!copy) luaL_error(L, "extract: out of memory");
    memcpy(copy, text, size);
    free(*slot); *slot = copy;
    return copy;
}

static const char* String(lua_State* L, int index) {
    luaL_checktype(L, index, LUA_TSTRING);
    size_t size;
    const char* value = lua_tolstring(L, index, &size);
    if (!size || memchr(value, 0, size)) luaL_error(L, "extract: paths must be nonempty strings without NUL bytes");
    return value;
}

static void Check(lua_State* L, struct archive* a, int code) {
    if (code == ARCHIVE_OK) return;
    const char* message = archive_error_string(a) ? archive_error_string(a) : "archive operation failed";
    int error = archive_errno(a);
    if (error) luaL_error(L, "extract: %s (%s)", message, strerror(error));
    luaL_error(L, "extract: %s", message);
}

#ifdef _WIN32
// Temporary conversions are Lua-owned, including when a Windows call fails.
static wchar_t* Wide(lua_State* L, const char* text) {
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, NULL, 0);
    if (!count) luaL_error(L, "extract: invalid UTF-8 path");
    wchar_t* wide = (wchar_t*)lua_newuserdatauv(L, (size_t)count * sizeof(wchar_t), 0);
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, wide, count);
    // Extended Windows paths require backslashes, including appended components.
    for (wchar_t* p = wide; *p; ++p) if (*p == L'/') *p = L'\\';
    return wide;
}
#endif

static char* Canonical(lua_State* L, char** slot, const char* path) {
#ifdef _WIN32
    wchar_t* wide = Wide(L, path);
    HANDLE file = CreateFileW(wide, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
    lua_pop(L, 1);
    if (file == INVALID_HANDLE_VALUE) luaL_error(L, "extract: cannot resolve %s (Windows error %d)", path, (int)GetLastError());
    wchar_t resolved[32768];
    DWORD count = GetFinalPathNameByHandleW(file, resolved, 32768, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    DWORD error = GetLastError(); CloseHandle(file);
    if (!count || count >= 32768) luaL_error(L, "extract: cannot resolve %s (Windows error %d)", path, (int)error);
    int bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, resolved, -1, NULL, 0, NULL, NULL);
    if (!bytes) luaL_error(L, "extract: invalid Unicode path");
    char* utf8 = (char*)lua_newuserdatauv(L, (size_t)bytes, 0);
    WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, resolved, -1, utf8, bytes, NULL, NULL);
    char* result = Copy(L, slot, utf8); lua_pop(L, 1);
#else
    char* result = realpath(path, NULL);
    if (!result) luaL_error(L, "extract: cannot resolve %s: %s", path, strerror(errno));
    free(*slot); *slot = result;
#endif
    return result;
}

static bool Exists(lua_State* L, const char* path) {
#ifdef _WIN32
    wchar_t* wide = Wide(L, path);
    DWORD attributes = GetFileAttributesW(wide), error = GetLastError(); lua_pop(L, 1);
    if (attributes != INVALID_FILE_ATTRIBUTES) return true;
    if (error != ERROR_FILE_NOT_FOUND && error != ERROR_PATH_NOT_FOUND)
        luaL_error(L, "extract: cannot inspect %s (Windows error %d)", path, (int)error);
#else
    struct stat info;
    if (lstat(path, &info) == 0) return true;
    if (errno != ENOENT) luaL_error(L, "extract: cannot inspect %s: %s", path, strerror(errno));
#endif
    return false;
}

static bool Separator(char c) { return c == '/' || c == '\\'; }

// Archive names are portable relative paths. Normalize dot components before
// matching/stripping; never let stripping hide traversal or absolute paths.
static char* Normalize(lua_State* L, char** slot, const char* input, bool parents = false) {
    if (!input || Separator(*input) || strchr(input, ':')) luaL_error(L, "extract: unsafe archive path");
    char* path = Copy(L, slot, input);
    size_t out = 0;
    for (size_t i = 0; input[i];) {
        while (Separator(input[i])) ++i;
        size_t start = i;
        while (input[i] && !Separator(input[i])) ++i;
        size_t size = i - start;
        if (!size || (size == 1 && input[start] == '.')) continue;
        if (size == 2 && input[start] == '.' && input[start + 1] == '.') {
            if (!parents || !out) luaL_error(L, "extract: archive path escapes the destination");
            while (out && path[out - 1] != '/') --out;
            if (out) --out;
            continue;
        }
#ifdef _WIN32
        // Windows aliases (ADS, device names, trailing dots/spaces) must not
        // bypass duplicate checks or resolve outside ordinary filesystem files.
        if (input[start + size - 1] == '.' || input[start + size - 1] == ' ')
            luaL_error(L, "extract: unsafe Windows archive path");
        char stem[5] = {}; size_t stem_size = 0;
        while (stem_size < size && input[start + stem_size] != '.') ++stem_size;
        while (stem_size && input[start + stem_size - 1] == ' ') --stem_size;
        for (size_t n = 0; n < stem_size && n < 4; ++n) {
            char c = input[start + n]; stem[n] = c >= 'a' && c <= 'z' ? c - 32 : c;
        }
        if (stem_size <= 4 && (!strcmp(stem, "CON") || !strcmp(stem, "PRN") || !strcmp(stem, "AUX") || !strcmp(stem, "NUL") ||
            ((strncmp(stem, "COM", 3) == 0 || strncmp(stem, "LPT", 3) == 0) && stem[3] >= '0' && stem[3] <= '9')))
            luaL_error(L, "extract: unsafe Windows device path");
        for (size_t j = 0; j < size; ++j)
            if ((unsigned char)input[start + j] < 32 || strchr("<>\"|?*", input[start + j]))
                luaL_error(L, "extract: unsafe Windows archive path");
#endif
        if (out) path[out++] = '/';
        memcpy(path + out, input + start, size); out += size;
    }
    path[out] = 0;
    return path;
}

static const char* Strip(const char* path, lua_Integer count) {
    while (*path && count-- > 0) {
        const char* slash = strchr(path, '/');
        path = slash ? slash + 1 : path + strlen(path);
    }
    return path;
}

static bool PrepareDestination(lua_State* L, State* s, const char* path) {
    Copy(L, &s->scratch[0], path);
    char* output = s->scratch[0];
#ifdef _WIN32
    for (char* p = output; *p; ++p) if (*p == '\\') *p = '/';
#endif
    size_t length = strlen(output);
    while (length > 1 && output[length - 1] == '/') output[--length] = 0;
    char* slash = strrchr(output, '/');
    const char* base = slash ? slash + 1 : output;
    if (!*base || !strcmp(base, ".") || !strcmp(base, "..")) luaL_error(L, "extract: destination must name a new directory");
    Copy(L, &s->scratch[1], base);
    if (slash) *slash = 0;
    Canonical(L, &s->scratch[2], slash ? (*output ? output : "/") : ".");
    lua_pushfstring(L, "%s/%s", s->scratch[2], s->scratch[1]);
    Copy(L, &s->destination, lua_tostring(L, -1)); lua_pop(L, 1);
    if (Exists(L, s->destination)) {
        if (s->if_exists == 1) return false;
        if (s->if_exists == 0) luaL_error(L, "extract: destination already exists: %s", s->destination);
    }
    lua_pushfstring(L, "%s.extract-XXXXXXXXXXXXXXXX", s->destination);
    Copy(L, &s->temporary, lua_tostring(L, -1)); lua_pop(L, 1);
#ifdef _WIN32
    size_t prefix = strlen(s->temporary) - 16;
    for (;;) {
        unsigned char random[8];
        if (BCryptGenRandom(NULL, random, sizeof(random), BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0)
            luaL_error(L, "extract: cannot generate temporary directory name");
        for (size_t i = 0; i < sizeof(random); ++i) sprintf(s->temporary + prefix + i * 2, "%02x", random[i]);
        wchar_t* wide = Wide(L, s->temporary);
        BOOL created = CreateDirectoryW(wide, NULL); DWORD error = GetLastError(); lua_pop(L, 1);
        if (created) break;
        if (error != ERROR_ALREADY_EXISTS) luaL_error(L, "extract: cannot create temporary directory (Windows error %d)", (int)error);
    }
#else
    if (!mkdtemp(s->temporary)) luaL_error(L, "extract: cannot create temporary directory: %s", strerror(errno));
#endif
    s->staged = true;
    return true;
}

static bool Publish(lua_State* L, State* s) {
#ifdef _WIN32
    wchar_t* from = Wide(L, s->temporary);
    wchar_t* to = Wide(L, s->destination);
    if (MoveFileExW(from, to, 0)) { s->staged = false; return true; }
    DWORD error = GetLastError();
    if (error != ERROR_ALREADY_EXISTS && error != ERROR_FILE_EXISTS)
        luaL_error(L, "extract: cannot publish destination (Windows error %d)", (int)error);
    if (s->if_exists == 1) return false;
    if (s->if_exists == 0) luaL_error(L, "extract: destination already exists: %s", s->destination);
    // Windows cannot exchange directories. Keep the old tree until publication succeeds.
    const char* backup = lua_pushfstring(L, "%s.old", s->temporary);
    wchar_t* old = Wide(L, backup);
    if (!MoveFileExW(to, old, 0))
        luaL_error(L, "extract: cannot move existing destination (Windows error %d)", (int)GetLastError());
    if (!MoveFileExW(from, to, 0)) {
        error = GetLastError();
        if (!MoveFileExW(old, to, 0))
            luaL_error(L, "extract: cannot publish destination (Windows error %d); original saved at %s", (int)error, backup);
        luaL_error(L, "extract: cannot publish destination (Windows error %d)", (int)error);
    }
    s->staged = false;
    if (!RemoveFsTree(backup)) luaL_error(L, "extract: cannot remove previous destination %s", backup);
    return true;
#else
    for (;;) {
        if (s->if_exists == 2) {
#ifdef __linux__
            int swapped = (int)syscall(SYS_renameat2, AT_FDCWD, s->temporary, AT_FDCWD, s->destination, 2 /* RENAME_EXCHANGE */);
#else
            int swapped = renamex_np(s->temporary, s->destination, RENAME_SWAP);
#endif
            // The old tree is now at temporary; the normal cleanup removes it.
            if (swapped == 0) return true;
            if (errno != ENOENT) luaL_error(L, "extract: cannot replace destination: %s", strerror(errno));
        }
#ifdef __linux__
        int moved = (int)syscall(SYS_renameat2, AT_FDCWD, s->temporary, AT_FDCWD, s->destination, 1 /* RENAME_NOREPLACE */);
#else
        int moved = renamex_np(s->temporary, s->destination, RENAME_EXCL);
#endif
        if (moved == 0) { s->staged = false; return true; }
        if (errno == EEXIST || errno == ENOTEMPTY) {
            if (s->if_exists == 1) return false;
            if (s->if_exists == 2) continue;
            luaL_error(L, "extract: destination already exists: %s", s->destination);
        }
        luaL_error(L, "extract: cannot publish destination: %s", strerror(errno));
    }
#endif
}

static void FinishEntry(lua_State* L, State* s, struct archive_entry* entry, bool data) {
    Check(L, s->writer, archive_write_header(s->writer, entry));
    if (data) {
        const void* buffer; size_t size; la_int64_t offset;
        for (;;) {
            int result = archive_read_data_block(s->reader, &buffer, &size, &offset);
            if (result == ARCHIVE_EOF) break;
            Check(L, s->reader, result);
            Check(L, s->writer, (int)archive_write_data_block(s->writer, buffer, size, offset));
        }
    }
    Check(L, s->writer, archive_write_finish_entry(s->writer));
}

static int Extract(lua_State* L) {
    int supplied = lua_gettop(L);
    bool options = lua_istable(L, 1);
    if (supplied < 1 || supplied > (options ? 1 : 2))
        return luaL_error(L, "extract expects a path, a path and destination, or an options table");
    if (options) lua_getfield(L, 1, "path"); else lua_pushvalue(L, 1);
    const char* input = String(L, -1);
    State* s = (State*)lua_newuserdatauv(L, sizeof(State), 0);
    memset(s, 0, sizeof(*s)); luaL_setmetatable(L, "dotcmd.extract"); lua_toclose(L, -1);
    static const char* const policies[] = {"error", "skip", "replace", NULL};
    if (options) lua_getfield(L, 1, "if_exists"); else lua_pushnil(L);
    s->if_exists = luaL_checkoption(L, -1, "error", policies); lua_pop(L, 1);
    lua_Integer strip = 0;
    if (options) {
        lua_getfield(L, 1, "strip_components");
        if (!lua_isnil(L, -1)) strip = luaL_checkinteger(L, -1);
        lua_pop(L, 1);
        if (strip < 0) return luaL_error(L, "extract: strip_components must be nonnegative");
        lua_getfield(L, 1, "to");
    } else if (supplied == 2) lua_pushvalue(L, 2);
    else lua_pushnil(L);
    if (lua_isnil(L, -1)) {
        Copy(L, &s->scratch[3], input);
        char* path = s->scratch[3]; size_t size = strlen(path);
        const char* suffixes[] = {".tar.gz", ".tar.xz", ".tgz", ".txz", ".zip", ".tar"};
        bool removed = false;
        for (size_t i = 0; i < sizeof(suffixes) / sizeof(*suffixes); ++i) {
            size_t n = strlen(suffixes[i]);
            if (size > n && !strcmp(path + size - n, suffixes[i])) { path[size - n] = 0; removed = true; break; }
        }
        if (removed) lua_pushstring(L, path); else lua_pushfstring(L, "%s.unpacked", path);
    }
    bool prepared = PrepareDestination(L, s, String(L, -1)); lua_pop(L, 1);
    if (!prepared) { lua_pushboolean(L, false); return 1; }
    if (options) lua_getfield(L, 1, "include"); else lua_pushnil(L);
    int filters = lua_gettop(L);
    size_t count = 0;
    if (!lua_isnil(L, filters)) {
        luaL_checktype(L, filters, LUA_TTABLE); count = lua_rawlen(L, filters);
        if (!count) return luaL_error(L, "extract: include must be a nonempty array");
        lua_pushnil(L);
        while (lua_next(L, filters)) {
            if (!lua_isinteger(L, -2) || lua_tointeger(L, -2) < 1 || (lua_Unsigned)lua_tointeger(L, -2) > count)
                return luaL_error(L, "extract: include must be an array of paths");
            String(L, -1); lua_pop(L, 1);
        }
    }
    lua_newtable(L); int matches = lua_gettop(L);
    lua_newtable(L); int normalized_filters = lua_gettop(L);
    for (size_t i = 1; i <= count; ++i) {
        lua_rawgeti(L, filters, (lua_Integer)i);
        char* name = Normalize(L, &s->scratch[0], String(L, -1));
        if (!*name) return luaL_error(L, "extract: include paths must name an entry");
        lua_pushstring(L, name); lua_rawseti(L, normalized_filters, (lua_Integer)i); lua_pop(L, 1);
    }
    lua_newtable(L); int outputs = lua_gettop(L);
    // libarchive converts ZIP/PAX names using the current C locale. Keep this
    // UTF-8 setting local to extraction, without changing the caller's locale.
#ifdef _WIN32
    s->previous_locale_mode = _configthreadlocale(_ENABLE_PER_THREAD_LOCALE);
    s->locale_changed = true;
    Copy(L, &s->previous_locale, setlocale(LC_CTYPE, NULL));
    if (!setlocale(LC_CTYPE, ".UTF8")) return luaL_error(L, "extract: cannot select UTF-8 locale");
#else
#ifdef __APPLE__
    s->locale = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", (locale_t)0);
#else
    s->locale = newlocale(LC_CTYPE_MASK, "C.UTF-8", (locale_t)0);
#endif
    if (!s->locale) return luaL_error(L, "extract: cannot select UTF-8 locale");
    s->previous_locale = uselocale(s->locale);
#endif
    s->reader = archive_read_new(); s->writer = archive_write_disk_new();
    if (!s->reader || !s->writer) return luaL_error(L, "extract: out of memory");
    Check(L, s->reader, archive_read_support_filter_none(s->reader));
    Check(L, s->reader, archive_read_support_filter_gzip(s->reader));
    Check(L, s->reader, archive_read_support_filter_xz(s->reader));
    Check(L, s->reader, archive_read_support_format_tar(s->reader));
    Check(L, s->reader, archive_read_support_format_zip(s->reader));
    // Plain tar headers use UTF-8, not the Windows OEM code page.
    Check(L, s->reader, archive_read_set_format_option(s->reader, "tar", "hdrcharset", "UTF-8"));
    Check(L, s->writer, archive_write_disk_set_options(s->writer,
        ARCHIVE_EXTRACT_SECURE_NODOTDOT | ARCHIVE_EXTRACT_SECURE_SYMLINKS | ARCHIVE_EXTRACT_NO_OVERWRITE));
#ifdef _WIN32
    wchar_t* wide = Wide(L, input);
    int opened = archive_read_open_filename_w(s->reader, wide, 65536); lua_pop(L, 1);
    Check(L, s->reader, opened);
#else
    Check(L, s->reader, archive_read_open_filename(s->reader, input, 65536));
#endif
    struct archive_entry* entry;
    for (;;) {
        int result = archive_read_next_header(s->reader, &entry);
        if (result == ARCHIVE_EOF) break;
        Check(L, s->reader, result);
        if (archive_entry_is_encrypted(entry)) return luaL_error(L, "extract: encrypted archives are not supported");
        const char* name = Normalize(L, &s->scratch[0], archive_entry_pathname(entry));
        bool selected = !count;
        for (size_t i = 1; i <= count; ++i) {
            lua_rawgeti(L, normalized_filters, (lua_Integer)i); const char* filter = lua_tostring(L, -1);
            size_t n = strlen(filter);
            if (!strncmp(name, filter, n) && (name[n] == 0 || name[n] == '/')) {
                selected = true; lua_pushboolean(L, true); lua_rawseti(L, matches, (lua_Integer)i);
            }
            lua_pop(L, 1);
        }
        const char* output = Strip(name, strip);
        if (!selected || !*output) { Check(L, s->reader, archive_read_data_skip(s->reader)); continue; }
        lua_getfield(L, outputs, output);
        bool duplicate = !lua_isnil(L, -1); lua_pop(L, 1);
        if (duplicate) return luaL_error(L, "extract: duplicate output path: %s", output);
        lua_pushboolean(L, true); lua_setfield(L, outputs, output);
        lua_pushfstring(L, "%s/%s", s->temporary, output);
        Copy(L, &s->scratch[1], lua_tostring(L, -1)); lua_pop(L, 1);
        const char* hard = archive_entry_hardlink(entry);
        const char* symbolic = archive_entry_symlink(entry);
        int type = archive_entry_filetype(entry);
        if (type != AE_IFDIR && Exists(L, s->scratch[1]))
            return luaL_error(L, "extract: output path already exists: %s", output);
        if (hard || symbolic) {
            Link* link = (Link*)calloc(1, sizeof(Link));
            if (!link) return luaL_error(L, "extract: out of memory");
            link->next = s->links; s->links = link; link->hard = hard != NULL;
            link->entry = archive_entry_clone(entry);
            if (!link->entry) return luaL_error(L, "extract: out of memory");
            archive_entry_copy_pathname(link->entry, s->scratch[1]);
            const char* target;
            if (hard) target = Strip(Normalize(L, &s->scratch[2], hard), strip);
            else {
                if (Separator(*symbolic) || strchr(symbolic, ':')) return luaL_error(L, "extract: unsafe symbolic link target");
                const char* slash = strrchr(output, '/');
                if (slash) lua_pushfstring(L, "%s/%s", lua_pushlstring(L, output, (size_t)(slash - output)), symbolic);
                else lua_pushstring(L, symbolic);
                target = Normalize(L, &s->scratch[2], lua_tostring(L, -1), true);
                lua_pop(L, slash ? 2 : 1);
            }
            lua_pushfstring(L, "%s/%s", s->temporary, target);
            Copy(L, &link->target, lua_tostring(L, -1)); lua_pop(L, 1);
            if (hard) archive_entry_copy_hardlink(link->entry, link->target);
            archive_entry_set_size(link->entry, 0);
            Check(L, s->reader, archive_read_data_skip(s->reader));
        } else {
            if (type != AE_IFREG && type != AE_IFDIR) return luaL_error(L, "extract: unsupported archive entry type: %s", name);
            archive_entry_copy_pathname(entry, s->scratch[1]);
            archive_entry_set_perm(entry, type == AE_IFDIR ? 0777 : 0666 | (archive_entry_perm(entry) & 0111));
            FinishEntry(L, s, entry, type == AE_IFREG);
        }
    }
    Check(L, s->reader, archive_read_close(s->reader));
    for (size_t i = 1; i <= count; ++i) {
        lua_rawgeti(L, matches, (lua_Integer)i); bool found = lua_toboolean(L, -1); lua_pop(L, 1);
        if (!found) { lua_rawgeti(L, filters, (lua_Integer)i); return luaL_error(L, "extract: include matched nothing: %s", lua_tostring(L, -1)); }
    }
    // Create hardlinks before symlinks; data writes can never traverse links.
    // Multiple passes allow forward hardlinks, but reject missing targets/cycles.
    for (;;) {
        bool pending = false, progress = false;
        for (Link* link = s->links; link; link = link->next) {
            if (!link->hard || link->done) continue;
            pending = true;
            if (Exists(L, link->target)) {
                if (Exists(L, archive_entry_pathname(link->entry))) return luaL_error(L, "extract: link conflicts with an extracted path");
                FinishEntry(L, s, link->entry, false); link->done = true; progress = true;
            }
        }
        if (!pending) break;
        if (!progress) return luaL_error(L, "extract: hardlink target was not extracted or contains a cycle");
    }
    for (;;) {
        bool pending = false, progress = false;
        for (Link* link = s->links; link; link = link->next) {
            if (link->done) continue;
            pending = true;
            if (!Exists(L, link->target)) continue;
            if (Exists(L, archive_entry_pathname(link->entry))) return luaL_error(L, "extract: link conflicts with an extracted path");
#ifdef _WIN32
            wchar_t* target = Wide(L, link->target);
            DWORD attributes = GetFileAttributesW(target); lua_pop(L, 1);
            archive_entry_set_symlink_type(link->entry, (attributes & FILE_ATTRIBUTE_DIRECTORY)
                ? AE_SYMLINK_TYPE_DIRECTORY : AE_SYMLINK_TYPE_FILE);
#endif
            FinishEntry(L, s, link->entry, false); link->done = true; progress = true;
        }
        if (!pending) break;
        if (!progress) return luaL_error(L, "extract: symbolic link target was not extracted or contains a cycle");
    }
    Check(L, s->writer, archive_write_close(s->writer));
    // Validate actual link resolution, including chains and '..' through links,
    // before publishing. Dangling/omitted targets and cycles are errors too.
    Canonical(L, &s->scratch[0], s->temporary);
    size_t root = strlen(s->scratch[0]);
    for (Link* link = s->links; link; link = link->next) {
        if (link->hard) continue;
        const char* resolved = Canonical(L, &s->scratch[1], archive_entry_pathname(link->entry));
        if (strncmp(resolved, s->scratch[0], root) || (resolved[root] && !Separator(resolved[root])))
            return luaL_error(L, "extract: symbolic link escapes the destination");
    }
    lua_pushboolean(L, Publish(L, s));
    return 1;
}

void RegisterExtract(lua_State* L) {
    if (luaL_newmetatable(L, "dotcmd.extract")) {
        lua_pushcfunction(L, Cleanup); lua_setfield(L, -2, "__close");
        lua_pushcfunction(L, Cleanup); lua_setfield(L, -2, "__gc");
    }
    lua_pop(L, 1);
    RegisterFunction(L, "extract", Extract);
}
