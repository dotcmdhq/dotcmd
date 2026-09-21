---@type dotcmd.Env|_G
local _ENV = _ENV

local args = {}

local function many(spec)
    return spec.arity == '*' or spec.arity == '+'
end

local function option_like(text)
    return #text > 1 and text:sub(1, 1) == '-' and tonumber(text) == nil
end

-- Read token structure without conversion, defaults, or required-value checks.
-- pending is the key of an option awaiting a value; opts and positionals are raw.
function args.scan(command, argv)
    local spellings = {}
    for key, spec in pairs(command.opts or {}) do
        spellings['--' .. key:gsub('_', '-')] = key
        for short in (spec.short or ''):gmatch('.') do spellings['-' .. short] = key end
    end
    local opts, positionals = {}, {}
    local options, pending = command.opts ~= nil, nil
    local i = 1
    while i <= #argv do
        local text = argv[i]
        local spelling, attached = text:match('^([^=]+)=(.*)$')
        local key = spellings[spelling or text]
        if options and text == '--' then
            options = false
        elseif options and option_like(text) and (key or not (command.args and command.args.end_opts)) then
            local spec = key and command.opts[key]
            if not spec then return nil, 'unknown option: ' .. text end
            local label = '--' .. key:gsub('_', '-')
            if opts[key] ~= nil and not many(spec) then return nil, 'option ' .. label .. ' may only appear once' end
            local value = true
            if spec.flag then
                if attached ~= nil then return nil, 'option ' .. label .. ' does not take a value' end
            else
                local raw = attached
                if raw == nil then
                    i = i + 1
                    raw = argv[i]
                    if raw == nil then pending = key; break end
                    if option_like(raw) then return nil, 'option ' .. label .. ' requires a value' end
                end
                value = raw
            end
            if many(spec) then
                if opts[key] == nil then opts[key] = {} end
                opts[key][#opts[key] + 1] = value
            else
                opts[key] = value
            end
        else
            positionals[#positionals + 1] = text
            if command.args and command.args.end_opts then options = false end
        end
        i = i + 1
    end

    return { opts = opts, positionals = positionals, options = options, pending = pending, spellings = spellings }
end

local function convert(spec, text)
    if spec.parse then
        local value, message = spec.parse(text)
        if value == nil then return nil, message or 'invalid value' end
        return value
    end
    local kind = spec.type
    if kind == 'integer' or kind == 'number' then
        local value = tonumber(text)
        if value and kind == 'integer' then value = math.tointeger(value) end
        if value == nil or value ~= value or value == math.huge or value == -math.huge then
            return nil, 'expected ' .. (kind == 'integer' and 'an integer' or 'a finite number')
        end
        return value
    elseif kind == 'boolean' then
        if text == 'true' then return true end
        if text == 'false' then return false end
        return nil, 'expected true or false'
    elseif type(kind) == 'table' then
        for _, choice in ipairs(kind) do if text == choice then return text end end
        return nil, 'expected one of: ' .. table.concat(kind, ', ')
    end
    -- Strings and file/directory paths are unchanged. Paths need not exist.
    return text
end

-- Return packed run parameters or nil and a CLI error. Schemas are trusted.
function args.parse(command, argv)
    local state, message = args.scan(command, argv)
    if not state then return nil, message end
    if state.pending then
        return nil, 'option --' .. state.pending:gsub('_', '-') .. ' requires a value'
    end
    local opts, positionals = state.opts, state.positionals

    for key, raw in pairs(opts) do
        local spec = command.opts[key]
        if not spec.flag then
            if many(spec) then
                for i, text in ipairs(raw) do
                    local value, message = convert(spec, text)
                    if value == nil then return nil, '--' .. key:gsub('_', '-') .. ': ' .. tostring(message) end
                    raw[i] = value
                end
            else
                local value, message = convert(spec, raw)
                if value == nil then return nil, '--' .. key:gsub('_', '-') .. ': ' .. tostring(message) end
                opts[key] = value
            end
        end
    end

    for key, spec in pairs(command.opts or {}) do
        if opts[key] == nil then
            if spec.arity == '1' or spec.arity == '+' then
                return nil, 'missing required option: --' .. key:gsub('_', '-')
            end
            if spec.default ~= nil then
                opts[key] = spec.default
            elseif many(spec) then
                opts[key] = {}
            elseif spec.flag then
                opts[key] = false
            end
        end
    end

    local result = { n = 0 }
    local function append(value)
        result.n = result.n + 1
        result[result.n] = value
    end
    if command.opts ~= nil then append(opts) end
    if command.args ~= nil then
        local index = 1
        for _, spec in ipairs(command.args) do
            local count = many(spec) and (#positionals - index + 1) or (positionals[index] ~= nil and 1 or 0)
            if count == 0 then
                local arity = spec.arity or '1'
                if arity == '1' or arity == '+' then return nil, 'missing required argument: ' .. spec[1] end
                if many(spec) then
                    for _, value in ipairs(spec.default or {}) do append(value) end
                else
                    append(spec.default)
                end
            else
                for _ = 1, count do
                    local value, message = convert(spec, positionals[index])
                    if value == nil then return nil, spec[1] .. ': ' .. tostring(message) end
                    append(value)
                    index = index + 1
                end
            end
        end
        if index <= #positionals then return nil, 'unexpected positional argument: ' .. positionals[index] end
    else
        for _, value in ipairs(positionals) do append(value) end
    end
    return result
end

return args
