---@type dotcmd.Env|_G
local _ENV = _ENV
local commands = require('dotcmd.commands')
local format = require('dotcmd.format')
local output = format.writer(io.stdout)

local function keyword(value)
    return { bold = true, value }
end

local function print_section(title, rows)
    if #rows == 0 then return end
    local width = 0
    for _, row in ipairs(rows) do width = math.max(width, #format.plain(row[1])) end
    output:write({ '\n', keyword(title .. ':'), '\n' })
    local indent = string.rep(' ', width + 4)
    for _, row in ipairs(rows) do
        local label = format.plain(row[1])
        local description = row[2] or ''
        local metadata = row[3]
        local separator = description == '' and metadata == nil and '' or string.rep(' ', width - #label + 2)
        output:write({ '  ', row[1], separator, description:gsub('\n', '\n' .. indent),
            metadata and description ~= '' and ' ' or '',
            metadata and { dim = true, '(' .. metadata .. ')' } or '', '\n' })
    end
end

local function value_type(spec)
    if spec.parse then return 'value' end
    return type(spec.type) == 'table' and table.concat(spec.type, '|') or (spec.type or 'string')
end

local function default_value(value)
    local kind = type(value)
    if kind == 'string' then return value == '' and '""' or value end
    if kind == 'number' or kind == 'boolean' then return tostring(value) end
    return '<' .. kind .. '>'
end

local function description(spec, positional)
    local notes = {}
    if positional and (spec.type or spec.parse) then notes[#notes + 1] = value_type(spec) end
    if not positional and (spec.arity == '1' or spec.arity == '+') then notes[#notes + 1] = 'required' end
    if not positional and (spec.arity == '*' or spec.arity == '+') then notes[#notes + 1] = 'repeatable' end
    if spec.default ~= nil then
        local default
        if spec.arity == '*' or spec.arity == '+' then
            local values = {}
            for _, value in ipairs(spec.default) do values[#values + 1] = default_value(value) end
            default = '[' .. table.concat(values, ', ') .. ']'
        else
            default = default_value(spec.default)
        end
        notes[#notes + 1] = 'default: ' .. default
    end
    return spec.description or '', #notes > 0 and table.concat(notes, '; ') or nil
end

local function print_options(opts)
    local names, rows = {}, {}
    for key, spec in pairs(opts or {}) do
        if not spec.hidden then names[#names + 1] = key end
    end
    table.sort(names)
    for _, key in ipairs(names) do
        local spec = opts[key]
        local aliases = {}
        for short in (spec.short or ''):gmatch('.') do aliases[#aliases + 1] = '-' .. short end
        aliases[#aliases + 1] = '--' .. key:gsub('_', '-')
        local label = {}
        for index, alias in ipairs(aliases) do
            if index > 1 then label[#label + 1] = ', ' end
            label[#label + 1] = keyword(alias)
        end
        if not spec.flag then
            label[#label + 1] = ' <'
            label[#label + 1] = keyword(value_type(spec))
            label[#label + 1] = '>'
        end
        local text, metadata = description(spec, false)
        rows[#rows + 1] = { label, text, metadata }
    end
    print_section('Options', rows)
end

local function usage(name, command, opts)
    local result = { keyword(name) }
    for _, spec in pairs(opts or command.opts or {}) do
        if not spec.hidden then
            result[#result + 1] = ' ['
            result[#result + 1] = keyword('options')
            result[#result + 1] = ']'
            break
        end
    end
    if command.commands then
        result[#result + 1] = command.run and ' [' or ' <'
        result[#result + 1] = keyword('command')
        result[#result + 1] = command.run and ']' or '>'
        return result
    end
    if command.args == nil then
        result[#result + 1] = ' ['
        result[#result + 1] = keyword('args')
        result[#result + 1] = '...]'
        return result
    end
    for _, spec in ipairs(command.args) do
        local arity = spec.arity or '1'
        result[#result + 1] = (arity == '?' or arity == '*') and ' [' or ' <'
        result[#result + 1] = keyword(spec[1])
        if arity == '*' or arity == '+' then result[#result + 1] = '...' end
        result[#result + 1] = (arity == '?' or arity == '*') and ']' or '>'
    end
    return result
end

return function(all_commands, main_command, ...)
    local path = { ... }
    if #path == 0 then
        output:write({ keyword('Usage:'), ' .cmd <command> [args...]\n' })
        local names, rows, builtin_rows = {}, {}, {}
        for key, command in pairs(all_commands) do
            if type(command) ~= 'string' and not command.hidden then names[#names + 1] = key end
        end
        table.sort(names)
        for _, key in ipairs(names) do
            local entry = all_commands[key]
            local description = entry.description
            local label = usage(key, entry)
            local builtin = key:sub(1, 2) == '--'
            for _, alias in ipairs(entry.aliases or {}) do
                label[#label + 1] = ', '
                label[#label + 1] = keyword(alias)
            end
            local section = builtin and builtin_rows or rows
            section[#section + 1] = { label, description and description:match('^[^\r\n]*') }
        end
        print_section('Project commands', rows)
        print_section('Built-in commands', builtin_rows)
        print_options(main_command.opts)
        output:flush()
        return
    end
    local command, inherited_opts = commands.find(all_commands, path)
    if command == nil then
        io.stderr:write('dotcmd: unknown command: ' .. table.concat(path, ' ') .. '\nRun .cmd --help to list available commands.\n')
        return 1
    end
    output:write({ keyword('Usage:'), ' .cmd ', format.plain(usage(table.concat(path, ' '), command, inherited_opts)), '\n' })
    local rows = {}
    for _, spec in ipairs(command.args or {}) do
        local text, metadata = description(spec, true)
        rows[#rows + 1] = { keyword(spec[1]), text, metadata }
    end
    if command.description then output:write({ '\n', command.description:gsub('%s+$', ''), '\n' }) end
    print_section('Arguments', rows)
    if command.commands then
        local children, child_rows = {}, {}
        for name, child in pairs(command.commands) do
            if type(child) ~= 'string' and not child.hidden then children[#children + 1] = name end
        end
        table.sort(children)
        for _, name in ipairs(children) do
            local child = command.commands[name]
            local label = usage(name, child)
            for _, alias in ipairs(child.aliases or {}) do
                label[#label + 1] = ', '
                label[#label + 1] = keyword(alias)
            end
            child_rows[#child_rows + 1] = { label, child.description and child.description:match('^[^\r\n]*') }
        end
        print_section('Commands', child_rows)
    end
    print_options(inherited_opts)
    output:flush()
end
