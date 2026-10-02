local internal = ...
local args = require("dotcmd.args")
local tasks = require("dotcmd.tasks")
local format = require("dotcmd.format")
local pretty = require("dotcmd.pretty")
local S = require("dotcmd.schema")
local api = require("dotcmd.api")
local fetch_schema = S.at(api, { "fetch" })
local plugin_schema = S.at(api, { "plugin" })
local output = format.writer(io.stdout)

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

local builtin_tasks = {
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

Without a name, lists functions and runtime tables.
A name shows signatures, fields, and descriptions.

Examples:
  .cmd --api fetch
  .cmd --api fs.stat
  .cmd --api Task]],
        args = { { "name", arity = "?", description = "Global, dotted member path, or named type" } },
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
    project_missing = missing or false
    local task_definitions = ok and project or {}
    for key, task in pairs(builtin_tasks) do task_definitions[key] = task end

    all_tasks = tasks.normalize(task_definitions)

    local resolution, resolve_error, error_code = tasks.resolve(all_tasks, argv)
    if not resolution then
        if not ok then
            if type(project) == "table" then error(project) end
            io.stderr:write("dotcmd: " .. tostring(project) .. "\n")
        else
            io.stderr:write("dotcmd: " .. tostring(resolve_error) .. "\nRun .cmd --help to list available tasks.\n")
        end
        return error_code or 1
    end
    local task, arguments, path, inherited_opts =
        resolution.task, resolution.arguments, resolution.path, resolution.opts
    local schema = { opts = inherited_opts, args = task.tasks and {} or task.args }
    if task.tasks and not task.run then
        local _, message = args.parse(schema, arguments)
        if message then
            local command = #path == 0 and "dotcmd" or "dotcmd " .. table.concat(path, " ")
            io.stderr:write(command .. ": " .. message .. "\n")
        else
            require("dotcmd.help")(all_tasks, project_missing, table.unpack(path))
        end
        return 2
    end
    local results
    if schema.opts ~= nil or schema.args ~= nil then
        local parameters, message = args.parse(schema, arguments)
        if not parameters then
            io.stderr:write("dotcmd " .. table.concat(path, " ") .. ": " .. message .. "\n")
            return 2
        end
        results = table.pack(task.run(table.unpack(parameters, 1, parameters.n)))
    else
        results = table.pack(task.run(table.unpack(arguments)))
    end
    for i = 1, results.n do output:write({ pretty(results[i]), "\n" }) end
    output:flush()
    return 0
end
