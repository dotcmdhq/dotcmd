local reserved = {
    ["and"] = true,
    ["break"] = true,
    ["do"] = true,
    ["else"] = true,
    ["elseif"] = true,
    ["end"] = true,
    ["false"] = true,
    ["for"] = true,
    ["function"] = true,
    ["goto"] = true,
    ["if"] = true,
    ["in"] = true,
    ["local"] = true,
    ["nil"] = true,
    ["not"] = true,
    ["or"] = true,
    ["repeat"] = true,
    ["return"] = true,
    ["then"] = true,
    ["true"] = true,
    ["until"] = true,
    ["while"] = true,
}

local string_style = { fg = "green" }
local scalar_style = { fg = "cyan" }
local punctuation_style = { dim = true }

local function quote(value)
    local escapes = {
        ["\a"] = "\\a",
        ["\b"] = "\\b",
        ["\t"] = "\\t",
        ["\n"] = "\\n",
        ["\v"] = "\\v",
        ["\f"] = "\\f",
        ["\r"] = "\\r",
        ["\""] = "\\\"",
        ["\\"] = "\\\\",
    }
    return "\"" .. value:gsub("[%c\"\\]", function(character)
        local escaped = escapes[character]
        if escaped then return escaped end
        return ("\\%03d"):format(character:byte())
    end) .. "\""
end

local function number(value)
    if value ~= value or value == math.huge or value == -math.huge then
        return "<" .. tostring(value) .. ">"
    end
    return tostring(value)
end

local key_rank = { string = 1, number = 2, boolean = 3, ["function"] = 4,
    userdata = 5, thread = 6, table = 7 }

local function entry_less(left, right)
    if left.group ~= right.group then return left.group < right.group end
    if left.rank ~= right.rank then return left.rank < right.rank end
    if left.rank == 3 then return left.key == false end
    if left.rank > 3 then return left.sort_key < right.sort_key end
    return left.key < right.key
end

local function entries(value)
    local result = {}
    local array_size = 0
    while rawget(value, array_size + 1) ~= nil do array_size = array_size + 1 end
    for index = 1, array_size do
        result[#result + 1] = {
            value = rawget(value, index),
        }
    end

    local named = {}
    local key, item = next(value)
    while key ~= nil do
        local kind = type(key)
        if not (kind == "number" and key >= 1 and key <= array_size and key % 1 == 0) then
            local entry = { key = key }
            if kind == "string" then
                if key:match("^[A-Za-z_][A-Za-z0-9_]*$") and not reserved[key] then
                    entry.key_markup = key
                else
                    entry.key_markup = { "[", { style = string_style, quote(key) }, "]" }
                end
            elseif kind == "number" then
                entry.key_markup = { "[", { style = scalar_style, number(key) }, "]" }
            elseif kind == "boolean" then
                entry.key_markup = { "[", { style = scalar_style, tostring(key) }, "]" }
            else
                entry.key_markup = { "[", { style = scalar_style, "<" .. tostring(key) .. ">" }, "]" }
            end
            entry.value = item
            entry.group = type(item) == "table" and 2 or 1
            entry.rank = key_rank[kind]
            entry.sort_key = key_rank[kind] > 3 and tostring(key) or nil
            named[#named + 1] = entry
        end
        key, item = next(value, key)
    end
    table.sort(named, entry_less)
    for index = 1, #named do result[#result + 1] = named[index] end
    return result
end

return function(value)
    local root_kind = type(value)
    if root_kind == "string" then return value end
    if root_kind == "number" then
        return { style = scalar_style, number(value) }
    end
    if root_kind == "boolean" or root_kind == "nil" then
        return { style = scalar_style, tostring(value) }
    end
    if root_kind ~= "table" then return tostring(value) end
    local metatable = debug.getmetatable(value)
    if type(metatable) == "table" and rawget(metatable, "__tostring") ~= nil then
        return tostring(value)
    end

    local output = {}
    local active = {}
    local stack = { { kind = "value", value = value, indent = 0 } }

    while #stack > 0 do
        local action = stack[#stack]
        stack[#stack] = nil
        if action.kind == "text" then
            output[#output + 1] = action.text
        elseif action.kind == "close" then
            active[action.value] = nil
            output[#output + 1] = "\n" .. string.rep("    ", action.indent) .. "}"
        else
            local kind = type(action.value)
            if kind == "string" then
                output[#output + 1] = { style = string_style, quote(action.value) }
            elseif kind == "number" then
                output[#output + 1] = { style = scalar_style, number(action.value) }
            elseif kind == "boolean" or kind == "nil" then
                output[#output + 1] = { style = scalar_style, tostring(action.value) }
            elseif kind ~= "table" then
                output[#output + 1] = { style = scalar_style, "<" .. tostring(action.value) .. ">" }
            else
                local previous = active[action.value]
                if previous then
                    output[#output + 1] = { style = scalar_style, "<" .. tostring(action.value) .. ">" }
                else
                    local items = entries(action.value)
                    if #items == 0 then
                        output[#output + 1] = "{}"
                    else
                        active[action.value] = true
                        output[#output + 1] = "{\n"
                        stack[#stack + 1] = {
                            kind = "close", value = action.value, indent = action.indent,
                        }
                        for index = #items, 1, -1 do
                            local item = items[index]
                            if index < #items then
                                stack[#stack + 1] = { kind = "text", text = "\n" }
                                stack[#stack + 1] = {
                                    kind = "text", text = { style = punctuation_style, "," },
                                }
                            end
                            stack[#stack + 1] = {
                                kind = "value", value = item.value, indent = action.indent + 1,
                            }
                            local prefix = string.rep("    ", action.indent + 1)
                            if item.key_markup then
                                stack[#stack + 1] = {
                                    kind = "text", text = { style = punctuation_style, "= " },
                                }
                                stack[#stack + 1] = { kind = "text", text = " " }
                                stack[#stack + 1] = { kind = "text", text = item.key_markup }
                            end
                            stack[#stack + 1] = { kind = "text", text = prefix }
                        end
                    end
                end
            end
        end
    end
    return output
end
