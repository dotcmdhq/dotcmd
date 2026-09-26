#include "json.h"
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
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
    luaL_checkstack(L, 3, "JSON value is too complex");
    PushValue(L, document, yyjson_doc_get_root(document->value));
    lua_closeslot(L, guard);
    return 1;
}

void RegisterJson(lua_State* L) {
    if (luaL_newmetatable(L, "dotcmd.json.document")) {
        lua_pushcfunction(L, Cleanup); lua_setfield(L, -2, "__close");
        lua_pushcfunction(L, Cleanup); lua_setfield(L, -2, "__gc");
    }
    lua_pop(L, 1);
    lua_createtable(L, 0, 1);
    lua_pushliteral(L, "json.decode");
    lua_pushcclosure(L, Decode, 1);
    lua_setfield(L, -2, "decode");
    lua_setglobal(L, "json");
}
