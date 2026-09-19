---@type dotcmd.Env|_G
local _ENV = _ENV

-- Projects return {name = function(...) ... end} or
-- {name = {description = "...", run = function(...) ... end}} from .cmd.lua.
-- host is global; commands receive CLI strings as varargs.
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
    local extraction = options.extract == true and {} or options.extract
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
    local path = download_path
    if extraction then
        path = host.cache_dir .. "/extracted/" .. sha256(hash .. "\0" .. ("%d"):format(extraction.strip_components or 0)
            .. "\0" .. table.concat(extraction.include or {}, "\0"))
    end
    if fs.stat(path) then
        return path
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
        fs.rename(temp, download_path)
    end

    if extraction then
        fs.mkdir(host.cache_dir .. "/extracted")
        extract {
            path = download_path,
            to = path,
            strip_components = extraction.strip_components,
            include = extraction.include,
        }
    end
    return path
end

function main(args)
    local launcher
    if args[1] == "--launcher" then
        table.remove(args, 1)
        launcher = table.remove(args, 1)
    end

    if args[1] == "--version" then
        print("dotcmd " .. host.version)
        return 0
    end
    if args[1] == "--licenses" then
        io.write(host.licenses)
        return 0
    end

    launcher = launcher or (host.cwd .. "/.cmd")
    if host.os == "windows" then launcher = launcher:gsub("\\", "/") end
    if launcher:sub(1, 1) ~= "/" and not (host.os == "windows" and launcher:match("^%a:/")) then
        launcher = host.cwd .. "/" .. launcher
    end
    host.project_dir = launcher:match("^(.*)/")
    if host.project_dir == "" then host.project_dir = "/" end
    local name = args[1]
    local help = name == nil or name == "--help" or name == "-h"
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

    local names = {}
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
        names[#names + 1] = name
    end

    if help then
        print("Usage: .cmd <command> [args...]")
        if #names > 0 then print("\nCommands:") end
        table.sort(names)
        for _, key in ipairs(names) do
            local command = commands[key]
            local description = type(command) == "table" and command.description
            print("  " .. key .. (description and ("  " .. description) or ""))
        end
        print(
            "\nOptions:\n  -h, --help  Show help\n  --version  Show dotcmd version\n  --licenses  Show dependency licenses")
        return 0
    end

    local command = commands[name]
    if command == nil then
        io.stderr:write("dotcmd: unknown command: " .. name .. "\nRun .cmd --help to list available commands.\n")
        return 1
    end
    local run = type(command) == "function" and command or command.run
    local code = run(table.unpack(args, 2))
    if code == nil then return 0 end
    if math.type(code) ~= "integer" or code < 0 or code > 255 then
        error("command " .. name .. " must return nil or an integer exit code between 0 and 255")
    end
    return code
end
