---@type dotcmd.Env|_G
local _ENV = _ENV

local function print_section(title, rows)
    if #rows == 0 then return end
    local width = 0
    for _, row in ipairs(rows) do width = math.max(width, #row[1]) end
    print('\n' .. title .. ':')
    local indent = string.rep(' ', width + 4)
    for _, row in ipairs(rows) do
        local description = row[2] or ''
        print('  ' .. row[1] .. (description == '' and '' or
            (string.rep(' ', width - #row[1] + 2) .. description:gsub('\n', '\n' .. indent))))
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
    local description = spec.description or ''
    if #notes > 0 then
        description = description .. (description == '' and '' or ' ') .. '(' .. table.concat(notes, '; ') .. ')'
    end
    return description
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
        local label = table.concat(aliases, ', ')
        if not spec.flag then label = label .. ' <' .. value_type(spec) .. '>' end
        rows[#rows + 1] = { label, description(spec, false) }
    end
    print_section('Options', rows)
end

local function usage(name, command)
    local usage = name
    for _, spec in pairs(command.opts or {}) do
        if not spec.hidden then
            usage = usage .. ' [options]'
            break
        end
    end
    if command.args == nil then return usage .. ' [args...]' end
    for _, spec in ipairs(command.args) do
        local arity = spec.arity or '1'
        local label = spec[1] .. ((arity == '*' or arity == '+') and '...' or '')
        if arity == '?' or arity == '*' then label = '[' .. label .. ']'
        else label = '<' .. label .. '>' end
        usage = usage .. ' ' .. label
    end
    return usage
end

return function(commands, main_command, name)
    if name == nil then
        print('Usage: .cmd <command> [args...]')
        local names, rows, builtin_rows = {}, {}, {}
        for key, command in pairs(commands) do
            if type(command) ~= 'string' and not command.hidden then names[#names + 1] = key end
        end
        table.sort(names)
        for _, key in ipairs(names) do
            local entry = commands[key]
            local description = entry.description
            local label = usage(key, entry)
            local builtin = key:sub(1, 2) == '--'
            for _, alias in ipairs(entry.aliases or {}) do label = label .. ', ' .. alias end
            local section = builtin and builtin_rows or rows
            section[#section + 1] = { label, description and description:match('^[^\r\n]*') }
        end
        print_section('Project commands', rows)
        print_section('Built-in commands', builtin_rows)
        print_options(main_command.opts)
        return
    end
    local command = commands[name]
    if type(command) == 'string' then command = commands[command] end
    if command == nil then
        io.stderr:write('dotcmd: unknown command: ' .. name .. '\nRun .cmd --help to list available commands.\n')
        return 1
    end
    print('Usage: .cmd ' .. usage(name, command))
    local rows = {}
    for _, spec in ipairs(command.args or {}) do
        rows[#rows + 1] = { spec[1], description(spec, true) }
    end
    if command.description then print('\n' .. command.description:gsub('%s+$', '')) end
    print_section('Arguments', rows)
    print_options(command.opts)
end
