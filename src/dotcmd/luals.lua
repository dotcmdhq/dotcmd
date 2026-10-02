-- Generate LuaLS declarations for schema inputs, without running predicates or
-- applying conformance. Named definitions become classes/aliases; a root record
-- describes globals. Other roots become a Value alias. Names are registry-local.
-- LuaLS cannot express arbitrary predicates, literal identity, dense sequence
-- constraints, or the difference between omission and an explicitly supplied nil.
local L = {}

local keywords = {}
for word in ("and break do else elseif end false for function goto if in local nil not or repeat return then true until while"):gmatch("%S+") do
    keywords[word] = true
end

local function identifier(name)
    return type(name) == "string" and name:match("^[%a_][%w_]*$") and not keywords[name]
end

local function sorted_keys(value)
    local result = {}
    for key in pairs(value) do result[#result + 1] = key end
    table.sort(result, function(a, b)
        if type(a) ~= type(b) then return type(a) < type(b) end
        return a < b
    end)
    return result
end

local function quote(value)
    return string.format("%q", value):gsub("\\\n", "\\n")
end

local function parameter_name(name)
    name = name:gsub("[^%w_]", "_")
    if not identifier(name) then name = "arg_" .. name end
    return name
end

local function literal(value)
    local kind = type(value)
    if kind == "string" then return quote(value) end
    if kind == "nil" or kind == "boolean" then return tostring(value) end
    if kind == "number" then
        return value == value and math.abs(value) < math.huge and tostring(value) or "number"
    end
    return kind
end

local function join_union(types)
    local result, seen = {}, {}
    for _, name in ipairs(types) do
        if not seen[name] then result[#result + 1] = name; seen[name] = true end
    end
    return table.concat(result, "|")
end

---Generate a standalone LuaLS definition document. Root record fields are globals;
---other roots are a Value alias.
---Descriptions/defaults are included; callbacks and inputs are never modified or executed.
---@param schema schema.Schema
---@return string annotations
local function generate(schema)
    local pending, scopes, scope_count, names = {}, {}, 0, {}
    local function allocate(name)
        local candidate, suffix = name, 2
        while names[candidate] do candidate = name .. "_" .. suffix; suffix = suffix + 1 end
        names[candidate] = true
        return candidate
    end
    local function enter(registry, parent)
        local siblings = scopes[parent or false]
        if not siblings then siblings = {}; scopes[parent or false] = siblings end
        if siblings[registry] then return siblings[registry] end
        local prefix = ""
        if parent then
            scope_count = scope_count + 1
            prefix = "Scope" .. scope_count
        end
        local scope = { parent = parent, definitions = {} }
        siblings[registry] = scope
        for _, name in ipairs(sorted_keys(registry.definitions)) do
            local qualified = prefix == "" and name or prefix .. "." .. name
            local definition = { name = allocate(qualified), schema = registry.definitions[name], scope = scope }
            scope.definitions[name] = definition
            pending[#pending + 1] = definition
        end
        return scope
    end
    local function resolve(name, scope)
        while scope do
            if scope.definitions[name] then return scope.definitions[name] end
            scope = scope.parent
        end
        error("undefined schema reference: " .. name, 0)
    end
    local function unwrap(value, scope)
        while value.type == "registry" or value.type == "ref" do
            if value.type == "registry" then
                scope = enter(value, scope)
                value = value.schema
            else
                local definition = resolve(value.name, scope)
                value, scope = definition.schema, definition.scope
            end
        end
        return value, scope
    end
    local function inherited_fields(value, scope)
        if not value.extends then return value.fields, nil, scope end
        local parent, owner = unwrap(value.extends, scope)
        local inherited, owners, sequence_scope = inherited_fields(parent, owner)
        local fields, scopes = {}, {}
        for key, field in pairs(inherited) do
            fields[key] = field
            if owners then scopes[key] = owners[key] else scopes[key] = owner or false end
        end
        if #value.fields > 0 then
            for i = 1, #fields do fields[i] = nil end
            sequence_scope = scope
        end
        for key, field in pairs(value.fields) do fields[key], scopes[key] = field, scope or false end
        return fields, scopes, sequence_scope
    end
    local function nullable(value, scope, visited)
        visited = visited or {}
        if visited[value] then return false end
        visited[value] = true
        if value.type == "any" or value.type == "nil" then return true end
        if value.type == "literal" then return value.value == nil end
        if value.type == "registry" or value.type == "ref" then
            value, scope = unwrap(value, scope)
            return nullable(value, scope, visited)
        end
        if value.type == "union" then
            for _, alternative in ipairs(value.alternatives) do
                if nullable(alternative, scope, visited) then return true end
            end
        end
        return false
    end
    local function property(value, scope, key)
        while true do
            if value[key] ~= nil then return value[key] end
            if value.type == "registry" then
                scope = enter(value, scope)
                value = value.schema
            elseif value.type == "ref" then
                local definition = resolve(value.name, scope)
                value, scope = definition.schema, definition.scope
            else
                return nil
            end
        end
    end
    local function description(value, scope, visited)
        local text = property(value, scope, "description")
        if text then return text end
        value, scope = unwrap(value, scope)
        visited = visited or {}
        if visited[value] then return nil end
        visited[value] = true
        if value.type == "union" then
            local candidate
            for _, alternative in ipairs(value.alternatives) do
                if alternative.type ~= "nil" and not (alternative.type == "literal" and alternative.value == nil) then
                    if candidate then return nil end
                    candidate = alternative
                end
            end
            return candidate and description(candidate, scope, visited) or nil
        end
        if value.type == "table" and #value.fields == 1 then
            return description(value.fields[1][2], scope, visited)
        end
        if value.type == "map" then return description(value.value, scope, visited) end
    end
    local function comment(value, scope)
        local text = description(value, scope) or ""
        local default = property(value, scope, "default")
        if default ~= nil and type(default) ~= "table" and type(default) ~= "function" then
            text = text .. (text == "" and "" or " ") .. "Default: " .. literal(default) .. "."
        end
        return text == "" and "" or " " .. text:gsub("\n", "<br>")
    end
    local function optional(value, scope)
        return property(value, scope, "default") ~= nil or nullable(value, scope)
    end

    local render, signatures
    local function entries(value, scope)
        value, scope = unwrap(value, scope)
        if value.type == "alt" then
            local result = {}
            for _, branch in ipairs(value.alternatives) do
                for _, sequence in ipairs(entries(branch[2], scope)) do result[#result + 1] = sequence end
            end
            return result
        end
        local fields, _, sequence_scope = inherited_fields(value, scope)
        return { { fields = fields, scope = sequence_scope } }
    end
    local function returns(sequence)
        local result = {}
        for _, entry in ipairs(sequence.fields) do
            local kind = render(entry[2], sequence.scope)
            if entry.arity == "?" and not nullable(entry[2], sequence.scope) then kind = kind .. "|nil" end
            if entry.arity == "*" then result[#result + 1] = "...: " .. kind
            elseif entry.arity == "+" then
                result[#result + 1] = kind
                result[#result + 1] = "...: " .. kind
            else result[#result + 1] = kind end
        end
        return #result == 0 and "" or ": " .. table.concat(result, ", ")
    end
    local function signature_type(signature)
        local parameters = {}
        for _, entry in ipairs(signature.params.fields) do
            local kind = render(entry[2], signature.params.scope)
            if entry.arity == "*" then parameters[#parameters + 1] = "...: " .. kind
            else
                parameters[#parameters + 1] = parameter_name(entry[1]) .. (entry.arity == "?" and "?" or "") .. ": " .. kind
                if entry.arity == "+" then parameters[#parameters + 1] = "...: " .. kind end
            end
        end
        return "fun(" .. table.concat(parameters, ", ") .. ")" .. returns(signature.returns)
    end
    signatures = function(value, scope)
        local result = {}
        for _, signature in ipairs(value.signatures) do
            for _, params in ipairs(entries(signature.params, scope)) do
                for _, output in ipairs(entries(signature.returns, scope)) do
                    result[#result + 1] = { params = params, returns = output }
                end
            end
        end
        return result
    end
    local function type_union(alternatives, scope, omit_nil)
        local types = {}
        for _, alternative in ipairs(alternatives) do
            local kind = render(alternative, scope, omit_nil)
            if kind ~= "" then
                if kind:match("^fun%(") then kind = "(" .. kind .. ")" end
                types[#types + 1] = kind
            end
        end
        return join_union(types)
    end
    local function field_name(key)
        return identifier(key) and key or "[" .. literal(key) .. "]"
    end
    local function table_fields(value, scope, own)
        local declared, owners, sequence_scope
        if own then declared, sequence_scope = value.fields, scope
        else declared, owners, sequence_scope = inherited_fields(value, scope) end
        local fields, indexed = {}, {}
        for i, entry in ipairs(declared) do
            local kind = render(entry[2], sequence_scope)
            local arity = entry.arity or "1"
            if arity == "*" or arity == "+" then
                indexed[#indexed + 1] = kind
                if arity == "+" then fields[#fields + 1] = { name = "[" .. i .. "]", kind = kind, schema = entry[2], scope = sequence_scope } end
            else
                fields[#fields + 1] = { name = "[" .. i .. "]", kind = kind,
                    optional = arity == "?", schema = entry[2], scope = sequence_scope }
            end
        end
        if #indexed > 0 then fields[#fields + 1] = { name = "[integer]", kind = join_union(indexed) } end
        for _, key in ipairs(sorted_keys(declared)) do
            if type(key) == "string" then
                local owner = scope
                if owners then owner = owners[key] or nil end
                local item = declared[key]
                local kind = render(item, owner, true)
                fields[#fields + 1] = { name = field_name(key), kind = kind == "" and "nil" or kind,
                    optional = optional(item, owner), schema = item, scope = owner }
            end
        end
        return fields
    end
    render = function(value, scope, omit_nil)
        local kind = value.type
        if kind == "registry" then return render(value.schema, enter(value, scope), omit_nil) end
        if kind == "ref" then return resolve(value.name, scope).name end
        if kind == "file" then return "file*" end
        if kind == "nil" then return omit_nil and "" or "nil" end
        if kind == "literal" then return value.value == nil and omit_nil and "" or literal(value.value) end
        if kind == "union" then return type_union(value.alternatives, scope, omit_nil) end
        if kind == "alt" then
            local alternatives = {}
            for _, branch in ipairs(value.alternatives) do alternatives[#alternatives + 1] = branch[2] end
            return type_union(alternatives, scope, omit_nil)
        end
        if kind == "map" then return "table<" .. render(value.key, scope) .. ", " .. render(value.value, scope) .. ">" end
        if kind == "table" then
            local fields = table_fields(value, scope)
            if #fields == 1 and fields[1].name == "[integer]" then
                local item = fields[1].kind
                if item:find("|", 1, true) or item:match("^fun%(") then item = "(" .. item .. ")" end
                return item .. "[]"
            end
            local items = {}
            for _, field in ipairs(fields) do
                items[#items + 1] = field.name .. (field.optional and "?" or "") .. ": " .. field.kind
            end
            return "{ " .. table.concat(items, ", ") .. " }"
        end
        if kind == "function" then
            local types = {}
            local overloads = signatures(value, scope)
            for _, signature in ipairs(overloads) do
                local name = signature_type(signature)
                types[#types + 1] = #overloads == 1 and name or "(" .. name .. ")"
            end
            return join_union(types)
        end
        return kind
    end

    local declarations, globals = { "-- Generated by .cmd --setup luals; do not edit.", "---@meta", "" }, {}
    local function describe(lines, value, scope)
        local text = property(value, scope, "description")
        if text then
            for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = "---" .. line end
        end
    end
    local function documented_choices(value)
        if value.type ~= "union" then return false end
        for _, alternative in ipairs(value.alternatives) do
            if alternative.description then return true end
        end
        return false
    end
    local function emit_function(key, value, scope, declared, declared_scope)
        describe(globals, declared, declared_scope)
        local overloads = signatures(value, scope)
        for i = 2, #overloads do globals[#globals + 1] = "---@overload " .. signature_type(overloads[i]) end
        local first, names = overloads[1], {}
        for _, entry in ipairs(first.params.fields) do
            local name = entry.arity == "*" and "..." or parameter_name(entry[1])
            names[#names + 1] = name
            globals[#globals + 1] = "---@param " .. name .. (entry.arity == "?" and "?" or "") .. " "
                .. render(entry[2], first.params.scope) .. comment(entry[2], first.params.scope)
            if entry.arity == "+" then
                names[#names + 1] = "..."
                globals[#globals + 1] = "---@param ... " .. render(entry[2], first.params.scope)
            end
        end
        for _, entry in ipairs(first.returns.fields) do
            local kind = render(entry[2], first.returns.scope)
            if entry.arity == "?" and not nullable(entry[2], first.returns.scope) then kind = kind .. "|nil" end
            local repeated = entry.arity == "*" or entry.arity == "+"
            if entry.arity ~= "*" then
                globals[#globals + 1] = "---@return " .. kind .. " " .. parameter_name(entry[1]) .. comment(entry[2], first.returns.scope)
            end
            if repeated then globals[#globals + 1] = "---@return " .. kind .. " ..." .. comment(entry[2], first.returns.scope) end
        end
        local arguments = table.concat(names, ", ")
        globals[#globals + 1] = identifier(key) and ("function " .. key .. "(" .. arguments .. ") end")
            or ("_G[" .. quote(key) .. "] = function(" .. arguments .. ") end")
        globals[#globals + 1] = ""
    end
    local root, scope = unwrap(schema, nil)
    local root_fields, root_owners
    if root.type == "table" then root_fields, root_owners = inherited_fields(root, scope) end
    if root_fields and #root_fields == 0 then
        for _, key in ipairs(sorted_keys(root_fields)) do
            local declared_scope = scope
            if root_owners then declared_scope = root_owners[key] or nil end
            local value = root_fields[key]
            local shape, owner = unwrap(value, declared_scope)
            if shape.type == "function" then emit_function(key, shape, owner, value, declared_scope)
            else
                describe(globals, value, declared_scope)
                globals[#globals + 1] = "---@type " .. render(value, declared_scope)
                globals[#globals + 1] = (identifier(key) and key or "_G[" .. quote(key) .. "]") .. " = nil"
                globals[#globals + 1] = ""
            end
        end
    else
        pending[#pending + 1] = { name = allocate("Value"), schema = root, scope = scope }
    end
    local index = 1
    while index <= #pending do
        local definition = pending[index]
        local value, owner = definition.schema, definition.scope
        describe(declarations, value, owner)
        if value.type == "table" and (value.extends or not (#value.fields == 1 and value.fields[1].arity == "*"
            and #sorted_keys(value.fields) == 1)) then
            declarations[#declarations + 1] = "---@class (exact) " .. definition.name
                .. (value.extends and (": " .. render(value.extends, owner)) or "")
            for _, field in ipairs(table_fields(value, owner, true)) do
                declarations[#declarations + 1] = "---@field " .. field.name .. (field.optional and "?" or "") .. " "
                    .. field.kind .. (field.schema and comment(field.schema, field.scope) or "")
            end
        elseif documented_choices(value) then
            declarations[#declarations + 1] = "---@alias " .. definition.name
            for _, alternative in ipairs(value.alternatives) do
                local kind = render(alternative, owner)
                if kind:match("^fun%(") then kind = "(" .. kind .. ")" end
                local text = alternative.description
                declarations[#declarations + 1] = "---| " .. kind .. (text and " # " .. text:gsub("\n", "<br>") or "")
            end
        else
            declarations[#declarations + 1] = "---@alias " .. definition.name .. " " .. render(value, owner)
        end
        declarations[#declarations + 1] = ""
        index = index + 1
    end
    for _, line in ipairs(globals) do declarations[#declarations + 1] = line end
    return table.concat(declarations, "\n")
end

function L.setup()
    local config_path, annotations_path = ".luarc.json", ".cmd.d.lua"
    local config = fs.read(config_path)
    if config then
        assert(json.decode(config)["$dotcmd"] == true,
            "cannot overwrite unmanaged .luarc.json; set \"$dotcmd\": true to let dotcmd manage both .luarc.json and .cmd.d.lua")
    else
        assert(not fs.stat(".luarc.jsonc", { follow = false }),
            "cannot create .luarc.json alongside existing .luarc.jsonc; migrate it to managed .luarc.json first")
        assert(not fs.stat(annotations_path, { follow = false }),
            "cannot overwrite existing .cmd.d.lua without a managed .luarc.json")
    end

    local annotations = generate(require("dotcmd.api"))
    local configuration = json.encode({
        ["$dotcmd"] = true,
        runtime = {
            version = "Lua 5.5",
            path = { "?.lua", "?/init.lua" },
            pathStrict = true,
        },
        workspace = {
            ignoreDir = { "target", ".git" },
            checkThirdParty = "Disable",
        },
    }, { pretty = true }) .. "\n"
    fs.write(annotations_path, annotations .. "\n")
    fs.write(config_path, configuration)
    print("Configured LuaLS: .luarc.json and .cmd.d.lua")
end

return L
