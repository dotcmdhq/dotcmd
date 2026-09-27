#include "json.h"
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "yyjson.h"
extern "C" {
#include "lua.h"
#include "lauxlib.h"
}

struct Frame {
    int table_ref;
    int is_object;
    size_t array_index;
    union {
        yyjson_arr_iter array;
        yyjson_obj_iter object;
    } iterator;
};

struct Document {
    yyjson_doc* value;
    Frame* frames;
    size_t frame_count;
    size_t frame_capacity;
};

static int Cleanup(lua_State* L) {
    Document* document = (Document*)lua_touserdata(L, 1);
    for (size_t i = 0; i < document->frame_count; ++i) {
        if (document->frames[i].table_ref != LUA_NOREF)
            luaL_unref(L, LUA_REGISTRYINDEX, document->frames[i].table_ref);
    }
    free(document->frames);
    document->frames = NULL;
    document->frame_count = 0;
    document->frame_capacity = 0;
    if (document->value) {
        yyjson_doc_free(document->value);
        document->value = NULL;
    }
    return 0;
}

static int Hint(size_t size) {
    return size <= INT_MAX ? (int)size : 0;
}

static void PushScalar(lua_State* L, yyjson_val* value) {
    if (yyjson_is_null(value)) {
        lua_pushnil(L);
    } else if (yyjson_is_bool(value)) {
        lua_pushboolean(L, yyjson_get_bool(value));
    } else if (yyjson_is_sint(value)) {
        lua_pushinteger(L, (lua_Integer)yyjson_get_sint(value));
    } else if (yyjson_is_uint(value)) {
        uint64_t number = yyjson_get_uint(value);
        if (number > (uint64_t)LUA_MAXINTEGER) {
            luaL_error(L, "json.decode: integer is outside Lua's range");
            return;
        }
        lua_pushinteger(L, (lua_Integer)number);
    } else if (yyjson_is_real(value)) {
        lua_pushnumber(L, (lua_Number)yyjson_get_real(value));
    } else if (yyjson_is_raw(value)) {
        luaL_error(L, "json.decode: number is outside Lua's range");
        return;
    } else {
        lua_pushlstring(L, yyjson_get_str(value), yyjson_get_len(value));
    }
}

static Frame* AddFrame(lua_State* L, Document* document, yyjson_val* value) {
    if (document->frame_count == document->frame_capacity) {
        size_t capacity = document->frame_capacity ? document->frame_capacity * 2 : 16;
        if (capacity < document->frame_capacity || capacity > SIZE_MAX / sizeof(Frame)) {
            luaL_error(L, "json.decode: nesting is too deep");
            return NULL;
        }
        Frame* frames = (Frame*)realloc(document->frames, capacity * sizeof(Frame));
        if (!frames) {
            luaL_error(L, "json.decode: out of memory");
            return NULL;
        }
        document->frames = frames;
        document->frame_capacity = capacity;
    }

    Frame* frame = &document->frames[document->frame_count++];
    frame->table_ref = LUA_NOREF;
    frame->is_object = yyjson_is_obj(value);
    frame->array_index = 1;
    if (frame->is_object)
        frame->iterator.object = yyjson_obj_iter_with(value);
    else
        frame->iterator.array = yyjson_arr_iter_with(value);

    if (frame->is_object)
        lua_createtable(L, 0, Hint(yyjson_obj_size(value)));
    else
        lua_createtable(L, Hint(yyjson_arr_size(value)), 0);
    luaL_setmetatable(L, frame->is_object ? "dotcmd.json.object" : "dotcmd.json.array");
    frame->table_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    return frame;
}

static void PushValue(lua_State* L, Document* document, yyjson_val* root) {
    if (!yyjson_is_ctn(root)) {
        PushScalar(L, root);
        return;
    }

    AddFrame(L, document, root);
    while (document->frame_count) {
        Frame* frame = &document->frames[document->frame_count - 1];
        yyjson_val* key = NULL;
        yyjson_val* value;
        size_t array_index = 0;

        if (frame->is_object) {
            key = yyjson_obj_iter_next(&frame->iterator.object);
            value = key ? yyjson_obj_iter_get_val(key) : NULL;
        } else {
            value = yyjson_arr_iter_next(&frame->iterator.array);
            array_index = frame->array_index++;
        }

        if (!value) {
            if (document->frame_count == 1) {
                lua_rawgeti(L, LUA_REGISTRYINDEX, frame->table_ref);
                luaL_unref(L, LUA_REGISTRYINDEX, frame->table_ref);
                frame->table_ref = LUA_NOREF;
                document->frame_count = 0;
                return;
            }
            luaL_unref(L, LUA_REGISTRYINDEX, frame->table_ref);
            frame->table_ref = LUA_NOREF;
            --document->frame_count;
            continue;
        }

        int parent_ref = frame->table_ref;
        int is_object = frame->is_object;
        if (yyjson_is_ctn(value)) {
            Frame* child = AddFrame(L, document, value);
            int child_ref = child->table_ref;
            lua_rawgeti(L, LUA_REGISTRYINDEX, parent_ref);
            if (is_object) {
                lua_pushlstring(L, yyjson_get_str(key), yyjson_get_len(key));
                lua_rawgeti(L, LUA_REGISTRYINDEX, child_ref);
                lua_rawset(L, -3);
            } else {
                lua_rawgeti(L, LUA_REGISTRYINDEX, child_ref);
                lua_rawseti(L, -2, (lua_Integer)array_index);
            }
            lua_pop(L, 1);
        } else {
            lua_rawgeti(L, LUA_REGISTRYINDEX, parent_ref);
            if (is_object) {
                lua_pushlstring(L, yyjson_get_str(key), yyjson_get_len(key));
                PushScalar(L, value);
                lua_rawset(L, -3);
            } else {
                PushScalar(L, value);
                lua_rawseti(L, -2, (lua_Integer)array_index);
            }
            lua_pop(L, 1);
        }
    }
}

static int Decode(lua_State* L) {
    if (lua_gettop(L) != 1 || lua_type(L, 1) != LUA_TSTRING)
        return luaL_error(L, "json.decode expects one string");
    size_t size;
    const char* source = lua_tolstring(L, 1, &size);

    Document* document = (Document*)lua_newuserdatauv(L, sizeof(Document), 0);
    document->value = NULL;
    document->frames = NULL;
    document->frame_count = 0;
    document->frame_capacity = 0;
    luaL_setmetatable(L, "dotcmd.json.document");
    int guard = lua_gettop(L);
    lua_toclose(L, guard);

    yyjson_read_err error;
    document->value = yyjson_read_opts(
        (char*)source, size, YYJSON_READ_BIGNUM_AS_RAW, NULL, &error);
    if (!document->value)
        return luaL_error(L, "json.decode: %s at byte %I",
            error.msg ? error.msg : "out of memory", (lua_Integer)(error.pos + 1));
    luaL_checkstack(L, 4, "JSON value is too complex");
    PushValue(L, document, yyjson_doc_get_root(document->value));
    lua_closeslot(L, guard);
    return 1;
}

struct EncodeFrame {
    int table_ref;
    yyjson_mut_val* value;
    yyjson_mut_val** keys;
    size_t count;
    size_t index;
};

struct Encoder {
    yyjson_mut_doc* document;
    char* output;
    EncodeFrame* frames;
    size_t frame_count;
    size_t frame_capacity;
};

static int CleanupEncoder(lua_State* L) {
    Encoder* encoder = (Encoder*)lua_touserdata(L, 1);
    for (size_t i = 0; i < encoder->frame_count; ++i) {
        luaL_unref(L, LUA_REGISTRYINDEX, encoder->frames[i].table_ref);
        free(encoder->frames[i].keys);
    }
    free(encoder->frames);
    encoder->frames = NULL;
    encoder->frame_count = 0;
    encoder->frame_capacity = 0;
    free(encoder->output);
    encoder->output = NULL;
    if (encoder->document) {
        yyjson_mut_doc_free(encoder->document);
        encoder->document = NULL;
    }
    return 0;
}

enum Shape { INFER_SHAPE, ARRAY_SHAPE, OBJECT_SHAPE };

static Shape TableShape(lua_State* L, int table, size_t* count) {
    Shape shape = INFER_SHAPE;
    if (lua_getmetatable(L, table)) {
        lua_pushliteral(L, "__jsontype");
        lua_rawget(L, -2);
        if (!lua_isnil(L, -1)) {
            size_t size = 0;
            const char* name = lua_type(L, -1) == LUA_TSTRING ? lua_tolstring(L, -1, &size) : NULL;
            if (name && size == 5 && memcmp(name, "array", 5) == 0) shape = ARRAY_SHAPE;
            else if (name && size == 6 && memcmp(name, "object", 6) == 0) shape = OBJECT_SHAPE;
            else luaL_error(L, "json.encode: __jsontype must be 'array' or 'object'");
        }
        lua_pop(L, 2);
    }

    lua_Integer max_index = 0;
    *count = 0;
    lua_pushnil(L);
    while (lua_next(L, table)) {
        if (shape == INFER_SHAPE) {
            if (lua_type(L, -2) == LUA_TSTRING) shape = OBJECT_SHAPE;
            else if (lua_isinteger(L, -2)) shape = ARRAY_SHAPE;
            else luaL_error(L, "json.encode: table keys must be strings or positive integers");
        }
        if (shape == ARRAY_SHAPE) {
            if (!lua_isinteger(L, -2) || lua_tointeger(L, -2) < 1)
                luaL_error(L, "json.encode: array keys must be consecutive integers starting at 1");
            lua_Integer index = lua_tointeger(L, -2);
            if (index > max_index) max_index = index;
        } else if (lua_type(L, -2) != LUA_TSTRING) {
            luaL_error(L, "json.encode: object keys must be strings");
        }
        ++*count;
        lua_pop(L, 1);
    }
    if (shape == INFER_SHAPE)
        luaL_error(L, "json.encode: ambiguous empty table; set __jsontype to 'array' or 'object'");
    if (shape == ARRAY_SHAPE && (lua_Unsigned)max_index != *count)
        luaL_error(L, "json.encode: sparse arrays are not supported");
    return shape;
}

static int CompareKeys(const void* left, const void* right) {
    yyjson_mut_val* a = *(yyjson_mut_val* const*)left;
    yyjson_mut_val* b = *(yyjson_mut_val* const*)right;
    size_t a_size = yyjson_mut_get_len(a), b_size = yyjson_mut_get_len(b);
    int order = memcmp(yyjson_mut_get_str(a), yyjson_mut_get_str(b), a_size < b_size ? a_size : b_size);
    return order ? order : (a_size > b_size) - (a_size < b_size);
}

static yyjson_mut_val* CheckedValue(lua_State* L, yyjson_mut_val* value) {
    if (!value) luaL_error(L, "json.encode: out of memory");
    return value;
}

static yyjson_mut_val* EncodeTable(lua_State* L, Encoder* encoder, int table, int active) {
    lua_pushvalue(L, table);
    lua_rawget(L, active);
    if (!lua_isnil(L, -1)) luaL_error(L, "json.encode: circular reference");
    lua_pop(L, 1);
    lua_pushvalue(L, table);
    lua_pushboolean(L, 1);
    lua_rawset(L, active);

    size_t count;
    Shape shape = TableShape(L, table, &count);
    if (encoder->frame_count == encoder->frame_capacity) {
        size_t capacity = encoder->frame_capacity ? encoder->frame_capacity * 2 : 16;
        if (capacity < encoder->frame_capacity || capacity > SIZE_MAX / sizeof(EncodeFrame))
            luaL_error(L, "json.encode: nesting is too deep");
        EncodeFrame* frames = (EncodeFrame*)realloc(encoder->frames, capacity * sizeof(EncodeFrame));
        if (!frames) luaL_error(L, "json.encode: out of memory");
        encoder->frames = frames;
        encoder->frame_capacity = capacity;
    }
    EncodeFrame* frame = &encoder->frames[encoder->frame_count++];
    memset(frame, 0, sizeof(*frame));
    frame->table_ref = LUA_NOREF;
    lua_pushvalue(L, table);
    frame->table_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    frame->count = count;
    frame->value = CheckedValue(L, shape == ARRAY_SHAPE
        ? yyjson_mut_arr(encoder->document) : yyjson_mut_obj(encoder->document));
    if (shape == OBJECT_SHAPE && count) {
        if (count > SIZE_MAX / sizeof(yyjson_mut_val*)) luaL_error(L, "json.encode: too many object keys");
        frame->keys = (yyjson_mut_val**)malloc(count * sizeof(yyjson_mut_val*));
        if (!frame->keys) luaL_error(L, "json.encode: out of memory");
        size_t index = 0;
        lua_pushnil(L);
        while (lua_next(L, table)) {
            size_t size;
            const char* key = lua_tolstring(L, -2, &size);
            frame->keys[index++] = CheckedValue(L, yyjson_mut_strncpy(encoder->document, key, size));
            lua_pop(L, 1);
        }
        qsort(frame->keys, count, sizeof(yyjson_mut_val*), CompareKeys);
    }
    return frame->value;
}

static yyjson_mut_val* EncodeValue(lua_State* L, Encoder* encoder, int index, int active) {
    index = lua_absindex(L, index);
    switch (lua_type(L, index)) {
    case LUA_TNIL:
        return CheckedValue(L, yyjson_mut_null(encoder->document));
    case LUA_TBOOLEAN:
        return CheckedValue(L, yyjson_mut_bool(encoder->document, lua_toboolean(L, index)));
    case LUA_TNUMBER:
        if (lua_isinteger(L, index))
            return CheckedValue(L, yyjson_mut_sint(encoder->document, lua_tointeger(L, index)));
        if (!isfinite(lua_tonumber(L, index))) luaL_error(L, "json.encode: number must be finite");
        return CheckedValue(L, yyjson_mut_real(encoder->document, lua_tonumber(L, index)));
    case LUA_TSTRING: {
        size_t size;
        const char* text = lua_tolstring(L, index, &size);
        return CheckedValue(L, yyjson_mut_strncpy(encoder->document, text, size));
    }
    case LUA_TTABLE:
        return EncodeTable(L, encoder, index, active);
    default:
        luaL_error(L, "json.encode: unsupported type %s", luaL_typename(L, index));
        return NULL;
    }
}

static int Encode(lua_State* L) {
    int arguments = lua_gettop(L);
    if (arguments < 1 || arguments > 2)
        return luaL_error(L, "json.encode expects a value and optional options table");
    bool pretty = false;
    if (arguments == 2 && !lua_isnil(L, 2)) {
        luaL_checktype(L, 2, LUA_TTABLE);
        lua_getfield(L, 2, "pretty");
        if (!lua_isnil(L, -1)) luaL_checktype(L, -1, LUA_TBOOLEAN);
        pretty = lua_toboolean(L, -1);
    }
    lua_settop(L, 1);
    luaL_checkstack(L, 8, "JSON value is too complex");
    Encoder* encoder = (Encoder*)lua_newuserdatauv(L, sizeof(Encoder), 0);
    memset(encoder, 0, sizeof(*encoder));
    luaL_setmetatable(L, "dotcmd.json.encoder");
    int guard = lua_gettop(L);
    lua_toclose(L, guard);
    encoder->document = yyjson_mut_doc_new(NULL);
    if (!encoder->document) return luaL_error(L, "json.encode: out of memory");
    // Only ancestors are active: shared tables are allowed, cycles are not.
    lua_newtable(L);
    int active = lua_gettop(L);
    yyjson_mut_doc_set_root(encoder->document, EncodeValue(L, encoder, 1, active));
    while (encoder->frame_count) {
        EncodeFrame* frame = &encoder->frames[encoder->frame_count - 1];
        lua_rawgeti(L, LUA_REGISTRYINDEX, frame->table_ref);
        if (frame->index == frame->count) {
            lua_pushnil(L);
            lua_rawset(L, active);
            luaL_unref(L, LUA_REGISTRYINDEX, frame->table_ref);
            free(frame->keys);
            --encoder->frame_count;
            continue;
        }
        yyjson_mut_val* key = frame->keys ? frame->keys[frame->index] : NULL;
        yyjson_mut_val* container = frame->value;
        ++frame->index;
        if (key) {
            lua_pushlstring(L, yyjson_mut_get_str(key), yyjson_mut_get_len(key));
            lua_rawget(L, -2);
        } else {
            lua_rawgeti(L, -1, (lua_Integer)frame->index);
        }
        lua_remove(L, -2);
        // EncodeValue may grow the frame array; retain no frame pointer across it.
        yyjson_mut_val* value = EncodeValue(L, encoder, -1, active);
        lua_pop(L, 1);
        if (key) yyjson_mut_obj_add(container, key, value);
        else yyjson_mut_arr_append(container, value);
    }
    size_t size;
    yyjson_write_err error;
    encoder->output = yyjson_mut_write_opts(encoder->document,
        pretty ? YYJSON_WRITE_PRETTY_TWO_SPACES : YYJSON_WRITE_NOFLAG, NULL, &size, &error);
    if (!encoder->output)
        return luaL_error(L, "json.encode: %s", error.msg ? error.msg : "out of memory");
    lua_pushlstring(L, encoder->output, size);
    lua_closeslot(L, guard);
    return 1;
}

void RegisterJson(lua_State* L) {
    if (luaL_newmetatable(L, "dotcmd.json.document")) {
        lua_pushcfunction(L, Cleanup); lua_setfield(L, -2, "__close");
        lua_pushcfunction(L, Cleanup); lua_setfield(L, -2, "__gc");
    }
    lua_pop(L, 1);
    if (luaL_newmetatable(L, "dotcmd.json.encoder")) {
        lua_pushcfunction(L, CleanupEncoder); lua_setfield(L, -2, "__close");
        lua_pushcfunction(L, CleanupEncoder); lua_setfield(L, -2, "__gc");
    }
    lua_pop(L, 1);
    luaL_newmetatable(L, "dotcmd.json.array");
    lua_pushliteral(L, "array"); lua_setfield(L, -2, "__jsontype");
    lua_pop(L, 1);
    luaL_newmetatable(L, "dotcmd.json.object");
    lua_pushliteral(L, "object"); lua_setfield(L, -2, "__jsontype");
    lua_pop(L, 1);
    lua_createtable(L, 0, 2);
    lua_pushliteral(L, "json.decode");
    lua_pushcclosure(L, Decode, 1);
    lua_setfield(L, -2, "decode");
    lua_pushliteral(L, "json.encode");
    lua_pushcclosure(L, Encode, 1);
    lua_setfield(L, -2, "encode");
    lua_setglobal(L, "json");
}
