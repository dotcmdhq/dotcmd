-- Schemas are ordinary tables. Definitions are trusted. validate and conform
-- accept the same inputs and never mutate them. conform returns defaults-filled
-- tables with named positional bindings, and {tag, value} alternative matches.
-- Custom predicates see the defaults-filled input shape before destructuring.
-- Function values retain their identity; *_call checks arguments without calling.
-- Validation failures throw {message, exit_code = 1}; custom
-- validator exceptions propagate unchanged.
-- Numeric definition entries are {name, schema, arity = "1"|"?"|"*"|"+"}.
-- Only the final positional entry may have non-1 arity. Use table.pack to
-- preserve nil positions. Named definition entries are field schemas.
-- Every constructor takes one properties table. Table fields combine named
-- fields with positional entries and reject undeclared fields. Maps describe
-- arbitrary keys/values separately; numeric keys and n are ordinary map data.

---@class schema.Properties<T>
---@field description? string Meaning of this value, for documentation and fallback validation messages.
---@field examples? string Examples rendered as a separate section in API documentation.
---@field default? T Used for a missing declared table field or omitted ? argument, including through references. Supplied nil arguments are checked as nil. Defaults are checked unchanged; table schemas construct fresh conformed outputs. Function defaults are values, never factories.
---@field validate? fun(value: T): boolean?, string? Runs after structural checks and defaults, on the input shape before destructuring. Return true to accept, or false/nil and an optional message to reject. Exceptions propagate.

---@class schema.StringProperties: schema.Properties<string>

---@class schema.String: schema.StringProperties
---@field type "string"

---@class schema.NumberProperties: schema.Properties<number>

---@class schema.Number: schema.NumberProperties
---@field type "number"

---@class schema.IntegerProperties: schema.Properties<integer>

---@class schema.Integer: schema.IntegerProperties
---@field type "integer"

---@class schema.BooleanProperties: schema.Properties<boolean>

---@class schema.Boolean: schema.BooleanProperties
---@field type "boolean"

---@class schema.NullProperties: schema.Properties<nil>

---@class schema.Null: schema.NullProperties
---@field type "nil"

---@class schema.AnyProperties: schema.Properties<any>

---@class schema.Any: schema.AnyProperties
---@field type "any"

---@class schema.FileProperties: schema.Properties<file*>

---@class schema.File: schema.FileProperties
---@field type "file"

---@class schema.LiteralProperties<T>: schema.Properties<T>
---@field value T Compared using Lua equality.

---@class schema.Literal<T>: schema.LiteralProperties<T>
---@field type "literal"

---@class schema.UnionProperties: schema.Properties<any>
---@field alternatives schema.Schema[] Nonempty; any matching branch accepts the value.

---@class schema.Union: schema.UnionProperties
---@field type "union"

---@class schema.OptionalProperties: schema.Properties<any>
---@field schema schema.Schema Schema to union with nil.

---@class schema.EnumProperties: schema.Properties<any>
---@field values any[] Nonempty list of non-nil literal values.

---@class schema.ArrayProperties: schema.Properties<table>
---@field items schema.Schema Schema for each array entry; conformance binds repeated entries to "items".

---@class schema.TableProperties: schema.Properties<table>
---@field fields schema.Fields Named fields and positional entries. Undeclared fields are rejected.
---@field extends? schema.Reference Parent table definition. Named fields merge, with child overrides; a child positional sequence replaces the whole inherited sequence. Inherited references retain the parent's registry scope. Both tables' predicates run after combined defaults.

---@class schema.Table: schema.TableProperties
---@field type "table"

---@class schema.MapProperties: schema.Properties<table>
---@field key schema.Schema Schema for every key; conformance preserves key identity.
---@field value schema.Schema Schema for every value.

---@class schema.Map: schema.MapProperties
---@field type "map"

---@alias schema.Arity "1"|"?"|"*"|"+"

---@class schema.Entry
---@field [1] string Argument name used in errors and documentation.
---@field [2] schema.Schema Schema for each supplied value.
---@field arity? schema.Arity Defaults to 1. Only the final entry may use ?, *, or +. Omission differs from a supplied nil.

---@class schema.Fields
---@field [integer] schema.Entry Ordered positional entries; use table.pack inputs to distinguish omission from nil. An omitted ? entry may use its default; required entries must be supplied.
---@field [string] schema.Schema Named field schemas. Missing fields use their defaults, otherwise they are checked as nil. A declared n field is ordinary data, not packed sequence metadata.

---@class schema.Branch
---@field [1] string Unique branch name used in errors and conformed matches.
---@field [2] schema.TableSchema Branch schema.

---@class schema.AlternativeProperties: schema.Properties<table>
---@field alternatives schema.Branch[] Nonempty ordered branches; the first match conforms to {tag = name, value = branch_output}.

---@class schema.Alternative: schema.AlternativeProperties
---@field type "alt"

---@alias schema.TableSchema schema.Table|schema.Alternative|schema.Reference|schema.Registry

---@class schema.Signature
---@field params schema.TableSchema Argument table, normally with positional entries.
---@field returns schema.TableSchema Return-value table; no positional entries means no return values.

---@class schema.FunctionProperties: schema.Properties<function>
---@field signatures schema.Signature[] Nonempty overload list.
---@field name? string Function name used in call validation/conformance errors, such as "fetch" or "fs.stat". Defaults to the path selected by at, then the enclosing reference name.

---@class schema.Function: schema.FunctionProperties
---@field type "function"
-- Checking a function value does not invoke or wrap it.

---@class schema.ReferenceProperties: schema.Properties<any>
---@field name string Definition name resolved in the enclosing registry, then its parents. No global registry.

---@class schema.Reference: schema.ReferenceProperties
---@field type "ref"

---@class schema.RegistryProperties: schema.Properties<any>
---@field definitions table<string, schema.Schema> Named definitions scoped to this registry; references can express recursion without cyclic schema tables.
---@field schema schema.Schema Root schema checked within this registry.
---@field name? string Function path for call errors, supplied by at. An explicit function name takes precedence.

---@class schema.Registry: schema.RegistryProperties
---@field type "registry"

---@alias schema.Schema schema.String|schema.Number|schema.Integer|schema.Boolean|schema.Null|schema.Any|schema.File|schema.Literal<any>|schema.Union|schema.Table|schema.Map|schema.Alternative|schema.Function|schema.Reference|schema.Registry
---@alias schema.FunctionSchema schema.Function|schema.Reference|schema.Registry
---@alias schema.ErrorCode "type"|"required"|"sparse"|"unexpected"|"unknown_field"|"union"|"validation"

---@class schema.Error
---@field code schema.ErrorCode
---@field path any[] Field keys and positional indices from the validated root to the failing value.
---@field expected schema.Schema Schema that rejected the value.
---@field actual_type "nil"|"boolean"|"number"|"string"|"table"|"function"|"userdata"|"thread" Lua type of the failing value.
---@field type_kind? string Cached primitive expectation for deferred message formatting.
---@field literal_value? any Cached literal expectation for deferred message formatting.
---@field message string Human-readable explanation without the path prefix.
---@field position? integer Argument position, for sequence failures.
---@field argument? string Argument name, when declared by the sequence.
---@field part? "key" Marks a failure validating a map key rather than its value.
---@field branch? string Name of the failing alternative branch.
---@field function_name? string Function whose call arguments failed to match.

---@class schema.ValidationError
---@field message string Formatted validation explanation including the failing path.
---@field exit_code integer Always 1.

local S = {}

---@param kind string
---@param properties? table
---@return any
local function node(kind, properties)
    local schema = {}
    for key, value in pairs(properties or {}) do schema[key] = value end
    schema.type = kind
    return schema
end

---@param properties? schema.StringProperties
---@return schema.String
function S.string(properties) return node("string", properties) end

---@param properties? schema.NumberProperties
---@return schema.Number
function S.number(properties) return node("number", properties) end

---@param properties? schema.IntegerProperties
---@return schema.Integer
function S.integer(properties) return node("integer", properties) end

---@param properties? schema.BooleanProperties
---@return schema.Boolean
function S.boolean(properties) return node("boolean", properties) end

---@param properties? schema.NullProperties
---@return schema.Null
function S.null(properties) return node("nil", properties) end

---@param properties? schema.AnyProperties
---@return schema.Any
function S.any(properties) return node("any", properties) end

---An open Lua file handle. Closed files are rejected; conformance retains identity.
---@param properties? schema.FileProperties
---@return schema.File
function S.file(properties) return node("file", properties) end

---@generic T
---@param properties schema.LiteralProperties<T>
---@return schema.Literal<T>
function S.literal(properties) return node("literal", properties) end

---@param properties schema.UnionProperties
---@return schema.Union
function S.union(properties) return node("union", properties) end

---A nullable schema, expressed as a union with nil.
---@param properties schema.OptionalProperties
---@return schema.Union
function S.optional(properties)
    local schema = node("union", properties)
    schema.alternatives = { properties.schema, S.null() }
    schema.schema = nil
    return schema
end

---A union of literal values.
---@param properties schema.EnumProperties
---@return schema.Union
function S.enum(properties)
    local schema = node("union", properties)
    schema.alternatives = {}
    for i, value in ipairs(properties.values) do schema.alternatives[i] = S.literal { value = value } end
    schema.values = nil
    return schema
end

---@param properties schema.TableProperties
---@return schema.Table
function S.table(properties) return node("table", properties) end

---An array of values; conformance binds the repeated entries to "items".
---@param properties schema.ArrayProperties
---@return schema.Table
function S.array(properties)
    local schema = node("table", properties)
    schema.fields = { { "items", properties.items, arity = "*" } }
    schema.items = nil
    return schema
end

---@param properties schema.MapProperties
---@return schema.Map
function S.map(properties) return node("map", properties) end

---@param properties schema.AlternativeProperties
---@return schema.Alternative
function S.alt(properties) return node("alt", properties) end

---@param properties schema.FunctionProperties
---@return schema.Function
function S.func(properties) return node("function", properties) end

---@param properties schema.ReferenceProperties
---@return schema.Reference
function S.ref(properties) return node("ref", properties) end

---@param properties schema.RegistryProperties
---@return schema.Registry
function S.registry(properties) return node("registry", properties) end

local function child_path(path, key)
    local result = {}
    for i, part in ipairs(path) do result[i] = part end
    result[#result + 1] = key
    return result
end

local function keys(value)
    local result = {}
    for key in pairs(value) do result[#result + 1] = key end
    table.sort(result, function(a, b)
        local ta, tb = type(a), type(b)
        if ta ~= tb then return ta < tb end
        if ta == "string" or ta == "number" then return a < b end
        return tostring(a) < tostring(b)
    end)
    return result
end

local function named_keys(fields)
    if getmetatable(fields) ~= nil then return keys(fields) end
    local result = {}
    for key in pairs(fields) do
        if type(key) == "string" then result[#result + 1] = key end
    end
    table.sort(result)
    return result
end

local function describe(schema)
    if schema.type == "file" then return "open file handle" end
    if schema.type == "ref" then return schema.name end
    if schema.type == "literal" then
        return type(schema.value) == "string" and string.format("%q", schema.value) or tostring(schema.value)
    end
    if schema.type == "union" then
        local names = {}
        for i, alternative in ipairs(schema.alternatives) do names[i] = describe(alternative) end
        return table.concat(names, " or ")
    end
    if schema.type == "alt" then return "alternative table" end
    return schema.type
end

local function failure(code, schema, value, path, message)
    -- Successful checks share a path stack; failures retain their own snapshot.
    return nil, { code = code, path = table.move(path, 1, #path, 1, {}), expected = schema,
        actual_type = type(value), message = message }
end

local function type_failure(schema, value, path)
    -- Keep observable formatting hooks eager, even for discarded branches.
    if getmetatable(schema) ~= nil then
        return failure("type", schema, value, path,
            "expected " .. describe(schema) .. ", got " .. type(value))
    end
    local kind = schema.type
    local literal_kind = kind == "literal" and type(schema.value) or nil
    if kind == "literal" and literal_kind ~= "string" and literal_kind ~= "number"
        and literal_kind ~= "boolean" and literal_kind ~= "nil" then
        return failure("type", schema, value, path,
            "expected " .. describe(schema) .. ", got " .. type(value))
    end
    local _, err = failure("type", schema, value, path, nil)
    -- Schemas may change before a later branch fails; retain the original label.
    err.type_kind = kind
    if kind == "literal" then err.literal_value = schema.value end
    return nil, err
end

local function required(err)
    err.code = "required"
    err.message = "required value is missing (expected " .. describe(err.expected) .. ")"
end

local function resolve(schema, scope)
    while scope do
        local definition = scope.definitions[schema.name]
        if definition then return definition, scope end
        scope = scope.parent
    end
    error("undefined schema reference: " .. schema.name)
end

local function unwrap(schema, scope)
    local name
    while schema.type == "registry" or schema.type == "ref" do
        if schema.type == "registry" then
            name = name or schema.name
            scope = { definitions = schema.definitions, parent = scope }
            schema = schema.schema
        else
            name = name or schema.name
            schema, scope = resolve(schema, scope)
        end
    end
    return schema, scope, name
end

-- Inheritance combines declarations, rather than validating two closed tables.
-- Field owners keep inherited references in their original lexical registry.
local function table_fields(schema, scope)
    if not schema.extends then return schema.fields, nil, scope end
    local parent, owner = unwrap(schema.extends, scope)
    local inherited, owners, sequence_scope, predicates = table_fields(parent, owner)
    local fields, scopes = {}, {}
    for key, field in pairs(inherited) do
        fields[key] = field
        if owners then scopes[key] = owners[key] else scopes[key] = owner or false end
    end
    if #schema.fields > 0 then
        for i = 1, #fields do fields[i] = nil end
        sequence_scope = scope
    end
    for key, field in pairs(schema.fields) do
        fields[key], scopes[key] = field, scope or false
    end
    if parent.validate then
        predicates = predicates or {}
        predicates[#predicates + 1] = parent
    end
    return fields, scopes, sequence_scope, predicates
end

---Selects declared table fields without validating values. Preserves lexical
---registry scope and leaf properties; ancestor validation/defaults do not apply.
---The selected path names call errors unless the function has an explicit name.
---An empty path selects the root. Definitions and inputs are untouched.
---@param schema schema.Schema
---@param path (string|integer)[] Ordered declared field keys or positional entry indices, such as {"fs", "stat"}.
---@return schema.Registry selected A schema with registry wrappers; usable with validate, conform, and, for functions, their call variants.
function S.at(schema, path)
    local name = schema.type == "registry" and schema.name or nil
    local scope
    for _, key in ipairs(path) do
        schema, scope = unwrap(schema, scope)
        local fields, owners, sequence_scope = table_fields(schema, scope)
        schema = fields[key]
        if type(key) == "number" then
            schema, scope = schema[2], sequence_scope
        elseif owners then
            scope = owners[key] or nil
        end
        if type(key) == "string" and key:match("^[%a_][%w_]*$") then
            name = name and (name .. "." .. key) or key
        else
            name = (name or "") .. "[" .. (type(key) == "string" and string.format("%q", key) or tostring(key)) .. "]"
        end
    end
    local selected = schema
    while scope do
        selected = S.registry { definitions = scope.definitions, schema = selected }
        scope = scope.parent
    end
    if selected == schema then selected = S.registry { definitions = {}, schema = selected } end
    selected.name = name
    return selected
end

-- Present the furthest/deepest failure when no alternative matches.
local function best_failure(best, candidate)
    if not best then return candidate end
    local position, best_position = candidate.position or 0, best.position or 0
    if position > best_position or (position == best_position and (#candidate.path > #best.path
        or (#candidate.path == #best.path and candidate.code == "validation" and best.code ~= "validation"))) then
        return candidate
    end
    return best
end

local function copy_table(value)
    local result = {}
    for key, item in pairs(value) do result[key] = item end
    return result
end

-- Absence is handled by the containing table/optional argument, not by value
-- schemas. In particular a supplied nil never triggers a default or coercion.
local function default_value(schema, scope)
    while true do
        if schema.default ~= nil then return schema.default end
        if schema.type == "registry" then
            scope = { definitions = schema.definitions, parent = scope }
            schema = schema.schema
        elseif schema.type == "ref" then
            schema, scope = resolve(schema, scope)
        else
            return nil
        end
    end
end

local check

local function check_child(schema, value, path, key, scope, conforming)
    path[#path + 1] = key
    local ok, output, normalized = check(schema, value, path, scope, conforming)
    path[#path] = nil
    return ok, output, normalized
end

-- Successful matches carry output and the defaults-filled original shape for
-- parent predicates. Failure is nil and an Error.
local function positional_key(key)
    return type(key) == "number" and math.tointeger(key) and key >= 1
end

local packed_length = S.integer {
    validate = function(value) return value >= 0, "packed sequence length must be nonnegative" end,
}

local function check_sequence(schema, fields, value, path, scope, conforming)
    local packed = fields.n == nil and value.n ~= nil
    local count = 0
    if packed then
        local ok, err = check_child(packed_length, value.n, path, "n", scope, false)
        if not ok then return nil, err end
        count = value.n
    end
    local extra_index
    for key in pairs(value) do
        if positional_key(key) then
            if packed and key > count then
                if not extra_index or key < extra_index then extra_index = key end
            elseif not packed and key > count then
                count = key
            end
        end
    end
    if extra_index then
        local _, err = failure("unexpected", schema, value[extra_index], child_path(path, extra_index),
            "positional argument exceeds packed sequence length")
        err.position = extra_index
        return nil, err
    end
    local index = 1
    local normalized = value
    local output = conforming and {} or nil
    for _, entry in ipairs(fields) do
        local name, item_schema = entry[1], entry[2]
        local arity, remaining = entry.arity or "1", count - index + 1
        local repeated = arity == "*" or arity == "+"
        local consume = 1
        if arity == "?" then consume = math.min(1, remaining)
        elseif repeated then consume = remaining end
        if (arity == "1" and remaining == 0) or (arity == "+" and consume == 0) then
            local _, err = failure("required", item_schema, nil, child_path(path, index),
                "missing required argument: " .. name)
            err.position, err.argument = index, name
            return nil, err
        end
        local items
        if repeated and conforming then
            items = { n = consume }
            output[name] = items
        end
        if arity == "?" and consume == 0 then
            local item = default_value(item_schema, scope)
            if item ~= nil then
                local ok, result, original = check_child(item_schema, item, path, index, scope, conforming)
                if not ok then result.position, result.argument = index, name; return nil, result end
                if conforming then output[name] = result end
                if normalized == value then normalized = copy_table(value) end
                normalized[index] = original
                if packed then normalized.n = index end
            end
        end
        for item_index = 1, consume do
            if value[index] == nil and not packed then
                local _, err = failure("sparse", item_schema, nil, child_path(path, index),
                    "positional entries must form a dense sequence")
                err.position, err.argument = index, name
                return nil, err
            end
            local ok, result, original = check_child(item_schema, value[index], path, index, scope, conforming)
            if not ok then result.position, result.argument = index, name; return nil, result end
            if original ~= value[index] then
                if normalized == value then normalized = copy_table(value) end
                normalized[index] = original
            end
            if conforming then
                if repeated then
                    items[item_index] = result
                else
                    output[name] = result
                end
            end
            index = index + 1
        end
    end
    if index <= count then
        local _, err = failure("unexpected", schema, value[index], child_path(path, index),
            "unexpected positional argument")
        err.position = index
        return nil, err
    end
    if conforming then return true, output, normalized end
    return true, normalized, normalized
end

local function check_table(schema, value, path, scope, conforming)
    if type(value) ~= "table" then return type_failure(schema, value, path) end
    local fields, owners, sequence_scope, predicates = table_fields(schema, scope)
    local packed = fields.n == nil and value.n ~= nil
    local ok, output, normalized = check_sequence(schema, fields, value, path, sequence_scope, conforming)
    if not ok then return nil, output end
    for _, key in ipairs(named_keys(fields)) do
        if type(key) == "string" then
            local owner = scope
            if owners then owner = owners[key] or nil end
            local item_schema, item = fields[key], value[key]
            if item == nil then item = default_value(item_schema, owner) end
            local valid, result, original = check_child(item_schema, item, path, key, owner, conforming)
            if not valid then
                if item == nil then required(result) end
                return nil, result
            end
            if original ~= value[key] then
                if normalized == value then normalized = copy_table(value) end
                normalized[key] = original
            end
            if conforming then output[key] = result end
        end
    end
    local has_unknown = getmetatable(value) ~= nil or getmetatable(fields) ~= nil
    if not has_unknown then
        for key in pairs(value) do
            if not positional_key(key) and not (packed and key == "n")
                and (type(key) ~= "string" or fields[key] == nil) then
                has_unknown = true
                break
            end
        end
    end
    -- Sorting is only needed to select an error; metatables keep their traversal.
    if has_unknown then
        for _, key in ipairs(keys(value)) do
            if not positional_key(key) and not (packed and key == "n")
                and (type(key) ~= "string" or fields[key] == nil) then
                return failure("unknown_field", schema, value[key], child_path(path, key), "unknown field")
            end
        end
    end
    if predicates then
        for _, parent in ipairs(predicates) do
            local valid, message = parent.validate(normalized)
            if not valid then
                return failure("validation", parent, normalized, path,
                    message or parent.description or "custom validation failed")
            end
        end
    end
    if conforming then return true, output, normalized end
    return true, normalized, normalized
end

local function check_map(schema, value, path, scope, conforming)
    if type(value) ~= "table" then return type_failure(schema, value, path) end
    local normalized = value
    local output = conforming and {} or nil
    for _, key in ipairs(keys(value)) do
        path[#path + 1] = key
        local ok, err = check(schema.key, key, path, scope, false)
        if not ok then path[#path] = nil; err.part = "key"; return nil, err end
        local valid, result, original = check(schema.value, value[key], path, scope, conforming)
        path[#path] = nil
        if not valid then return nil, result end
        if original ~= value[key] then
            if normalized == value then normalized = copy_table(value) end
            normalized[key] = original
        end
        if conforming then output[key] = result end
    end
    if conforming then return true, output, normalized end
    return true, normalized, normalized
end

check = function(schema, value, path, scope, conforming)
    local kind = schema.type
    local ok, output, normalized
    if kind == "registry" then
        ok, output, normalized = check(schema.schema, value, path, { definitions = schema.definitions, parent = scope }, conforming)
    elseif kind == "ref" then
        local definition, owner = resolve(schema, scope)
        ok, output, normalized = check(definition, value, path, owner, conforming)
    elseif kind == "union" or kind == "alt" then
        local best
        for _, alternative in ipairs(schema.alternatives) do
            local branch = kind == "alt" and alternative[2] or alternative
            ok, output, normalized = check(branch, value, path, scope, conforming)
            if ok then
                if kind == "alt" and conforming then
                    output = { tag = alternative[1], value = output }
                end
                break
            end
            if kind == "alt" then output.branch = alternative[1] end
            best = best_failure(best, output)
        end
        if not ok then
            local err = best
            if kind == "union" and #err.path == #path and err.code ~= "validation" then
                err.code, err.expected = "union", schema
                err.message = "expected " .. describe(schema) .. ", got " .. type(value)
            end
            return nil, err
        end
    elseif kind == "table" then
        ok, output, normalized = check_table(schema, value, path, scope, conforming)
    elseif kind == "map" then
        ok, output, normalized = check_map(schema, value, path, scope, conforming)
    else
        if kind == "any" then ok = true
        elseif kind == "literal" then ok = value == schema.value
        elseif kind == "integer" then ok = type(value) == "number" and math.tointeger(value) ~= nil
        elseif kind == "file" then ok = io.type(value) == "file"
        else ok = type(value) == kind end
        if not ok then return type_failure(schema, value, path) end
        output, normalized = value, value
    end
    if not ok then return nil, output end
    if schema.validate then
        local valid, message = schema.validate(normalized)
        if not valid then
            return failure("validation", schema, normalized, path,
                message or schema.description or "custom validation failed")
        end
    end
    return true, output, normalized
end

---@param err schema.Error
---@return string
local function format_error(err)
    if err.code == "type" and err.message == nil then
        local expected = err.type_kind
        if expected == "file" then expected = "open file handle" end
        if expected == "literal" then
            expected = type(err.literal_value) == "string" and string.format("%q", err.literal_value) or tostring(err.literal_value)
        end
        err.message = "expected " .. expected .. ", got " .. err.actual_type
    end
    if err.function_name then
        local path = err.argument or ""
        local first = err.position and 2 or 1
        for i = first, #err.path do
            local key = err.path[i]
            if type(key) == "string" and key:match("^[%a_][%w_]*$") then
                path = path == "" and key or path .. "." .. key
            else
                path = path .. "[" .. (type(key) == "string" and string.format("%q", key) or tostring(key)) .. "]"
            end
        end
        local label
        if #err.path >= first then label = "field " .. string.format("%q", path)
        elseif err.argument then label = "argument " .. string.format("%q", path)
        elseif err.position then label = "argument #" .. err.position
        else label = "arguments" end
        if err.part == "key" then label = "key of " .. label end
        local message
        if err.code == "type" or err.code == "union" then
            local expected = describe(err.expected)
            local kind = err.expected.type
            if kind == "integer" or kind == "alt" or kind == "file" then expected = "an " .. expected
            elseif kind ~= "nil" and kind ~= "literal" and kind ~= "union" then expected = "a " .. expected end
            message = label .. " must be " .. expected .. ", got " .. err.actual_type
        elseif err.code == "required" then message = label .. " is required"
        elseif err.code == "unexpected" then message = "unexpected " .. label
        elseif err.code == "unknown_field" then message = "unknown " .. label
        elseif err.code == "sparse" then message = label .. " is missing; " .. err.message
        else message = label .. " failed validation (" .. err.message .. ")" end
        if err.branch then message = message .. " (branch " .. err.branch .. ")" end
        return err.function_name .. ": " .. message
    end
    local label = "value"
    for i = 1, #err.path do
        local key = err.path[i]
        if type(key) == "string" and key:match("^[%a_][%w_]*$") then label = label .. "." .. key
        else label = label .. "[" .. (type(key) == "string" and string.format("%q", key) or tostring(key)) .. "]" end
    end
    if err.argument then label = label .. " (" .. err.argument .. ")" end
    if err.branch then label = label .. " (branch " .. err.branch .. ")" end
    if err.part == "key" then label = label .. " key" end
    return label .. ": " .. err.message
end

---@param err schema.Error
---@return schema.ValidationError
local function validation_error(err)
    return { message = format_error(err), exit_code = 1 }
end

---Returns the original value on success; throws schema.ValidationError on invalid input.
---Defaults participate in checking but are never inserted into the caller's input.
---@generic T
---@param schema schema.Schema
---@param value T
---@return T
function S.validate(schema, value)
    local ok, result = check(schema, value, {}, nil, false)
    if not ok then
        ---@cast result schema.Error
        error(validation_error(result), 0)
    end
    return value
end

---Returns the conformed value; throws on invalid input.
---Primitives, files and functions retain their value. Tables receive defaults and named
---positional bindings; alternatives become {tag, value}. No type coercion.
---@param schema schema.Schema
---@param value any
---@return any output
function S.conform(schema, value)
    local ok, output = check(schema, value, {}, nil, true)
    if not ok then
        ---@cast output schema.Error
        error(validation_error(output), 0)
    end
    return output
end

local function check_call(schema, arguments, conforming)
    local scope, name
    schema, scope, name = unwrap(schema, nil)
    local best
    for _, signature in ipairs(schema.signatures) do
        local ok, output = check(signature.params, arguments, {}, scope, conforming)
        if ok then return signature, output end
        best = best_failure(best, output)
    end
    local err = best
    err.function_name = schema.name or name
    return nil, err
end

---Returns the matching signature; throws if none matches. Never invokes the function.
---@param schema schema.FunctionSchema
---@param ... any Arguments, including explicit nil positions.
---@return schema.Signature
function S.validate_call(schema, ...)
    local signature, result = check_call(schema, table.pack(...), false)
    if not signature then
        ---@cast result schema.Error
        error(validation_error(result), 0)
    end
    return signature
end

---Returns structured arguments for the first matching signature. Throws if none
---matches, identifying the function when named. Never invokes or wraps the function.
---@param schema schema.FunctionSchema
---@param ... any Arguments, including explicit nil positions.
---@return table arguments Named bindings or a tagged alternative match.
function S.conform_call(schema, ...)
    local signature, output = check_call(schema, table.pack(...), true)
    if not signature then
        ---@cast output schema.Error
        error(validation_error(output), 0)
    end
    ---@cast output table
    return output
end

return S
