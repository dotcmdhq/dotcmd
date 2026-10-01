local S = require("dotcmd.schema")
local L = require("dotcmd.luals")

local function contains(text, expected)
    assert(text:find(expected, 1, true), "missing declaration: " .. expected .. "\n" .. text)
end

local function signature(params, returns)
    return { params = S.table { fields = params }, returns = S.table { fields = returns or {} } }
end

test("primitives, literals, unions and maps describe input types", function()
    local schema = S.registry {
        definitions = {
            Count = S.integer(), Nothing = S.null(), Flag = S.boolean(), Number = S.number(),
            Handle = S.file(),
            Labels = S.map { key = S.string(), value = S.array { items = S.string() } },
            Choice = S.union { alternatives = { S.literal { value = "a\nb" }, S.literal { value = false }, S.null() } },
        },
        schema = S.table { fields = { labels = S.ref { name = "Labels" } } },
    }
    local text = L.generate(schema, "example")
    contains(text, "---@alias example.Count integer")
    contains(text, "---@alias example.Number number")
    contains(text, "---@alias example.Flag boolean")
    contains(text, "---@alias example.Nothing nil")
    contains(text, "---@alias example.Handle file*")
    contains(text, "---@alias example.Choice \"a\\nb\"|false|nil")
    contains(text, "---@alias example.Labels table<string, string[]>")
    contains(text, "---@type example.Labels\nlabels = nil")
    assert(load(text))
end)

test("mixed tables retain positions, required values and optional defaults", function()
    local text = L.generate(S.registry {
        definitions = { Options = S.table { fields = {
            { "program", S.string() }, { "args", S.number(), arity = "*" },
            mode = S.string { default = "fast", description = "Execution mode." },
            enabled = S.boolean { default = false },
            name = S.optional { schema = S.string() },
            ["odd key"] = S.integer(),
        } } },
        schema = S.table { fields = {} },
    })
    contains(text, "---@class (exact) Options")
    contains(text, "---@field [1] string")
    contains(text, "---@field [integer] number")
    contains(text, "---@field mode? string Execution mode. Default: \"fast\".")
    contains(text, "---@field enabled? boolean Default: false.")
    contains(text, "---@field name? string")
    contains(text, "---@field [\"odd key\"] integer")
end)

test("forward and recursive references remain named", function()
    local text = L.generate(S.registry {
        definitions = {
            Node = S.table { fields = { children = S.array { items = S.ref { name = "Node" } } } },
            RecursiveArray = S.array { items = S.ref { name = "RecursiveArray" } },
            RecursiveUnion = S.union { alternatives = { S.ref { name = "RecursiveUnion" }, S.string() } },
            Names = S.array { items = S.ref { name = "Name" } }, Name = S.string(),
        },
        schema = S.table { fields = { node = S.ref { name = "Node" }, union = S.ref { name = "RecursiveUnion" } } },
    }, "tree")
    contains(text, "---@field children tree.Node[]")
    contains(text, "---@alias tree.RecursiveArray tree.RecursiveArray[]")
    contains(text, "---@alias tree.Names tree.Name[]")
    contains(text, "---@alias tree.RecursiveUnion tree.RecursiveUnion|string")
    assert(text == L.generate(S.registry {
        definitions = {
            Names = S.array { items = S.ref { name = "Name" } }, Name = S.string(),
            RecursiveArray = S.array { items = S.ref { name = "RecursiveArray" } },
            RecursiveUnion = S.union { alternatives = { S.ref { name = "RecursiveUnion" }, S.string() } },
            Node = S.table { fields = { children = S.array { items = S.ref { name = "Node" } } } },
        },
        schema = S.table { fields = { node = S.ref { name = "Node" }, union = S.ref { name = "RecursiveUnion" } } },
    }, "tree"))
end)

test("nested registries shadow locally and preserve outer references", function()
    local nested = S.registry {
        definitions = { Name = S.integer() },
        schema = S.table { fields = { local_name = S.ref { name = "Name" }, outer = S.ref { name = "Outer" } } },
    }
    local text = L.generate(S.registry {
        definitions = { Name = S.string(), Outer = S.boolean(), ["Scope1.Name"] = S.number() },
        schema = S.table { fields = { nested = nested, name = S.ref { name = "Name" } } },
    }, "scoped")
    contains(text, "---@alias scoped.Scope1.Name number")
    contains(text, "---@alias scoped.Scope1.Name_2 integer")
    contains(text, "---@type { local_name: scoped.Scope1.Name_2, outer: scoped.Outer }")
    contains(text, "---@type scoped.Name\nname = nil")
end)

test("non-record roots get an alias without colliding with definitions", function()
    local text = L.generate(S.registry {
        definitions = { Value = S.string() }, schema = S.ref { name = "Value" },
    })
    contains(text, "---@alias Value string")
    contains(text, "---@alias Value_2 string")
end)

test("global overloads preserve argument lists and repeated results", function()
    local text = L.generate(S.table { fields = {
        call = S.func { description = "Call a program.", signatures = {
            signature({ { "options", S.table { fields = { path = S.string() } } } }, { { "result", S.boolean() } }),
            signature({ { "program", S.string() }, { "arguments", S.string(), arity = "*" } }, { { "result", S.boolean() } }),
        } },
        many = S.func { signatures = { signature({ { "values", S.integer(), arity = "+" } }, {
            { "first", S.string() }, { "more", S.any(), arity = "*" },
        }) } },
    } })
    contains(text, "---Call a program.\n---@overload fun(program: string, ...: string): boolean")
    contains(text, "---@param options { path: string }")
    contains(text, "function call(options) end")
    contains(text, "---@param values integer\n---@param ... integer")
    contains(text, "---@return string first\n---@return any ...")
    contains(text, "function many(values, ...) end")
end)

test("named alternatives describe input shapes rather than conformed tags", function()
    local text = L.generate(S.table { fields = {
        parse = S.func { signatures = { {
            params = S.alt { alternatives = {
                { "text", S.table { fields = { { "text", S.string() } } } },
                { "number", S.table { fields = { { "value", S.number() } } } },
            } },
            returns = S.table { fields = { { "value", S.optional { schema = S.string() }, arity = "?" } } },
        } } },
    } })
    contains(text, "---@overload fun(value: number): string|nil")
    contains(text, "---@param text string")
    contains(text, "---@return string|nil value")
    assert(not text:find("tag", 1, true))
end)

test("literal meanings and per-use reference descriptions survive generation", function()
    local text = L.generate(S.registry {
        definitions = {
            Mode = S.union { alternatives = {
                S.literal { value = "skip", description = "Keep existing output." },
                S.literal { value = "replace", description = "Publish new output.\nPreserve permissions." },
            } },
            Run = S.func { signatures = { signature({}) }, description = "Generic function." },
        },
        schema = S.table { fields = {
            run = S.ref { name = "Run", description = "Run this task." },
            mode = S.ref { name = "Mode" },
        } },
    })
    contains(text, "---@alias Mode\n---| \"skip\" # Keep existing output.")
    contains(text, "---| \"replace\" # Publish new output.<br>Preserve permissions.")
    contains(text, "---Run this task.\nfunction run() end")
    contains(text, "---@type Mode\nmode = nil")
    assert(not text:find("---Keep existing output.\n---@type Mode", 1, true))
end)

test("generation neither executes callbacks nor changes schemas", function()
    local calls = 0
    local schema = S.table { fields = { name = S.string { description = "Name.", validate = function()
        calls = calls + 1
        error("must not run")
    end } } }
    local field = schema.fields.name
    local first = L.generate(schema)
    assert(first == L.generate(schema) and calls == 0)
    assert(schema.fields.name == field and field.type == "string" and field.validate)
    for key in pairs(field) do assert(key == "type" or key == "description" or key == "validate") end
end)

test("full API emits every public global and preserves schema contracts", function()
    local api = require("dotcmd.api")
    local text = L.generate(api, "dotcmd")
    for name, schema in pairs(api.schema.fields) do
        if schema.type == "function" then contains(text, "function " .. name .. "(")
        else contains(text, name .. " = nil") end
    end
    contains(text, "---@overload fun(url: string, sha256: string): string")
    contains(text, "---@param command dotcmd.Command|dotcmd.ExecCommand")
    contains(text, "---@param command dotcmd.Command|dotcmd.SpawnCommand")
    contains(text, "---@field body? string|any Binary-safe response string by default")
    contains(text, "---@field stdin file* Present when stdin is piped.")
    contains(text, "---@field stdout file* Present when stdout is piped.")
    contains(text, "---@field stderr file* Present when stderr is piped.")
    assert(not text:find("dotcmd.FileHandle", 1, true))
    contains(text, "---@field stdout string Present when captured.")
    contains(text, "---@field stderr string Present when captured.")
    contains(text, "---@field check? any False disables HTTP status checking;")
    assert(not text:find("dotcmd.Format", 1, true))
    assert(load(text))
end)

test("named children emit inheritance and only their own fields", function()
    local schema = S.registry {
        definitions = {
            Parent = S.table { fields = { name = S.string { description = "Parent name." }, count = S.integer() } },
            Child = S.table { extends = S.ref { name = "Parent" }, fields = { count = S.string(), enabled = S.boolean() } },
            Grandchild = S.table { extends = S.ref { name = "Child" }, fields = {} },
        },
        schema = S.table { fields = {} },
    }
    local text = L.generate(schema, "example")
    contains(text, "---@class (exact) example.Child: example.Parent\n---@field count string\n---@field enabled boolean\n\n")
    contains(text, "---@class (exact) example.Grandchild: example.Child\n\n")
    contains(text, "---@class (exact) example.Parent\n---@field count integer\n---@field name string Parent name.")
    assert(schema.definitions.Child.fields.name == nil)
end)

test("anonymous inherited records and signatures preserve reference scopes", function()
    local text = L.generate(S.registry {
        definitions = {
            Value = S.string(),
            Parent = S.table { fields = { name = S.ref { name = "Value" } } },
            Params = S.table { fields = { { "text", S.ref { name = "Value" } } } },
        },
        schema = S.registry {
            definitions = {
                Value = S.integer(),
                Child = S.table { extends = S.ref { name = "Parent" }, fields = { number = S.ref { name = "Value" } } },
            },
            schema = S.table { fields = {
                child = S.table { extends = S.ref { name = "Parent" }, fields = { number = S.ref { name = "Value" } } },
                run = S.func { signatures = { {
                    params = S.table { extends = S.ref { name = "Params" }, fields = {} },
                    returns = S.table { extends = S.ref { name = "Params" }, fields = {} },
                } } },
            } },
        },
    }, "scoped")
    contains(text, "---@class (exact) scoped.Scope1.Child: scoped.Parent\n---@field number scoped.Scope1.Value")
    contains(text, "---@type { name: scoped.Value, number: scoped.Scope1.Value }")
    contains(text, "---@param text scoped.Value\n---@return scoped.Value text\nfunction run(text) end")
end)

test("inherited roots expose inherited globals", function()
    local text = L.generate(S.registry {
        definitions = { Parent = S.table { fields = { inherited = S.string() } } },
        schema = S.table { extends = S.ref { name = "Parent" }, fields = { own = S.integer() } },
    })
    contains(text, "---@type string\ninherited = nil")
    contains(text, "---@type integer\nown = nil")
end)
