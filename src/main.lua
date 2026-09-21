---@type dotcmd.Env|_G
local _ENV = _ENV
local internal = ...
local args = require('dotcmd.args')

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

local main_command = {
    args = { end_opts = true, { 'args', arity = '*', default = { '--help' } } },
    opts = {
        launcher = { hidden = true },
    },
}

local commands, launcher

local builtin_commands = {
    __complete = {
        hidden = true,
        args = { { 'protocol' }, { 'prefix' }, { 'words', arity = '*' } },
        run = function(protocol, prefix, ...)
            return require('dotcmd.completion').complete(commands, protocol, prefix, ...)
        end,
    },
    __setup_completions = {
        description = [[Install shell completions for the current user

Supports command names, options, enum and boolean values, and paths from command schemas.
The shell defaults to SHELL; specify it when using a different shell or when SHELL is unset.
Use pwsh for PowerShell 7, or powershell for Windows PowerShell.
Updates the adapter and its shell startup entry when run again.
Open a new shell after setup.]],
        args = { { 'shell', arity = '?', type = { 'bash', 'zsh', 'fish', 'powershell', 'pwsh' },
            description = 'Shell to configure (default: SHELL)' } },
        run = function(shell)
            return require('dotcmd.completion').setup(internal.completion_scripts, shell)
        end,
    },
    __update = {
        description = [[Update the project launcher to a release

Replaces the entire launcher, including local edits, with the published release.
Follows symlinks and updates their target, preserving the links.
Accepts latest or an exact release tag; downgrades are allowed.
Does nothing when the selected version matches the running dotcmd version.
The next invocation downloads the selected binary if it is not already cached.]],
        args = { { 'version', arity = '?', default = 'latest', description = 'Release version or latest',
            parse = function(value)
                if value ~= '' and value ~= '.' and value ~= '..' then return value end
                return nil, 'expected a release tag'
            end,
        } },
        run = function(version)
            return require('dotcmd.update')(launcher, version)
        end,
    },
    __version = {
        description = 'Show dotcmd version',
        args = {},
        run = function() print('dotcmd ' .. host.version) end,
    },
    __cache_dir = {
        description = 'Show shared cache directory',
        args = {},
        run = function() print(host.cache_dir) end,
    },
    __licenses = {
        description = 'Show dependency licenses',
        args = {},
        run = function() io.write(internal.licenses) end,
    },
    __help = {
        aliases = { '-h', '-?' },
        description = 'Show help for a command, or list commands',
        args = { { 'command', arity = '?', description = 'Command to describe' } },
        run = function(name)
            return require('dotcmd.help')(commands, main_command, name)
        end,
    },
}

function main(argv)
    local parsed, message = args.parse(main_command, argv)
    if not parsed then
        io.stderr:write('dotcmd: ' .. message .. '\n')
        return 2
    end
    local opts = table.remove(parsed, 1)
    local name = table.remove(parsed, 1)

    if not opts.launcher or opts.launcher == '' then
        io.stderr:write("dotcmd: invoke the project's .cmd launcher\n")
        return 2
    end
    launcher = opts.launcher
    if host.os == "windows" then launcher = launcher:gsub("\\", "/") end
    if launcher:sub(1, 1) ~= "/" and not (host.os == "windows" and launcher:match("^%a:/")) then
        launcher = host.cwd .. "/" .. launcher
    end
    host.project_dir = launcher:match("^(.*)/")
    if host.project_dir == "" then host.project_dir = "/" end
    local path = host.project_dir .. "/.cmd.lua"
    local ok, project = pcall(function() return assert(loadfile(path, 't'))() end)
    local command_definitions = ok and project or {}
    for key, command in pairs(builtin_commands) do command_definitions[key] = command end

    commands = {}
    for key, definition in pairs(command_definitions) do
        local command = type(definition) == 'function' and { run = definition } or definition
        local spelling = key:gsub('_', '-')
        commands[spelling] = command
        for _, alias in ipairs(command.aliases or {}) do
            commands[alias] = commands[alias] or spelling
        end
    end

    local command = commands[name]
    if type(command) == 'string' then command = commands[command] end
    if command == nil then
        if not ok then
            io.stderr:write('dotcmd: ' .. tostring(project) .. '\n')
        else
            io.stderr:write("dotcmd: unknown command: " .. name .. "\nRun .cmd --help to list available commands.\n")
        end
        return 1
    end
    local code
    if command.opts ~= nil or command.args ~= nil then
        local parameters, message = args.parse(command, parsed)
        if not parameters then
            io.stderr:write('dotcmd ' .. name .. ': ' .. message .. '\n')
            return 2
        end
        code = command.run(table.unpack(parameters, 1, parameters.n))
    else
        code = command.run(table.unpack(parsed))
    end
    if code == nil then return 0 end
    if math.type(code) ~= "integer" or code < 0 or code > 255 then
        error("command " .. name .. " must return nil or an integer exit code between 0 and 255")
    end
    return code
end
