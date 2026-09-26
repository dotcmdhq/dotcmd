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
