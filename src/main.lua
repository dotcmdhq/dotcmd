local internal = ...
local args = require("dotcmd.args")
local tasks = require("dotcmd.tasks")
local format = require("dotcmd.format")
local pretty = require("dotcmd.pretty")
local S = require("dotcmd.schema")
local api = require("dotcmd.api")
local fetch_schema = S.at(api, { "fetch" })
local plugin_schema = S.at(api, { "plugin" })
local task_schema = S.at(api, { "task" })
local prepend_path_schema = S.at(api, { "prepend_path" })
local output = format.writer(io.stdout)

function prepend_path(...)
    S.validate_call(prepend_path_schema, ...)
    local separator = host.path_sep
    local prefix = table.concat({ ... }, separator)
    return function(old)
        if old == nil or old == "" then return prefix end
        return prefix .. separator .. old
    end
end

-- Project tasks are {name = function(...) ... end} or
-- {name = {description = "...", run = function(...) ... end}} from .cmd.lua.
-- host is global; optional opts/args schemas prepare the arguments to run.
-- Completed entries are trusted; only fresh downloads are verified.
function fetch(...)
    S.validate_call(fetch_schema, ...)
    local options, hash = ...
    if type(options) == "string" then options = { url = options, sha256 = hash } end
    hash = options.sha256
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
        local ok, identity = pcall(string.dump, prepare, true)
        if not ok then
            local native_name = internal.native_function_name(prepare)
            identity = native_name and ("\0native\0" .. native_name)
        end
        assert(identity, "fetch: prepare must be a Lua function or named native function")
        -- Captured values and ambient state are the caller's responsibility.
        prepared_dir = host.cache_dir .. "/prepared/" .. sha256 { bytes = hash .. "\0" .. name
            .. "\0" .. host.os .. "\0" .. host.arch .. "\0" .. identity }
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
        http { url = options.url, to = temp, progress = true }
        assert(sha256 { path = temp } == hash, "fetch: SHA-256 mismatch for " .. options.url)
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
            "fetch: prepare must create the output file or directory")
        -- Publish the whole entry atomically; a concurrent winner is reused.
        fs.rename(temp, prepared_dir, { if_exists = "skip" })
    end
    return result_path
end

local loaded_plugins = {}

function plugin(...)
    S.validate_call(plugin_schema, ...)
    local url, hash = ...
    local values = loaded_plugins[hash]
    if values then return table.unpack(values, 1, values.n) end

    local path = fetch { url = url, sha256 = hash }
    local source = assert(fs.read(path), "plugin: missing source: " .. path)
    assert(sha256 { bytes = source } == hash, "plugin: SHA-256 mismatch for " .. url)
    values = table.pack(assert(load(source, "@" .. url, "t"))())
    loaded_plugins[hash] = values
    return table.unpack(values, 1, values.n)
end

local launcher = internal.launcher
local all_tasks, project_missing
local project_ok, project_error

local function fail_invocation(message, code, path)
    if message and path and #path > 0 then message = table.concat(path, " ") .. ": " .. message end
    error({ message = message, exit_code = code }, 0)
end

-- Prepare one invocation without catching task errors or formatting its values.
local function invocation(argv, fail)
    local resolution, message, code = tasks.resolve(all_tasks, argv)
    if not resolution then
        if not project_ok then
            if type(project_error) == "table" then error(project_error, 0) end
            return fail(tostring(project_error), code or 1)
        end
        return fail(message .. "\nRun .cmd --help to list available tasks.", code or 1)
    end
    local selected, arguments, path = resolution.task, resolution.arguments, resolution.path
    local schema = { opts = resolution.opts, args = selected.tasks and {} or selected.args }
    if selected.tasks and not selected.run then
        local _, parse_error = args.parse(schema, arguments)
        if not parse_error then require("dotcmd.help")(all_tasks, project_missing, table.unpack(path)) end
        return fail(parse_error, 2, path)
    end
    if schema.opts ~= nil or schema.args ~= nil then
        local parameters, parse_error = args.parse(schema, arguments)
        if not parameters then return fail(parse_error, 2, path) end
        return selected.run, parameters
    end
    return selected.run, table.pack(table.unpack(arguments))
end

function task(...)
    S.validate_call(task_schema, ...)
    local run, parameters = invocation({ ... }, fail_invocation)
    return run(table.unpack(parameters, 1, parameters.n))
end

local builtin_tasks = {
    __eval = {
        description = [[Evaluate a Lua expression or chunk

Uses the same runtime globals and project working directory as tasks.
Returned values use the task result formatter. Explicit print calls retain Lua behavior.

Examples:
  .cmd --eval 'host'
  .cmd --eval 'local x = 40; return x + 2']],
        args = { { "code", description = "Lua expression or chunk" } },
        run = function(source)
            local chunk, message = require("dotcmd.eval").compile(source, "=eval", _ENV)
            if not chunk then error(message, 0) end
            return chunk()
        end,
    },
    __repl = {
        description = "Start a Lua REPL",
        args = {},
        run = function()
            require("dotcmd.eval").repl(_ENV, internal.format_error)
        end,
    },
    __resolve = require("dotcmd.resolve"),
    __complete = {
        hidden = true,
        args = { { "protocol" }, { "prefix" }, { "words", arity = "*" } },
        run = function(protocol, prefix, ...)
            return require("dotcmd.completion").complete(all_tasks, protocol, prefix, ...)
        end,
    },
    __setup = {
        description = "Set up dotcmd integrations",
        tasks = {
            luals = {
                description = [[Generate LuaLS configuration and dotcmd API declarations

Creates .luarc.json and .cmd.d.lua in the project directory.
Configuration with "$dotcmd": true is managed: rerunning replaces both files.
Existing unmanaged configuration or declarations are never overwritten.]],
                args = {},
                run = function() return require("dotcmd.luals").setup() end,
            },
            completions = {
                description = [[Install shell completions for the current user

Supports task names, options, enum and boolean values, and paths from task schemas.
The shell defaults to SHELL; specify it when using a different shell or when SHELL is unset.
Use pwsh for PowerShell 7, or powershell for Windows PowerShell.
Updates the adapter and its shell startup entry when run again.
Open a new shell after setup.]],
                args = { { "shell", arity = "?", type = { "bash", "zsh", "fish", "powershell", "pwsh" },
                    description = "Shell to configure (default: SHELL)" } },
                run = function(shell)
                    return require("dotcmd.completion").setup(internal.completion_scripts, shell, internal.detect_shell)
                end,
            },
        },
    },
    __init = {
        description = [[Create the project's .cmd.lua file

Writes a minimal file that returns an empty task table.
Does not overwrite an existing .cmd.lua.]],
        args = {},
        run = function()
            fs.write(".cmd.lua", [[---@type Tasks
return {}
]], { if_exists = "error" })
            output:write({ "Created .cmd.lua\nOptional: run ",
                { bold = true, ".cmd --setup completions" }, " to enable shell completions.\n" }):flush()
        end,
    },
    __update = {
        description = [[Update the project launcher to a release

Replaces the entire launcher, including local edits, with the published release.
Follows symlinks and updates their target, preserving the links.
Accepts latest or an exact release tag; downgrades are allowed.
Does nothing when the selected version matches the running dotcmd version.
The next invocation downloads the selected binary if it is not already cached.]],
        args = { { "version", arity = "?", default = "latest", description = "Release version or latest",
            parse = function(value)
                if value ~= "" and value ~= "." and value ~= ".." then return value end
                return nil, "expected a release tag"
            end,
        } },
        run = function(version)
            return require("dotcmd.update")(launcher, version, internal.version)
        end,
    },
    __version = {
        description = "Show dotcmd version",
        args = {},
        run = function() print("dotcmd " .. internal.version) end,
    },
    __cache_dir = {
        description = "Show shared cache directory",
        args = {},
        run = function() print(host.cache_dir) end,
    },
    __licenses = {
        description = "Show dependency licenses",
        args = {},
        run = function() io.write(internal.licenses) end,
    },
    __api = {
        description = [[Show Lua API documentation

Without a name, lists functions, runtime tables, and configuration types.
A name shows signatures, fields, and descriptions, followed by referenced type definitions.

Examples:
  .cmd --api fetch
  .cmd --api fs.stat
  .cmd --api Tasks]],
        args = { { "name", arity = "?", type = "string", description = "Global, named type, or dotted member path" } },
        run = function(name) api.show(name) end,
    },
    __help = {
        aliases = { "-h", "-?" },
        description = "Show help for a task, or list tasks",
        args = { { "task", arity = "*", description = "Task path to describe" } },
        run = function(...)
            return require("dotcmd.help")(all_tasks, project_missing, ...)
        end,
    },
}

return function(argv)
    local ok, project, missing = pcall(function()
        if not fs.stat(".cmd.lua", { follow = false }) then return {}, true end
        return assert(loadfile(".cmd.lua", "t"))(), false
    end)
    project_ok, project_error = ok, project
    project_missing = missing or false
    local task_definitions = ok and project or {}
    for key, task in pairs(builtin_tasks) do task_definitions[key] = task end

    all_tasks = tasks.normalize(task_definitions)

    local run, parameters = invocation(argv, function(message, code, path)
        if message then
            local prefix = "dotcmd"
            if path and #path > 0 then prefix = prefix .. " " .. table.concat(path, " ") end
            io.stderr:write(prefix .. ": " .. message .. "\n")
        end
        return nil, code
    end)
    if not run then return parameters end
    local results = table.pack(run(table.unpack(parameters, 1, parameters.n)))
    for i = 1, results.n do output:write({ pretty(results[i]), "\n" }) end
    output:flush()
    return 0
end
