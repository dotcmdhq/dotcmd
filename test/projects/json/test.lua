test("json decodes scalars, objects, and arrays", function()
    assert(json.decode("null") == nil)
    assert(json.decode("true") == true)
    assert(json.decode("false") == false)
    assert(json.decode("42") == 42 and math.type(json.decode("42")) == "integer")
    assert(json.decode("-1.25e2") == -125.0 and math.type(json.decode("-1.25e2")) == "float")
    assert(json.decode([["a\u0000b\u00e9\ud83d\ude00"]]) == "a\0bé😀")

    local value = json.decode([[{"name":"ninja","versions":[1,2,3],"enabled":true}]])
    assert(value.name == "ninja" and value.enabled == true)
    assert(#value.versions == 3 and value.versions[1] == 1 and value.versions[3] == 3)
end)

test("json maps null to nil", function()
    local object = json.decode([[{"missing":null,"present":1}]])
    assert(object.missing == nil and object.present == 1)

    local array = json.decode("[null,1,null,3,null]")
    assert(array[1] == nil and array[2] == 1 and array[3] == nil and array[4] == 3 and array[5] == nil)
end)

test("json preserves Lua integer boundaries", function()
    assert(json.decode("9223372036854775807") == math.maxinteger)
    assert(json.decode("-9223372036854775808") == math.mininteger)
    t.assert_error("integer is outside Lua's range", function()
        json.decode("{\"nested\":[9223372036854775808]}")
    end)
    assert(json.decode("{\"still\":\"works\"}").still == "works")
    for _, source in ipairs {
        "-9223372036854775809",
        "18446744073709551616",
    } do
        t.assert_error("outside Lua's range", function() json.decode(source) end)
    end
end)

test("json rejects malformed and non-standard input", function()
    for _, source in ipairs {
        "", "[1,]", "{\"a\":1} trailing", "{/* comment */}", "NaN", "\"" .. string.char(255) .. "\"",
    } do
        t.assert_error("json.decode:", function() json.decode(source) end)
    end
    t.assert_error("at byte 6", function() json.decode("{\"a\":}") end)
end)

test("json validates its argument", function()
    t.assert_error("expects one string", function() json.decode() end)
    t.assert_error("expects one string", function() json.decode(1) end)
    t.assert_error("expects one string", function() json.decode("{}", "{}") end)
end)

test("json converts deeply nested values iteratively", function()
    local depth = 4096
    local value = json.decode(string.rep("{\"value\":", depth) .. "42" .. string.rep("}", depth))
    for _ = 1, depth do value = value.value end
    assert(value == 42)

    value = json.decode(string.rep("[", depth) .. "42" .. string.rep("]", depth))
    for _ = 1, depth do value = value[1] end
    assert(value == 42)
end)

test("json encodes scalars and preserves integer boundaries", function()
    assert(json.encode(nil) == "null")
    assert(json.encode(true) == "true")
    assert(json.encode(false) == "false")
    assert(json.encode(42) == "42")
    assert(json.encode(math.maxinteger) == "9223372036854775807")
    assert(json.encode(math.mininteger) == "-9223372036854775808")
    for _, value in ipairs({ -1.25, 1e-200, 1e200, 1.2345678901234567 }) do
        assert(json.decode(json.encode(value)) == value)
    end
    local value = "quote\" slash\\ newline\n tab\t nul\0 bé😀"
    local encoded = json.encode(value)
    assert(not encoded:find("\0", 1, true))
    assert(json.decode(encoded) == value)
end)

test("json encodes nested tables with stable object key order", function()
    local shared = { z = 3, a = 1 }
    assert(json.encode({ z = shared, a = { shared, false } })
        == [[{"a":[{"a":1,"z":3},false],"z":{"a":1,"z":3}}]])
    assert(json.encode({ ["a\0b"] = 3, a = 2, [""] = 1 }) == [[{"":1,"a":2,"a\u0000b":3}]])
    assert(json.encode({ 1, 2 }, nil) == "[1,2]")
end)

test("json pretty encoding uses two spaces and no trailing newline", function()
    local value = { z = true, a = { 1, 2 } }
    assert(json.encode(value, { pretty = true }) == [[{
  "a": [
    1,
    2
  ],
  "z": true
}]])
    assert(json.encode(value, { pretty = false }) == json.encode(value))
    assert(json.encode(value, {}) == json.encode(value))
end)

test("json uses explicit metatable hints for empty and populated tables", function()
    local array = setmetatable({}, { __jsontype = "array" })
    local object = setmetatable({}, { __jsontype = "object" })
    assert(json.encode({ items = array, settings = object }) == [[{"items":[],"settings":{}}]])
    array[1] = "one"; object.enabled = true
    assert(json.encode(array) == '["one"]')
    assert(json.encode(object) == [[{"enabled":true}]])
    array[1] = nil; object.enabled = nil
    assert(json.encode(array) == "[]" and json.encode(object) == "{}")
    t.assert_error("ambiguous empty table", function() json.encode({}) end)
    t.assert_error("ambiguous empty table", function() json.encode({ nested = {} }) end)
end)

test("json decoding attaches shape hints at every depth", function()
    local value = json.decode([[{"items":[{"enabled":true}],"settings":{},"empty":[]}]])
    assert(getmetatable(value).__jsontype == "object")
    assert(getmetatable(value.items).__jsontype == "array")
    assert(getmetatable(value.items[1]).__jsontype == "object")
    assert(getmetatable(value.settings).__jsontype == "object")
    assert(getmetatable(value.empty).__jsontype == "array")
    value.items[1].enabled = nil
    assert(json.encode(value.items) == "[{}]")
    value.items[1] = nil
    assert(json.encode(value) == [[{"empty":[],"items":[],"settings":{}}]])
    assert(json.encode(json.decode("[]")) == "[]")
    assert(json.encode(json.decode("{}")) == "{}")
end)

test("json rejects invalid hints and incompatible table shapes", function()
    for _, hint in ipairs({ false, 1, "", "Array", "array\0", {} }) do
        t.assert_error("__jsontype must be", function()
            json.encode(setmetatable({}, { __jsontype = hint }))
        end)
    end
    t.assert_error("array keys must be", function()
        json.encode(setmetatable({ named = 1 }, { __jsontype = "array" }))
    end)
    t.assert_error("object keys must be", function()
        json.encode(setmetatable({ 1 }, { __jsontype = "object" }))
    end)
    for _, value in ipairs({ { [0] = 1 }, { [-1] = 1 }, { [1.5] = 1 },
        { [true] = 1 }, { [{}] = 1 }, { 1, named = 2 } }) do
        t.assert_error("json.encode:", function() json.encode(value) end)
    end
    for _, value in ipairs({ { [2] = 1 }, { [1] = 1, [3] = 3 },
        setmetatable({ [2] = 1 }, { __jsontype = "array" }) }) do
        t.assert_error("sparse arrays", function() json.encode(value) end)
    end
end)

test("json encoding inspects raw keys, values, and metatable hints", function()
    local function unexpected() error("metamethod must not run") end
    local meta = setmetatable({ __jsontype = "array", __metatable = "protected",
        __len = unexpected, __pairs = unexpected, __index = unexpected, __tostring = unexpected },
        { __index = unexpected })
    assert(json.encode(setmetatable({ 1, 2 }, meta)) == "[1,2]")
    assert(json.encode(setmetatable({}, meta)) == "[]")
    assert(json.encode(setmetatable({ x = 1 }, setmetatable({}, { __index = unexpected }))) == [[{"x":1}]])
end)

test("json rejects cycles but permits reused tables", function()
    local value = { child = {} }
    value.child.parent = value
    for _ = 1, 50 do
        t.assert_error("circular reference", function() json.encode(value) end)
    end
    local shared = json.decode("{}")
    assert(json.encode({ shared, shared }) == "[{},{}]")
    local self = {}; self[1] = self
    t.assert_error("circular reference", function() json.encode(self) end)
    collectgarbage("collect")
    assert(json.encode({ still = "works" }) == [[{"still":"works"}]])
end)

test("json rejects unsupported values and invalid strings", function()
    for _, value in ipairs({ math.huge, -math.huge, 0 / 0 }) do
        t.assert_error("number must be finite", function() json.encode(value) end)
    end
    for _, value in ipairs({ function() end, coroutine.create(function() end), io.stdout }) do
        t.assert_error("unsupported type", function() json.encode({ value }) end)
    end
    for _, value in ipairs({ string.char(255), { [string.char(255)] = true } }) do
        t.assert_error("json.encode:", function() json.encode(value) end)
    end
    t.assert_error("expects a value", function() json.encode() end)
    t.assert_error("expects a value", function() json.encode(1, {}, {}) end)
    t.assert_error("table expected", function() json.encode(1, true) end)
    t.assert_error("boolean expected", function() json.encode(1, { pretty = "yes" }) end)
end)

test("json encodes deeply nested arrays and objects iteratively", function()
    local depth = 4096
    for _, pair in ipairs({ { "[", "]" }, { '{"value":', "}" } }) do
        local text = string.rep(pair[1], depth) .. "42" .. string.rep(pair[2], depth)
        assert(json.encode(json.decode(text)) == text)
    end
end)
