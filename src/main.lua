---@type dotcmd.Env|_G
local _ENV = _ENV
local internal = ...
local args = require('dotcmd.args')
local commands = require('dotcmd.commands')

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
        assert(sha256 { path = temp } == hash, "cached: SHA-256 mismatch for " .. options.url)
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

function plugin(url, hash)
    local path = cached { url = url, sha256 = hash }
    local file <close> = assert(io.open(path, "rb"))
    local source = assert(file:read("a"))
    assert(sha256(source) == hash, "plugin: SHA-256 mismatch for " .. url)
    return assert(load(source, "@" .. url, "t"))()
end

local main_command = {
    args = { end_opts = true, { 'args', arity = '*', default = { '--help' } } },
    opts = {
        launcher = { hidden = true },
    },
}

local all_commands, launcher

local builtin_commands = {
    __complete = {
        hidden = true,
        args = { { 'protocol' }, { 'prefix' }, { 'words', arity = '*' } },
        run = function(protocol, prefix, ...)
            return require('dotcmd.completion').complete(all_commands, protocol, prefix, ...)
        end,
    },
    __setup = {
        description = 'Set up dotcmd integrations',
        commands = {
            completions = {
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
        },
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
        args = { { 'command', arity = '*', description = 'Command path to describe' } },
        run = function(...)
            return require('dotcmd.help')(all_commands, main_command, ...)
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

    all_commands = commands.normalize(command_definitions)

    local words = { name }
    for _, word in ipairs(parsed) do words[#words + 1] = word end
    local resolution, resolve_error, error_code = commands.resolve(all_commands, words)
    if not resolution then
        if not ok then
            io.stderr:write('dotcmd: ' .. tostring(project) .. '\n')
        else
            io.stderr:write('dotcmd: ' .. tostring(resolve_error) .. '\nRun .cmd --help to list available commands.\n')
        end
        return error_code or 1
    end
    local command, arguments, path, inherited_opts =
        resolution.command, resolution.arguments, resolution.path, resolution.opts
    local schema = { opts = inherited_opts, args = command.commands and {} or command.args }
    if command.commands and not command.run then
        local _, message = args.parse(schema, arguments)
        if message then
            io.stderr:write('dotcmd ' .. table.concat(path, ' ') .. ': ' .. message .. '\n')
            return 2
        end
        return require('dotcmd.help')(all_commands, main_command, table.unpack(path)) or 0
    end
    local code
    if schema.opts ~= nil or schema.args ~= nil then
        local parameters, message = args.parse(schema, arguments)
        if not parameters then
            io.stderr:write('dotcmd ' .. table.concat(path, ' ') .. ': ' .. message .. '\n')
            return 2
        end
        code = command.run(table.unpack(parameters, 1, parameters.n))
    else
        code = command.run(table.unpack(arguments))
    end
    if code == nil then return 0 end
    if math.type(code) ~= "integer" or code < 0 or code > 255 then
        error("command " .. table.concat(path, ' ') .. " must return nil or an integer exit code between 0 and 255")
    end
    return code
end
