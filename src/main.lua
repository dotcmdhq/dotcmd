---@type dotcmd.Env|_G
local _ENV = _ENV

-- Projects return {name = function(...) ... end} or
-- {name = {description = "...", run = function(...) ... end}} from .cmd.lua.
-- host is global; optional opts/args schemas prepare the arguments to run.
local function cache_dir()
    local function env(name)
        local value = os.getenv(name)
        return value ~= '' and value or nil
    end
    local override = env('DOTCMD_CACHE_DIR')
    if override then
        local absolute = host.os == 'windows'
            and (override:match('^%a:[/\\]') or override:match('^[/\\][/\\]'))
            or (host.os ~= 'windows' and override:sub(1, 1) == '/')
        assert(absolute, 'DOTCMD_CACHE_DIR must be an absolute path')
        return override
    end
    if host.os == 'windows' then
        local base = env('LOCALAPPDATA')
        if not base then
            base = assert(env('USERPROFILE'), 'neither LOCALAPPDATA nor USERPROFILE is set') .. '/AppData/Local'
        end
        return base .. '/dotcmd/Cache'
    end
    if host.os == 'linux' then
        local xdg = env('XDG_CACHE_HOME')
        if xdg and xdg:sub(1, 1) == '/' then return xdg .. '/dotcmd' end
    end
    return assert(env('HOME'), 'HOME is not set')
        .. (host.os == 'macos' and '/Library/Caches/dotcmd' or '/.cache/dotcmd')
end
host.cache_dir = cache_dir()

-- Completed entries are trusted; only fresh downloads are verified.
function cached(options)
    local hash = options.sha256
    local prepare = options.prepare
    local name = options.name
    if not name then
        local url_path = options.url:match("^[^:]+://[^/?#]+([^?#]*)")
        name = url_path:match("([^/]+)$") or "download"
        name = name:gsub("%%(%x%x)", function(hex)
            return string.char(tonumber(hex, 16))
        end)
    end

    local download_dir = host.cache_dir .. "/downloads/" .. hash
    local download_path = download_dir .. "/" .. name
    local prepared_dir
    if prepare ~= nil then
        local ok, bytecode = pcall(string.dump, prepare, true)
        assert(ok, "cached: prepare must be a Lua function")
        -- Captured values and ambient state are the caller's responsibility.
        prepared_dir = host.cache_dir .. "/prepared/" .. sha256(hash .. "\0" .. name
            .. "\0" .. host.os .. "\0" .. host.arch .. "\0" .. bytecode)
    end
    local result_path = prepared_dir and (prepared_dir .. "/" .. name) or download_path
    if fs.stat(result_path) then
        return result_path
    end

    if not fs.stat(download_path) then
        fs.mkdir(download_dir)
        local temp = download_dir .. "/.tmp-" .. ("%016x%016x"):format(math.random(0), math.random(0))
        local cleanup <close> = setmetatable({}, {
            __close = function()
                fs.remove(temp)
            end,
        })
        http { url = options.url, path = temp, check = true }
        assert(sha256 { path = temp } == hash, "cached: SHA-256 mismatch")
        fs.rename(temp, download_path, { if_exists = "skip" })
    end

    if prepare then
        fs.mkdir(host.cache_dir .. "/prepared")
        local temp = host.cache_dir .. "/prepared/.tmp-" .. ("%016x%016x"):format(math.random(0), math.random(0))
        fs.mkdir(temp)
        local cleanup <close> = setmetatable({}, {
            __close = function()
                fs.remove(temp, { recursive = true })
            end,
        })
        local output = temp .. "/" .. name
        prepare(download_path, output)
        local stat = fs.stat(output, { follow = false })
        assert(stat and (stat.type == "file" or stat.type == "directory"),
            "cached: prepare must create the output file or directory")
        -- Publish the whole entry atomically; a concurrent winner is reused.
        fs.rename(temp, prepared_dir, { if_exists = "skip" })
    end
    return result_path
end

-- Schema declarations are trusted. Return packed run parameters or a CLI error.
local function parse_args(command, argv)
    local function many(spec)
        return spec.arity == '*' or spec.arity == '+'
    end
    local function parse(spec, text)
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
    local function option_like(text)
        return #text > 1 and text:sub(1, 1) == '-' and tonumber(text) == nil
    end

    local spellings = {}
    for key, spec in pairs(command.opts or {}) do
        spellings['--' .. key:gsub('_', '-')] = key
        for short in (spec.short or ''):gmatch('.') do spellings['-' .. short] = key end
    end
    local opts, positionals = {}, {}
    local options = command.opts ~= nil
    local i = 1
    while i <= #argv do
        local text = argv[i]
        if options and text == '--' then
            options = false
        elseif options and option_like(text) then
            local spelling, attached = text:match('^([^=]+)=(.*)$')
            local key = spellings[spelling or text]
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
                    if raw == nil or option_like(raw) then return nil, 'option ' .. label .. ' requires a value' end
                end
                local message
                value, message = parse(spec, raw)
                if value == nil then return nil, label .. ': ' .. tostring(message) end
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
                    local value, message = parse(spec, positionals[index])
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

local function print_help_section(title, rows)
    if #rows == 0 then return end
    local width = 0
    for _, row in ipairs(rows) do width = math.max(width, #row[1]) end
    print('\n' .. title .. ':')
    for _, row in ipairs(rows) do
        local description = row[2] or ''
        local indent = string.rep(' ', width + 4)
        print('  ' .. row[1] .. (description == '' and '' or
            (string.rep(' ', width - #row[1] + 2) .. description:gsub('\n', '\n' .. indent))))
    end
end

local function help_value_type(spec)
    if spec.parse then return 'value' end
    return type(spec.type) == 'table' and table.concat(spec.type, '|') or (spec.type or 'string')
end

local function help_default_value(value)
    local kind = type(value)
    if kind == 'string' then return value == '' and '""' or value end
    if kind == 'number' or kind == 'boolean' then return tostring(value) end
    return '<' .. kind .. '>'
end

local function help_description(spec, positional)
    local notes = {}
    if positional and (spec.type or spec.parse) then notes[#notes + 1] = help_value_type(spec) end
    if not positional and (spec.arity == '1' or spec.arity == '+') then notes[#notes + 1] = 'required' end
    if not positional and (spec.arity == '*' or spec.arity == '+') then notes[#notes + 1] = 'repeatable' end
    if spec.default ~= nil then
        local default = help_default_value(spec.default)
        if spec.arity == '*' or spec.arity == '+' then
            local values = {}
            for _, value in ipairs(spec.default) do values[#values + 1] = help_default_value(value) end
            default = '[' .. table.concat(values, ', ') .. ']'
        end
        notes[#notes + 1] = 'default: ' .. default
    end
    local description = spec.description or ''
    if #notes > 0 then
        description = description .. (description == '' and '' or ' ') .. '(' .. table.concat(notes, '; ') .. ')'
    end
    return description
end

local function print_help_options(opts)
    local names, rows = {}, {}
    for key in pairs(opts or {}) do names[#names + 1] = key end
    table.sort(names)
    for _, key in ipairs(names) do
        local spec = opts[key]
        local aliases = {}
        for short in (spec.short or ''):gmatch('.') do aliases[#aliases + 1] = '-' .. short end
        aliases[#aliases + 1] = '--' .. key:gsub('_', '-')
        local label = table.concat(aliases, ', ')
        if not spec.flag then label = label .. ' <' .. help_value_type(spec) .. '>' end
        rows[#rows + 1] = { label, help_description(spec, false) }
    end
    print_help_section('Options', rows)
end

function main(args)
    local main_command = {
        args = { end_opts = true, { 'args', arity = '*' } },
        opts = {
            launcher = { description = 'Path to the project launcher' },
            help = { flag = true, short = 'h?', description = 'Show help for a command, or list commands' },
            version = { flag = true, description = 'Show dotcmd version' },
            cache_dir = { flag = true, description = 'Show shared cache directory' },
            licenses = { flag = true, description = 'Show dependency licenses' },
        },
    }
    local parsed, message = parse_args(main_command, args)
    if not parsed then
        io.stderr:write('dotcmd: ' .. message .. '\n')
        return 2
    end
    local opts = table.remove(parsed, 1)
    local name = table.remove(parsed, 1)

    if opts.version then
        print("dotcmd " .. host.version)
        return 0
    end
    if opts.cache_dir then
        print(host.cache_dir)
        return 0
    end
    if opts.licenses then
        io.write(host.licenses)
        return 0
    end

    local launcher = opts.launcher or (host.cwd .. "/.cmd")
    if host.os == "windows" then launcher = launcher:gsub("\\", "/") end
    if launcher:sub(1, 1) ~= "/" and not (host.os == "windows" and launcher:match("^%a:/")) then
        launcher = host.cwd .. "/" .. launcher
    end
    host.project_dir = launcher:match("^(.*)/")
    if host.project_dir == "" then host.project_dir = "/" end
    local help = name == nil or opts.help
    local path = host.project_dir .. "/.cmd.lua"
    local project, message = loadfile(path, "t")
    local commands = {}
    if project then
        commands = project()
    else
        -- A missing project is a CLI condition, not a Lua failure.
        local file, _, code = io.open(path, "r")
        if file then file:close() end
        if code ~= 2 then error(message) end -- ENOENT on POSIX and Windows.
        if not help then
            io.stderr:write("dotcmd: cannot run '" .. name .. "': no .cmd.lua found in " .. host.project_dir .. "\n")
            return 1
        end
    end
    if type(commands) ~= "table" then error(".cmd.lua must return a command table") end

    for name, command in pairs(commands) do
        if type(name) ~= "string" or name == "" then error("command names must be nonempty strings") end
        if type(command) ~= "function" then
            if type(command) ~= "table" or type(command.run) ~= "function" then
                error("command " .. name .. " must be a function or a table with a run function")
            end
            if command.description ~= nil and type(command.description) ~= "string" then
                error("description for command " .. name .. " must be a string")
            end
        end
    end

    if name == nil then
        print('Usage: .cmd [options] <command> [args...]')
        local names, rows = {}, {}
        for key in pairs(commands) do names[#names + 1] = key end
        table.sort(names)
        for _, key in ipairs(names) do
            local entry = commands[key]
            local description = type(entry) == 'table' and entry.description
            rows[#rows + 1] = { key, description and description:match('^[^\r\n]*') }
        end
        print_help_section('Commands', rows)
        print_help_options(main_command.opts)
        return 0
    end

    local command = commands[name]
    if command == nil then
        io.stderr:write("dotcmd: unknown command: " .. name .. "\nRun .cmd --help to list available commands.\n")
        return 1
    end
    if opts.help then
        if type(command) == 'function' then command = {} end
        local usage = 'Usage: .cmd ' .. name
        local rows = {}
        if command.opts and next(command.opts) then usage = usage .. ' [options]' end
        if command.args == nil then
            usage = usage .. ' [args...]'
        else
            for _, spec in ipairs(command.args) do
                local arity = spec.arity or '1'
                local label = spec[1] .. ((arity == '*' or arity == '+') and '...' or '')
                if arity == '?' or arity == '*' then
                    label = '[' .. label .. ']'
                else
                    label = '<' .. label .. '>'
                end
                usage = usage .. ' ' .. label
                rows[#rows + 1] = { spec[1], help_description(spec, true) }
            end
        end
        print(usage)
        if command.description then print('\n' .. command.description:gsub('%s+$', '')) end
        print_help_section('Arguments', rows)
        print_help_options(command.opts)
        return 0
    end
    local run = type(command) == "function" and command or command.run
    local code
    if type(command) == 'table' and (command.opts ~= nil or command.args ~= nil) then
        local parameters, message = parse_args(command, parsed)
        if not parameters then
            io.stderr:write('dotcmd ' .. name .. ': ' .. message .. '\n')
            return 2
        end
        code = run(table.unpack(parameters, 1, parameters.n))
    else
        code = run(table.unpack(parsed))
    end
    if code == nil then return 0 end
    if math.type(code) ~= "integer" or code < 0 or code > 255 then
        error("command " .. name .. " must return nil or an integer exit code between 0 and 255")
    end
    return code
end
