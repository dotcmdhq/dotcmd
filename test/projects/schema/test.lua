local S = require("dotcmd.schema")

local function rejects(schema, value, message)
    local ok, thrown = pcall(S.validate, schema, value)
    assert(not ok and type(thrown) == "table" and thrown.exit_code == 1)
    assert(thrown.message == message, thrown.message)
    for key in pairs(thrown) do assert(key == "message" or key == "exit_code") end
    return thrown
end

test("schema validation errors expose only message and exit code", function()
    local fn = S.func { signatures = { { params = S.table { fields = { { "value", S.string() } } }, returns = S.table { fields = {} } } } }
    local checks = {
        function() S.validate(S.string(), 42) end,
        function() S.conform(S.string(), 42) end,
        function() S.validate_call(fn, 42) end,
        function() S.conform_call(fn, 42) end,
    }
    for _, check in ipairs(checks) do
        local ok, thrown = pcall(check)
        assert(not ok and type(thrown.message) == "string" and thrown.exit_code == 1)
        for key in pairs(thrown) do assert(key == "message" or key == "exit_code") end
    end
end)

test("constructors produce inspectable nodes and preserve per-use metadata", function()
    local options = { description = "HTTPS URL", default = "https://example.com" }
    local url = S.string(options)
    assert(url.type == "string" and url.description == options.description and url.default == options.default)
    assert(options.type == nil and S.string().description == nil)
    options.description = "changed"
    assert(url.description == "HTTPS URL")
    local alternatives = S.union { alternatives = { url, S.null { description = "derive from context" } } }
    assert(alternatives.type == "union" and alternatives.alternatives[1] == url)
    assert(alternatives.alternatives[2].type == "nil")
    local reference = S.ref { name = "URL", description = "source URL" }
    assert(reference.type == "ref" and reference.name == "URL" and reference.definitions == nil)
    assert(S.table { fields = {} }.type == "table" and S.alt { alternatives = { { "empty", S.table { fields = {} } } } }.type == "alt")
end)

test("helper properties retain defaults and predicates", function()
    local nullable = S.optional {
        schema = S.string(), default = "derived", description = "optional text",
        validate = function(value) return value ~= "bad", "invalid optional text" end,
    }
    local choice = S.enum { values = { false, "chosen" }, default = false, description = "selection" }
    local array = S.array {
        items = S.string(), default = {}, description = "at most one item",
        validate = function(value) return #value <= 1 end,
    }
    assert(nullable.type == "union" and nullable.schema == nil and nullable.description == "optional text")
    assert(choice.type == "union" and choice.values == nil and choice.description == "selection")
    assert(array.type == "table" and array.items == nil and array.fields[1][2].type == "string")
    local record = S.table { fields = { nullable = nullable, choice = choice, array = array } }
    local input = {}
    assert(S.validate(record, input) == input and next(input) == nil)
    local output = S.conform(record, input)
    assert(output.nullable == "derived" and output.choice == false and output.array.items.n == 0)
    assert(S.validate(nullable, nil) == nil)
    rejects(nullable, "bad", "value: invalid optional text")
    rejects(choice, true, "value: expected false or \"chosen\", got boolean")
    rejects(array, { "one", "two" }, "value: at most one item")
end)

test("primitive checks preserve Lua types and literal values", function()
    assert(S.validate(S.string(), "") == "")
    assert(S.validate(S.number(), 1.5) == 1.5)
    assert(S.validate(S.integer(), 3) == 3 and S.validate(S.integer(), 3.0) == 3.0)
    assert(S.validate(S.boolean(), false) == false)
    assert(S.validate(S.null(), nil) == nil)
    assert(select("#", S.validate(S.null(), nil)) == 1)
    local function tool() end
    assert(S.validate(S.any(), nil) == nil and S.validate(S.any(), tool) == tool)
    assert(S.validate(S.literal { value = false }, false) == false and S.validate(S.literal { value = nil }, nil) == nil)
    rejects(S.string(), 42, "value: expected string, got number")
    rejects(S.number(), "42", "value: expected number, got string")
    rejects(S.integer(), 1.5, "value: expected integer, got number")
    rejects(S.integer(), "3", "value: expected integer, got string")
    rejects(S.boolean(), nil, "value: expected boolean, got nil")
    rejects(S.literal { value = "capture" }, "inherit", "value: expected \"capture\", got string")
end)

test("file schemas accept open handles and preserve identity", function()
    local file <close> = assert(io.tmpfile())
    local calls = 0
    local properties = { description = "Open output.", default = file, validate = function(value)
        calls = calls + 1
        return value == file, "unexpected handle"
    end }
    local schema = S.file(properties)
    assert(schema.type == "file" and properties.type == nil and schema.description == properties.description)
    assert(S.validate(schema, file) == file and S.conform(schema, file) == file and calls == 2)
    assert(S.conform(S.table { fields = { output = schema } }, {}).output == file)
    assert(S.validate(S.optional { schema = S.file() }, nil) == nil)
    rejects(schema, "path", "value: expected open file handle, got string")
    rejects(schema, {}, "value: expected open file handle, got table")
    rejects(schema, nil, "value: expected open file handle, got nil")
    assert(calls == 3)
end)

test("closed files fail validation and conformance", function()
    local file = assert(io.tmpfile())
    assert(file:close())
    rejects(S.file(), file, "value: expected open file handle, got userdata")
    t.assert_error("value: expected open file handle, got userdata", function() S.conform(S.file(), file) end)
    local call = S.func { name = "consume", signatures = { {
        params = S.table { fields = { { "input", S.file() } } }, returns = S.table { fields = {} },
    } } }
    t.assert_error("consume: argument \"input\" must be an open file handle, got userdata", function()
        S.validate_call(call, file)
    end)
end)

test("custom validation follows structure, preserves inputs, and retains explanations", function()
    local calls = 0
    local checksum = S.string {
        description = "64 lowercase hex characters",
        validate = function(value)
            calls = calls + 1
            return #value == 64 and value:match("^[0-9a-f]+$") ~= nil
        end,
    }
    rejects(checksum, 3, "value: expected string, got number")
    assert(calls == 0)
    rejects(checksum, "oops", "value: 64 lowercase hex characters")
    assert(calls == 1)
    assert(S.validate(checksum, string.rep("a", 64)))
    rejects(S.union { alternatives = { S.null(), checksum } }, "oops", "value: 64 lowercase hex characters")

    local schema = S.table { fields = { left = S.number(), right = S.number() }, validate = function(value) return value.left < value.right, "left must be less than right" end, }
    local value = { left = 3, right = 2 }
    rejects(schema, value, "value: left must be less than right")
    assert(value.left == 3 and value.right == 2)
end)

test("unions accept overlapping branches and nullable fields allow absence", function()
    assert(S.validate(S.union { alternatives = { S.number(), S.integer() } }, 3))
    local mode = S.union { alternatives = { S.literal { value = "capture" }, S.literal { value = "inherit" }, S.null() } }
    local schema = S.table { fields = { mode = mode, name = S.string { default = "default" } } }
    assert(S.validate(schema, { name = "tool" }))
    rejects(schema, { name = false }, "value.name: expected string, got boolean")
    local missing = {}
    assert(S.validate(schema, missing) and next(missing) == nil)
    local value = {}
    assert(S.validate(S.table { fields = { name = S.union { alternatives = { S.string(), S.null() } } } }, value))
    assert(next(value) == nil)
    rejects(mode, false, "value: expected \"capture\" or \"inherit\" or nil, got boolean")
end)

test("mixed tables combine positional arities with named fields", function()
    local schema = S.table { fields = {
        { "program", S.string() },
        { "args", S.string(), arity = "*" },
        cwd = S.union { alternatives = { S.string(), S.null() } },
    } }
    assert(S.validate(schema, { "java", "-version", cwd = "path with spaces" }))
    assert(S.validate(schema, { "java" }))
    rejects(schema, {}, "value[1] (program): missing required argument: program")
    rejects(schema, { "java", 42 }, "value[2] (args): expected string, got number")
    rejects(schema, { "java", cwd = false }, "value.cwd: expected string or nil, got boolean")
    rejects(schema, { "java", typo = "value" }, "value.typo: unknown field")
    rejects(schema, { [1] = "java", [3] = "-version" }, "value[2] (args): positional entries must form a dense sequence")
end)

test("mixed table conformance merges positional bindings and named fields", function()
    local schema = S.table { fields = {
        { "program", S.string() },
        { "args", S.union { alternatives = { S.string(), S.null() } }, arity = "*" },
        cwd = S.string(),
        enabled = S.boolean { default = false },
    } }
    local input = table.pack("java", nil, "-version")
    input.cwd = "/project"
    assert(S.validate(schema, input) == input)
    local output = S.conform(schema, input)
    assert(output.program == "java" and output.cwd == "/project" and output.enabled == false)
    assert(output.args.n == 2 and output.args[1] == nil and output.args[2] == "-version")
    assert(output[1] == nil and output.n == nil)
    assert(input[1] == "java" and input.n == 3 and input.enabled == nil and input.program == nil)
    rejects(schema, { "java", cwd = "/project", args = {} }, "value.args: unknown field")
end)

test("mixed optional defaults are checked before destructuring without mutating inputs", function()
    local seen = 0
    local schema = S.table { fields = {
        { "program", S.string() },
        { "enabled", S.boolean { default = false }, arity = "?" },
        cwd = S.string { default = "/project" },
    }, validate = function(value)
        seen = seen + 1
        assert(value[1] == "java" and value[2] == false and value.cwd == "/project")
        assert(value.program == nil and value.enabled == nil)
        return true
    end }
    local input = { "java" }
    assert(S.validate(schema, input) == input)
    local output = S.conform(schema, input)
    assert(output.program == "java" and output.enabled == false and output.cwd == "/project")
    assert(seen == 2 and input[2] == nil and input.cwd == nil and input.n == nil)
    rejects(schema, table.pack("java", nil), "value[2] (enabled): expected boolean, got nil")
end)

test("closed tables check empty positionals and declared n fields remain ordinary data", function()
    local empty = S.table { fields = {} }
    local output = S.conform(empty, table.pack())
    assert(next(output) == nil)
    rejects(empty, table.pack(nil), "value[1]: unexpected positional argument")
    rejects(S.table { fields = { name = S.string() } }, { "extra", name = "tool" }, "value[1]: unexpected positional argument")
    local schema = S.table { fields = { { "program", S.string() }, n = S.integer() } }
    local input = { "java", n = 20 }
    assert(S.validate(schema, input) == input)
    output = S.conform(schema, input)
    assert(output.program == "java" and output.n == 20 and output[1] == nil)
    output = S.conform(S.table { fields = { n = S.string() } }, { n = "ordinary field" })
    assert(output.n == "ordinary field")
end)

test("packed sequences reject invalid lengths with formatted validation errors", function()
    local schema = S.table { fields = { { "args", S.null(), arity = "*" } } }
    local thrown = rejects(schema, { n = "field" }, "value.n: expected integer, got string")
    assert(thrown.message == "value.n: expected integer, got string")
    rejects(schema, { n = 1.5 }, "value.n: expected integer, got number")
    thrown = rejects(schema, { n = -1 }, "value.n: packed sequence length must be nonnegative")
    assert(thrown.message == "value.n: packed sequence length must be nonnegative")
    for _, input in ipairs({ { n = "field" }, { n = 1.5 }, { n = -1 } }) do
        local ok, validation_error = pcall(S.validate, schema, input)
        local conformed, conformance_error = pcall(S.conform, schema, input)
        assert(not ok and not conformed and validation_error.message == conformance_error.message)
    end
    local input = table.pack(nil, nil)
    assert(S.validate(schema, input) == input)
    assert(S.conform(schema, input).args.n == 2)
end)

test("packed lengths cannot hide supplied positional values", function()
    local cases = {
        { S.table { fields = {} }, { n = 0, "unchecked" }, 1 },
        { S.table { fields = { { "program", S.string() } } }, { n = 1, "java", [3] = 42 }, 3 },
        { S.table { fields = { { "args", S.null(), arity = "*" } } }, { n = 2, [5] = false }, 5 },
    }
    for _, case in ipairs(cases) do
        rejects(case[1], case[2], "value[" .. case[3] .. "]: positional argument exceeds packed sequence length")
        local ok, thrown = pcall(S.conform, case[1], case[2])
        assert(not ok and thrown.exit_code == 1 and thrown.message == "value[" .. case[3] .. "]: positional argument exceeds packed sequence length")
        assert(case[2][case[3]] ~= nil)
    end
end)

test("maps preserve sparse numeric keys as ordinary data", function()
    local map = S.map { key = S.integer(), value = S.string() }
    local input = { [1] = "first", [3] = "third" }
    assert(S.validate(map, input) == input)
    local output = S.conform(map, input)
    assert(output[1] == "first" and output[3] == "third" and output ~= input)
    rejects(map, { name = "text" }, "value.name key: expected integer, got string")
    local named = S.map { key = S.string(), value = S.string() }
    output = S.conform(named, { n = "ordinary map entry" })
    assert(output.n == "ordinary map entry")
    rejects(named, { n = 1 }, "value.n: expected string, got number")
end)

test("tables reject undeclared fields and maps validate every key and value", function()
    local array = S.table { fields = { { "items", S.string(), arity = "*" } } }
    assert(S.validate(array, {}) and S.validate(array, { "one", "two" }))
    rejects(array, { name = "one" }, "value.name: unknown field")
    rejects(array, { [0] = "one" }, "value[0]: unknown field")
    rejects(array, { [1.5] = "one" }, "value[1.5]: unknown field")
    local map = S.map { key = S.string(), value = S.boolean() }
    assert(S.validate(map, { enabled = false, debug = true }))
    rejects(map, { enabled = "false" }, "value.enabled: expected boolean, got string")
    rejects(map, { [1] = true }, "value[1] key: expected string, got number")
    rejects(S.table { fields = { name = S.string() } }, { name = "tool", other = 42 }, "value.other: unknown field")
end)

test("map predicates see normalized values and conformance retains keys", function()
    local seen = 0
    local schema = S.map {
        key = S.string(),
        value = S.table { fields = { enabled = S.boolean { default = false } } },
        validate = function(value)
            seen = seen + 1
            return value.entry.enabled == false, "entry must be disabled"
        end,
    }
    local input = { entry = {} }
    assert(S.validate(schema, input) == input)
    local output = S.conform(schema, input)
    assert(output.entry.enabled == false and output ~= input and output.entry ~= input.entry and seen == 2)
    assert(input.entry.enabled == nil)
    rejects(schema, { entry = { enabled = true } }, "value: entry must be disabled")
    rejects(schema, false, "value: expected map, got boolean")
end)

test("registry references are local and recursive definitions stay acyclic", function()
    local command = S.registry {
        definitions = {
            Command = S.table { fields = {
                { "program", S.union { alternatives = { S.string(), S.ref { name = "Command" } } } },
                { "args", S.string(), arity = "*" },
                cwd = S.union { alternatives = { S.string(), S.null() } },
            } },
        },
        schema = S.ref { name = "Command" },
    }
    assert(S.validate(command, { { { "java", "-Xmx1g" }, "-version" }, cwd = "project" }))
    rejects(command, { { "java", 42 } }, "value[1][2] (program): expected string, got number")
    local function no_cycles(node, active)
        if type(node) ~= "table" then return end
        assert(not active[node])
        active[node] = true
        for _, child in pairs(node) do no_cycles(child, active) end
        active[node] = nil
    end
    no_cycles(command, {})
    assert(S.validate(S.registry { definitions = { Value = S.string() }, schema = S.ref { name = "Value" } }, "text"))
    assert(S.validate(S.registry { definitions = { Value = S.number() }, schema = S.ref { name = "Value" } }, 42))
end)

test("nested registries resolve definitions in their owning lexical scope", function()
    local schema = S.registry {
        definitions = {
            Value = S.string(),
            Outer = S.table { fields = { value = S.ref { name = "Value" } } },
        },
        schema = S.registry {
            definitions = { Value = S.number() },
            schema = S.table { fields = { local_value = S.ref { name = "Value" }, outer = S.ref { name = "Outer" } } },
        },
    }
    assert(S.validate(schema, { local_value = 42, outer = { value = "outer string" } }))
    rejects(schema, { local_value = 42, outer = { value = 42 } }, "value.outer.value: expected string, got number")
end)

test("at selects API functions with scoped arguments and qualified call errors", function()
    local signature = {
        params = S.table { fields = { { "path", S.ref { name = "Path" } } } },
        returns = S.table { fields = { { "stat", S.union { alternatives = { S.ref { name = "FileStat" }, S.null() } } } } },
    }
    local stat = S.func { signatures = { signature }, description = "Inspect a filesystem entry." }
    local api = S.registry {
        definitions = {
            Path = S.string(),
            FileStat = S.table { fields = { size = S.integer() } },
        },
        schema = S.table { fields = { fs = S.table { fields = { stat = stat } } } },
    }
    local selected = S.at(api, { "fs", "stat" })
    assert(S.validate(selected, fs.stat) == fs.stat)
    assert(S.conform(selected, fs.stat) == fs.stat)
    assert(S.validate_call(selected, "some/file") == signature)
    assert(S.conform_call(selected, "some/file").path == "some/file")
    local ok, thrown = pcall(S.validate_call, selected, 42)
    assert(not ok and thrown.message == "fs.stat: argument \"path\" must be a string, got number")
    ok, thrown = pcall(S.conform_call, selected, nil)
    assert(not ok and thrown.message == "fs.stat: argument \"path\" must be a string, got nil")
    local chained = S.at(S.at(api, { "fs" }), { "stat" })
    ok, thrown = pcall(S.validate_call, chained, false)
    assert(not ok and thrown.message == "fs.stat: argument \"path\" must be a string, got boolean")
    assert(stat.name == nil and api.name == nil)
    assert(stat.signatures[1].returns == signature.returns)
    local root = S.at(api, {})
    local value = { fs = { stat = fs.stat } }
    assert(root.schema == api and S.validate(root, value) == value)
end)

test("at preserves lexical reference ownership through nested registries and aliases", function()
    local outer_signature = { params = S.table { fields = { { "value", S.ref { name = "Value" } } } }, returns = S.table { fields = {} } }
    local inner_signature = { params = S.table { fields = { { "value", S.ref { name = "Value" } } } }, returns = S.table { fields = {} } }
    local api = S.registry {
        definitions = {
            Value = S.string(),
            Outer = S.table { fields = { call = S.func { signatures = { outer_signature } } } },
        },
        schema = S.table { fields = {
            nested = S.registry {
                definitions = { Value = S.number(), Local = S.func { signatures = { inner_signature } } },
                schema = S.table { fields = { outer = S.ref { name = "Outer" }, call = S.ref { name = "Local" } } },
            },
        } },
    }
    local outer = S.at(api, { "nested", "outer", "call" })
    local inner = S.at(api, { "nested", "call" })
    assert(S.validate_call(outer, "text") == outer_signature)
    assert(S.validate_call(inner, 42) == inner_signature)
    assert(S.conform_call(outer, "text").value == "text")
    assert(S.conform_call(inner, 42).value == 42)
    local ok, thrown = pcall(S.validate_call, outer, 42)
    assert(not ok and thrown.message == "nested.outer.call: argument \"value\" must be a string, got number")
    ok, thrown = pcall(S.validate_call, inner, "text")
    assert(not ok and thrown.message == "nested.call: argument \"value\" must be a number, got string")
end)

test("at preserves selected reference properties without running ancestor validators", function()
    local api = S.registry {
        definitions = { Text = S.string { default = "definition" } },
        schema = S.table { fields = {
            { "text", S.ref { name = "Text", default = "selected",
                description = "selected text",
                validate = function(value) return value ~= "bad", "selected validation" end, } },
        }, validate = function() error("ancestor validator must not run") end },
    }
    local selected = S.at(api, { 1 })
    assert(S.validate(selected, "text") == "text")
    assert(S.conform(S.table { fields = { field = selected } }, {}).field == "selected")
    local thrown = rejects(selected, "bad", "value: selected validation")
    assert(thrown.message == "value: selected validation")
    assert(api.schema.fields[1][2].default == "selected")
    local function no_cycles(value, active)
        if type(value) ~= "table" then return end
        assert(not active[value])
        active[value] = true
        for _, child in pairs(value) do no_cycles(child, active) end
        active[value] = nil
    end
    no_cycles(selected, {})
end)

test("at preserves explicit function names and selects fields without a registry", function()
    local signature = { params = S.table { fields = { { "path", S.string() } } }, returns = S.table { fields = {} } }
    local schema = S.table { fields = {
        fs = S.table { fields = { stat = S.func { signatures = { signature }, name = "inspect" } } },
        ["fetch source"] = S.func { signatures = { signature } },
    } }
    local selected = S.at(schema, { "fs", "stat" })
    assert(S.conform_call(selected, "file").path == "file")
    local ok, thrown = pcall(S.validate_call, selected, 42)
    assert(not ok and thrown.message == "inspect: argument \"path\" must be a string, got number")
    selected = S.at(schema, { "fetch source" })
    ok, thrown = pcall(S.validate_call, selected, 42)
    assert(not ok and thrown.message == "[\"fetch source\"]: argument \"path\" must be a string, got number")
end)

test("sequences distinguish omission, explicit nil, and zero return values", function()
    local one = S.table { fields = { { "value", S.union { alternatives = { S.string(), S.null() } } } } }
    assert(S.validate(one, table.pack(nil)))
    rejects(one, table.pack(), "value[1] (value): missing required argument: value")
    local optional = S.table { fields = { { "value", S.string(), arity = "?" } } }
    assert(S.validate(optional, table.pack()) and S.validate(optional, table.pack("")))
    rejects(optional, table.pack(nil), "value[1] (value): expected string, got nil")
    local empty = S.table { fields = {} }
    assert(S.validate(empty, table.pack()))
    rejects(empty, table.pack(nil), "value[1]: unexpected positional argument")
    assert(S.validate(S.table { fields = { { "a", S.null() }, { "b", S.string() } } }, table.pack(nil, "b")))
end)

test("sequence repetition validates every supplied position including trailing nil", function()
    local star = S.table { fields = { { "program", S.string() }, { "args", S.string(), arity = "*" } } }
    assert(S.validate(star, table.pack("java")))
    assert(S.validate(star, table.pack("java", "", "-version")))
    rejects(star, table.pack("java", "text", nil), "value[3] (args): expected string, got nil")
    local plus = S.table { fields = { { "files", S.string(), arity = "+" } } }
    rejects(plus, table.pack(), "value[1] (files): missing required argument: files")
    assert(S.validate(plus, table.pack("file")))
    assert(S.validate(S.table { fields = { { "args", S.null(), arity = "*" } } }, table.pack(nil, nil)))
end)

test("sequence alternatives report the furthest matching position and branch", function()
    local schema = S.alt { alternatives = {
        { "options", S.table { fields = { { "options", S.table { fields = { url = S.string(), sha256 = S.string() } } } } } },
        { "positional", S.table { fields = { { "url", S.string() }, { "sha256", S.string() } } } },
    } }
    assert(S.validate(schema, table.pack({ url = "https://example.com", sha256 = "hash" })))
    assert(S.validate(schema, table.pack("https://example.com", "hash")))
    rejects(schema, table.pack({ url = "https://example.com" }), "value[1].sha256 (options) (branch options): required value is missing (expected string)")
    rejects(schema, table.pack("https://example.com"), "value[2] (sha256) (branch positional): missing required argument: sha256")
end)

test("function schemas describe calls without invoking or wrapping functions", function()
    local signatures = {
        { params = S.table { fields = { { "options", S.table { fields = { name = S.string() } } } } }, returns = S.table { fields = {} } },
        { params = S.table { fields = { { "name", S.string() }, { "args", S.string(), arity = "*" } } },
            returns = S.table { fields = { { "result", S.integer() } } } },
    }
    local schema = S.registry { definitions = { Tool = S.func { signatures = signatures } }, schema = S.ref { name = "Tool" } }
    local calls = 0
    local function tool() calls = calls + 1 end
    assert(S.validate(schema, tool) and calls == 0)
    rejects(schema, {}, "value: expected function, got table")
    local signature = S.validate_call(schema, { name = "java" })
    assert(signature == signatures[1] and calls == 0)
    signature = S.validate_call(schema, "java", "-version")
    assert(signature == signatures[2] and calls == 0)
    local ok, thrown = pcall(S.validate_call, schema, "java", nil)
    assert(not ok and thrown.exit_code == 1 and thrown.message == "Tool: argument \"args\" must be a string, got nil")
    assert(S.validate(signature.returns, table.pack(42)))
end)

test("custom validator exceptions propagate without being treated as branch failures", function()
    local exception = { message = "validator failed", exit_code = 23 }
    local schema = S.union { alternatives = { S.string { validate = function() error(exception) end }, S.any() } }
    local ok, thrown = pcall(S.validate, schema, "text")
    assert(not ok and thrown == exception)
    local function_schema = S.func { signatures = { { params = S.table { fields = { { "value", schema } } }, returns = S.table { fields = {} } } } }
    ok, thrown = pcall(S.validate_call, function_schema, "text")
    assert(not ok and thrown == exception)
    ok, thrown = pcall(S.conform, schema, "text")
    assert(not ok and thrown == exception)
    ok, thrown = pcall(S.conform_call, function_schema, "text")
    assert(not ok and thrown == exception)
end)

test("validation and call conformance produce formatted command errors and exit status 1", function()
    local project = t.project("invalid schema", [[
local S = require("dotcmd.schema")
return {
    test = function()
        S.validate(S.table { fields = { check = S.boolean() } }, { check = "yes" })
    end,
    call = function()
        local schema = S.func { signatures = { {
            params = S.table { fields = { { "url", S.string() }, { "sha256", S.string() } } },
            returns = S.table { fields = {} },
        } }, name = "fetch" }
        S.conform_call(schema, "https://example.com", 42)
    end,
}
]])
    local result = t.run_project(project, "test")
    assert(result.exit_code == 1 and result.stdout == "")
    assert(result.stderr:gsub("\r\n", "\n") == "dotcmd: value.check: expected boolean, got string\n", result.stderr)
    result = t.run_project(project, "call")
    assert(result.exit_code == 1 and result.stdout == "")
    assert(result.stderr:gsub("\r\n", "\n") == "dotcmd: fetch: argument \"sha256\" must be a string, got number\n", result.stderr)
end)

test("formatted errors include field paths, positional names, and map key failures", function()
    local schema = S.table { fields = { { "program", S.string() }, ["source url"] = S.string() } }
    local thrown = rejects(schema, { "java", ["source url"] = false }, "value[\"source url\"]: expected string, got boolean")
    assert(thrown.message == "value[\"source url\"]: expected string, got boolean")
    thrown = rejects(S.table { fields = { { "program", S.string() } } }, table.pack(false), "value[1] (program): expected string, got boolean")
    assert(thrown.message == "value[1] (program): expected string, got boolean")
    thrown = rejects(S.map { key = S.string(), value = S.any() }, { [1] = true }, "value[1] key: expected string, got number")
    assert(thrown.message == "value[1] key: expected string, got number")
end)

test("conformance preserves primitive values, nil, false, and function identity", function()
    local function tool() error("must not be called") end
    local function_schema = S.func { signatures = { { params = S.table { fields = {} }, returns = S.table { fields = {} } } }, default = tool }
    assert(S.conform(S.string(), "text") == "text")
    assert(S.conform(S.boolean(), false) == false)
    local ok, value = pcall(S.conform, S.null(), nil)
    assert(ok and value == nil)
    assert(select("#", S.conform(S.null(), nil)) == 1)
    assert(select("#", S.conform(S.string(), "text")) == 1)
    assert(S.conform(function_schema, tool) == tool)
    assert(S.conform(S.table { fields = { tool = function_schema } }, {}).tool == tool)
    assert(S.conform(S.union { alternatives = { S.null(), S.string() } }, "text") == "text")
    ok, value = pcall(S.conform, S.integer(), "3")
    assert(not ok and value.exit_code == 1 and value.message == "value: expected integer, got string")
end)

test("structured defaults produce independent conformed outputs and preserve false", function()
    local default = { values = { "first" } }
    local schema = S.table { fields = {
        enabled = S.boolean { default = false },
        settings = S.table { fields = { values = S.table { fields = { { "items", S.string(), arity = "*" } } } }, default = default },
        optional = S.union { alternatives = { S.string(), S.null() } },
    } }
    local input = {}
    assert(S.validate(schema, input) == input and next(input) == nil)
    local first = S.conform(schema, input)
    local second = S.conform(schema, input)
    assert(first.enabled == false and first.settings.values.items[1] == "first")
    assert(first ~= input and first.settings ~= second.settings and first.settings.values ~= second.settings.values)
    first.settings.values.items[1] = "changed"
    assert(second.settings.values.items[1] == "first" and default.values[1] == "first" and next(input) == nil)
    local supplied = { enabled = true, settings = { values = {} } }
    local output = S.conform(schema, supplied)
    assert(output.enabled == true and output.settings.values.items.n == 0)

    local invalid = S.table { fields = { enabled = S.boolean { default = "yes" } } }
    local ok, thrown = pcall(S.conform, invalid, {})
    assert(not ok and thrown.message == "value.enabled: expected boolean, got string")
    rejects(invalid, {}, "value.enabled: expected boolean, got string")
end)

test("literal and any defaults preserve identity and metatables", function()
    local token = setmetatable({}, { __index = { label = "token" } })
    local schema = S.registry {
        definitions = {
            Token = S.literal { value = token, default = token,
                validate = function(value) return value == token end, },
        },
        schema = S.table { fields = {
            literal = S.ref { name = "Token" },
            raw = S.any { default = token },
        } },
    }
    local input = {}
    assert(S.validate(schema, input) == input and next(input) == nil)
    local output = S.conform(schema, input)
    assert(output.literal == token and output.raw == token)
    assert(getmetatable(output.literal) == getmetatable(token) and output.raw.label == "token")
    local optional = S.table { fields = { { "token", S.literal { value = token, default = token }, arity = "?" } } }
    assert(S.conform(optional, table.pack()).token == token)
end)

test("defaults resolve through scoped references and only declared parents are filled", function()
    local schema = S.registry {
        definitions = {
            Text = S.string { default = "definition" },
            Alias = S.ref { name = "Text" },
        },
        schema = S.table { fields = {
            from_definition = S.ref { name = "Alias" },
            from_use = S.ref { name = "Alias", default = "use" },
            missing_parent = S.union { alternatives = { S.null(), S.table { fields = { child = S.string { default = "child" } } } } },
            default_parent = S.table { fields = { child = S.string { default = "child" } }, default = {} },
        } },
    }
    local output = S.conform(schema, {})
    assert(output.from_definition == "definition" and output.from_use == "use")
    assert(output.missing_parent == nil and output.default_parent.child == "child")
    local mixed = S.table { fields = { { "program", S.string { default = "java" }, arity = "?" } } }
    output = S.conform(mixed, {})
    assert(output.program == "java")
    rejects(mixed, table.pack(nil), "value[1] (program): expected string, got nil")
end)

test("sequence conformance preserves supplied nil positions and omitted defaults", function()
    local schema = S.table { fields = {
        { "program", S.string() },
        { "mode", S.union { alternatives = { S.null(), S.string() } }, arity = "?" },
    } }
    local absent = S.conform(schema, table.pack("java"))
    local supplied = S.conform(schema, table.pack("java", nil))
    assert(absent.program == "java" and absent.mode == nil)
    assert(supplied.program == "java" and supplied.mode == nil)

    local optional = S.table { fields = { { "enabled", S.boolean { default = false }, arity = "?" } } }
    local output = S.conform(optional, table.pack())
    assert(output.enabled == false)
    assert(S.validate(optional, table.pack()))
    rejects(optional, table.pack(nil), "value[1] (enabled): expected boolean, got nil")
    local required = S.table { fields = { { "value", S.string { default = "default" } } } }
    rejects(required, table.pack(), "value[1] (value): missing required argument: value")

    local repeated = S.table { fields = { { "values", S.union { alternatives = { S.string(), S.null() } }, arity = "*" } } }
    output = S.conform(repeated, table.pack("first", nil))
    assert(output.values.n == 2 and output.values[1] == "first" and output.values[2] == nil)
    output = S.conform(repeated, table.pack())
    assert(output.values.n == 0)
end)

test("named alternatives conform nested sequences and select the first matching branch", function()
    local first = S.table { fields = { { "command", S.table { fields = { { "program", S.string() } } } } } }
    local schema = S.alt { alternatives = { { "nested", first }, { "also_nested", first } } }
    local input = table.pack(table.pack("java"))
    local output = S.conform(schema, input)
    assert(output.tag == "nested" and output.value.command.program == "java")
    assert(input[1][1] == "java" and input[1].program == nil)
    local ok, thrown = pcall(S.conform, schema, table.pack(table.pack(false)))
    assert(not ok and thrown.message:find("branch nested", 1, true))
end)

test("custom predicates see filled input shapes before sequence destructuring", function()
    local seen = {}
    local schema = S.table { fields = {
        command = S.table { fields = { { "mode", S.string { default = "capture" }, arity = "?" } }, validate = function(value)
                assert(value[1] == "capture" and value.n == 1 and value.mode == nil)
                return true
            end, },
        enabled = S.boolean { default = false },
    }, validate = function(value)
        seen[#seen + 1] = value
        return value.command[1] == "capture" and value.enabled == false, "expected normalized input"
    end }
    local input = { command = table.pack() }
    assert(S.validate(schema, input))
    local output = S.conform(schema, input)
    assert(output.command.mode == "capture" and output.enabled == false and #seen == 2)
    assert(input.enabled == nil and input.command.n == 0)
end)

test("failed union branches do not leak defaults into map conformance", function()
    local schema = S.union { alternatives = { S.table { fields = { generated = S.string { default = "default" }, required = S.number() } }, S.map { key = S.string(), value = S.string() } } }
    local input = { extra = "preserved" }
    local output = S.conform(schema, input)
    assert(output.generated == nil and output.extra == "preserved" and input.generated == nil)
    local map = S.map { key = S.string(), value = S.table { fields = { { "value", S.number() } } } }
    output = S.conform(map, { entry = table.pack(42) })
    assert(output.entry.value == 42)
    local key = table.pack(42)
    local keyed = S.map { key = S.table { fields = { { "id", S.number() } } }, value = S.string() }
    output = S.conform(keyed, { [key] = "kept" })
    assert(output[key] == "kept" and key[1] == 42 and key.id == nil)
end)

test("schemas validate structured API returns and preserve native function identity", function()
    local stat = S.union { alternatives = { S.null(), S.table { fields = {
        type = S.union { alternatives = { S.literal { value = "file" }, S.literal { value = "directory" }, S.literal { value = "symlink" }, S.literal { value = "other" } } },
        size = S.integer(),
        mode = S.integer(),
    } } } }
    local signature = {
        params = S.table { fields = { { "path", S.string() } } },
        returns = S.table { fields = { { "stat", stat } } },
    }
    local schema = S.func { signatures = { signature } }
    assert(S.validate(schema, fs.stat) and S.conform(schema, fs.stat) == fs.stat)
    local path = host.project_dir .. "/test.lua"
    assert(S.validate_call(schema, path) == signature)
    assert(S.validate(signature.returns, table.pack(fs.stat(path))))
    assert(S.validate(signature.returns, table.pack(fs.stat(host.project_dir .. "/missing-file"))))
end)

test("call conformance returns only structured arguments", function()
    local signature = {
        params = S.alt { alternatives = {
            { "options", S.table { fields = { { "options", S.table { fields = { enabled = S.boolean { default = false } } } } } } },
            { "positional", S.table { fields = { { "enabled", S.boolean() }, { "args", S.null(), arity = "*" } } } },
        } },
        returns = S.table { fields = {} },
    }
    local schema = S.registry { definitions = { Tool = S.func { signatures = { signature } } }, schema = S.ref { name = "Tool" } }
    local input = {}
    local output = S.conform_call(schema, input)
    assert(output.tag == "options")
    assert(output.value.options.enabled == false and next(input) == nil)
    output = S.conform_call(schema, false, nil, nil)
    assert(output.tag == "positional" and output.value.enabled == false)
    assert(output.value.args.n == 2)
    assert(select("#", S.conform_call(schema, input)) == 1)
    assert(S.validate_call(schema, false, nil, nil) == signature)
    local ok, thrown = pcall(S.conform_call, schema, "invalid")
    assert(not ok and thrown.exit_code == 1 and thrown.message == "Tool: argument \"options\" must be a table, got string (branch options)")
end)

test("call errors identify the function, named argument, nested field, and branch", function()
    local signature = {
        params = S.alt { alternatives = {
            { "options", S.table { fields = { { "options", S.table { fields = { url = S.string(), sha256 = S.string() } } } } } },
            { "positional", S.table { fields = { { "url", S.string() }, { "sha256", S.string() } } } },
        } },
        returns = S.table { fields = {} },
    }
    local schema = S.func { signatures = { signature }, name = "fetch" }
    local ok, thrown = pcall(S.conform_call, schema, "https://example.com", 42)
    assert(not ok and thrown.message == "fetch: argument \"sha256\" must be a string, got number (branch positional)")
    assert(thrown.exit_code == 1)
    ok, thrown = pcall(S.conform_call, schema, { url = "https://example.com" })
    assert(not ok and thrown.message == "fetch: field \"options.sha256\" is required (branch options)")
    local valid, validation_error = pcall(S.validate_call, schema, { url = "https://example.com" })
    assert(not valid and validation_error.message == thrown.message)

    local registry = S.registry { definitions = { Alias = schema }, schema = S.ref { name = "Alias" } }
    ok, thrown = pcall(S.conform_call, registry, "https://example.com", false)
    assert(not ok and thrown.message:match("^fetch:"))
    local unnamed = S.registry { definitions = { fetch = S.func { signatures = { signature } } }, schema = S.ref { name = "fetch" } }
    ok, thrown = pcall(S.conform_call, unnamed, "https://example.com", false)
    assert(not ok and thrown.message:match("^fetch:"))
    local stat = S.func { signatures = { { params = S.table { fields = { { "path", S.string() } } }, returns = S.table { fields = {} } } }, name = "fs.stat" }
    ok, thrown = pcall(S.conform_call, stat, "path", "extra")
    assert(not ok and thrown.message == "fs.stat: unexpected argument #2")
end)

test("validation and conformance throw the same formatted failures", function()
    local cases = {
        { S.string(), false },
        { S.table { fields = { name = S.string() } }, {} },
        { S.table { fields = { { "value", S.string() } } }, table.pack(nil) },
        { S.alt { alternatives = { { "text", S.table { fields = { { "value", S.string() } } } } } }, table.pack(false) },
    }
    for _, case in ipairs(cases) do
        local valid, validation_error = pcall(S.validate, case[1], case[2])
        local conformed, conformance_error = pcall(S.conform, case[1], case[2])
        assert(not valid and not conformed)
        assert(validation_error.message == conformance_error.message and conformance_error.exit_code == 1)
    end
end)

test("call errors use sentences and one quoted path for nested fields", function()
    local cases = {
        { S.table { fields = { { "path", S.string() } } }, table.pack(), "fetch: argument \"path\" is required" },
        { S.table { fields = { { "count", S.integer() } } }, table.pack(1.5), "fetch: argument \"count\" must be an integer, got number" },
        { S.table { fields = { { "value", S.null() } } }, table.pack(false), "fetch: argument \"value\" must be nil, got boolean" },
        { S.table { fields = { { "mode", S.union { alternatives = { S.literal { value = "capture" }, S.literal { value = "inherit" } } } } } }, table.pack("other"),
            "fetch: argument \"mode\" must be \"capture\" or \"inherit\", got string" },
        { S.table { fields = { { "options", S.table { fields = { sha256 = S.string() } } } } }, table.pack({}),
            "fetch: field \"options.sha256\" is required" },
        { S.table { fields = { { "options", S.table { fields = { sha256 = S.string() } } } } }, table.pack({ sha256 = 42 }),
            "fetch: field \"options.sha256\" must be a string, got number" },
        { S.table { fields = { { "options", S.table { fields = {} } } } }, table.pack({ typo = true }),
            "fetch: unknown field \"options.typo\"" },
        { S.table { fields = { { "options", S.map { key = S.string(), value = S.any() } } } }, table.pack({ [1] = true }),
            "fetch: key of field \"options[1]\" must be a string, got number" },
        { S.table { fields = { { "values", S.table { fields = { { "items", S.string(), arity = "*" } } } } } }, table.pack({ [2] = "second" }),
            "fetch: field \"values[1]\" is missing; positional entries must form a dense sequence" },
        { S.table { fields = { { "url", S.string { validate = function() return false, "must use HTTPS" end } } } }, table.pack("http://example.com"),
            "fetch: argument \"url\" failed validation (must use HTTPS)" },
    }
    for _, case in ipairs(cases) do
        local schema = S.func { signatures = { { params = case[1], returns = S.table { fields = {} } } }, name = "fetch" }
        local ok, thrown = pcall(S.validate_call, schema, table.unpack(case[2], 1, case[2].n))
        assert(not ok and thrown.message == case[3], thrown.message)
        local conformed, conformance_error = pcall(S.conform_call, schema, table.unpack(case[2], 1, case[2].n))
        assert(not conformed and conformance_error.message == case[3], conformance_error.message)
    end
end)

test("alternative failures retain paths after checking later branches", function()
    local schema = S.alt { alternatives = {
        { "deep", S.table { fields = { nested = S.table { fields = { leaf = S.string() } } } } },
        { "shallow", S.table { fields = { nested = S.any(), required = S.number() } } },
    } }
    local input = { nested = { leaf = false } }
    rejects(schema, input, "value.nested.leaf (branch deep): expected string, got boolean")
    local ok, thrown = pcall(S.conform, schema, input)
    assert(not ok and thrown.message == "value.nested.leaf (branch deep): expected string, got boolean")
end)

test("table checks retain sorted predicates, unknown fields, and metatable traversal", function()
    local seen = {}
    local schema = S.table { fields = {
        b = S.string { validate = function() seen[#seen + 1] = "b"; return true end },
        a = S.string { validate = function() seen[#seen + 1] = "a"; return true end },
    } }
    local input = setmetatable({ a = "a", b = "b" }, { __pairs = function(value)
        seen[#seen + 1] = "pairs"
        return next, value, nil
    end })
    for _, operation in ipairs({ S.validate, S.conform }) do
        seen = {}
        operation(schema, input)
        assert(table.concat(seen, ",") == "pairs,a,b,pairs")
    end
    rejects(schema, { a = "a", b = "b", z = true, c = true }, "value.c: unknown field")
end)

test("table checks observe schema field edits between calls", function()
    local fields = { name = S.string() }
    local schema = S.table { fields = fields }
    local input = { name = "tool" }
    assert(S.validate(schema, input) == input)
    fields.enabled = S.boolean { default = false }
    assert(S.conform(schema, input).enabled == false)
    fields.name = S.number()
    rejects(schema, input, "value.name: expected number, got string")
    fields.name = nil
    rejects(schema, input, "value.name: unknown field")
end)

test("discarded literal failures still run formatting hooks and propagate exceptions", function()
    local calls = 0
    local token = setmetatable({}, { __tostring = function()
        calls = calls + 1
        return "token"
    end })
    local schema = S.union { alternatives = { S.literal { value = token }, S.any() } }
    local input = {}
    assert(S.validate(schema, input) == input and calls == 1)
    assert(S.conform(schema, input) == input and calls == 2)
    local exception = {}
    getmetatable(token).__tostring = function() error(exception) end
    local ok, thrown = pcall(S.validate, schema, input)
    assert(not ok and thrown == exception)
end)

test("earlier type failures retain labels when a later predicate edits the schema", function()
    local literal = S.literal { value = "original" }
    local schema = S.alt { alternatives = {
        { "deep", S.table { fields = { nested = S.table { fields = { leaf = literal } } } } },
        { "shallow", S.table { fields = { nested = S.any() }, validate = function()
            literal.value = "changed"
            return false, "rejected"
        end } },
    } }
    for _, operation in ipairs({ S.validate, S.conform }) do
        literal.value = "original"
        local ok, thrown = pcall(operation, schema, { nested = { leaf = false } })
        assert(not ok and thrown.message == 'value.nested.leaf (branch deep): expected "original", got boolean')
        assert(literal.value == "changed")
    end
end)

test("table inheritance merges defaults and overrides before predicates", function()
    local calls = {}
    local parent = S.table { fields = {
        label = S.string { default = "base" }, enabled = S.boolean { default = false },
    }, validate = function(value)
        calls[#calls + 1] = "parent"
        assert(value.label == "child" and value.enabled == false and value.count ~= nil)
        return value.count >= 0, "count must be nonnegative"
    end }
    local child = S.table { extends = S.ref { name = "Parent" }, fields = {
        label = S.string { default = "child" }, count = S.integer { default = 1 },
    }, validate = function(value)
        calls[#calls + 1] = "child"
        return value.count <= 5, "count must be at most five"
    end }
    local grandchild = S.table { extends = S.ref { name = "Child" }, fields = { ready = S.boolean { default = true } } }
    local schema = S.registry { definitions = { Parent = parent, Child = child }, schema = grandchild }
    local input = {}
    assert(S.validate(schema, input) == input and next(input) == nil)
    local output = S.conform(schema, input)
    assert(output.label == "child" and output.enabled == false and output.count == 1 and output.ready)
    assert(table.concat(calls, ",") == "parent,child,parent,child")
    rejects(schema, { count = -1 }, "value: count must be nonnegative")
    rejects(schema, { count = 6 }, "value: count must be at most five")
    rejects(schema, { unrelated = true }, "value.unrelated: unknown field")
    rejects(parent, { label = "child", count = 1 }, "value.count: unknown field")
    assert(parent.fields.count == nil and child.fields.ready == nil and grandchild.fields.label == nil)
end)

test("inherited named and positional references keep the defining registry", function()
    local schema = S.registry {
        definitions = {
            Value = S.string { default = "outer" },
            Parent = S.table { fields = {
                { "first", S.ref { name = "Value" } }, { "rest", S.ref { name = "Value" }, arity = "*" },
                name = S.ref { name = "Value" },
                call = S.func { signatures = { {
                    params = S.table { fields = { { "value", S.ref { name = "Value" } } } },
                    returns = S.table { fields = {} },
                } } },
            } },
        },
        schema = S.registry {
            definitions = {
                Value = S.integer(),
                Child = S.table { extends = S.ref { name = "Parent" }, fields = { number = S.ref { name = "Value" } } },
            },
            schema = S.ref { name = "Child" },
        },
    }
    local fn = function() end
    local input = { "first", "second", number = 2, call = fn }
    assert(S.validate(schema, input) == input)
    local output = S.conform(schema, input)
    assert(output.first == "first" and output.rest[1] == "second" and output.rest.n == 1)
    assert(output.name == "outer" and output.number == 2 and output.call == fn and input.name == nil)
    rejects(schema, { 1, number = 2, call = fn }, "value[1] (first): expected string, got number")
    assert(S.validate(S.at(schema, { "name" }), "text") == "text")
    assert(S.validate(S.at(schema, { 1 }), "text") == "text")
    assert(S.validate(S.at(schema, { "number" }), 2) == 2)
    local call = S.at(schema, { "call" })
    assert(S.conform_call(call, "text").value == "text")
    t.assert_error("call: argument \"value\" must be a string, got number", function() S.validate_call(call, 2) end)
end)

test("child positionals replace the complete inherited sequence", function()
    local schema = S.registry {
        definitions = { Parent = S.table { fields = {
            { "strings", S.string(), arity = "*" }, flag = S.boolean { default = true },
        } } },
        schema = S.table { extends = S.ref { name = "Parent" }, fields = { { "number", S.integer() } } },
    }
    local output = S.conform(schema, { 42 })
    assert(output.number == 42 and output.flag and output.strings == nil)
    rejects(schema, { 42, "extra" }, "value[2]: unexpected positional argument")
    rejects(schema, { "old" }, "value[1] (number): expected integer, got string")
    assert(S.validate(S.at(schema, { 1 }), 42) == 42)
end)

test("call conformance inherits optional positionals and their defaults", function()
    local schema = S.registry {
        definitions = {
            Params = S.table { fields = { { "path", S.string { default = "default" }, arity = "?" } } },
        },
        schema = S.func { name = "call", signatures = { {
            params = S.table { extends = S.ref { name = "Params" }, fields = {} },
            returns = S.table { fields = {} },
        } } },
    }
    assert(S.conform_call(schema).path == "default")
    assert(S.conform_call(schema, "supplied").path == "supplied")
    t.assert_error("argument \"path\" must be a string, got nil", function() S.validate_call(schema, nil) end)
end)
