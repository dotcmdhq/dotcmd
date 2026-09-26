assert(type(host) == "table") -- Available while loading the project, not just in commands.
assert(select("#", ...) == 0)
local function hex(value)
    return (value:gsub(".", function(c) return ("%02x"):format(c:byte()) end))
end
return {
    help = function() print("project help") end,
    update = function() print("project update") end,
    __echo = function(value) print(value) end,
    build_docs = {
        aliases = { "docs", "docs_local", "-d" },
        description = "Build documentation",
        args = { { "value" } },
        run = function(value) print(value) end,
    },
    ["already-hyphenated"] = function() print("hyphenated") end,
    args = {description = "Print arguments as hex", run = function(...)
        print(select("#", ...))
        for i = 1, select("#", ...) do print(hex(select(i, ...))) end
    end},
    context = function() print(host.cwd); print(host.project_dir); print(host.os); print(host.arch) end,
    status = function(code) error({ exit_code = tonumber(code) }) end,
    nothing = function() end,
    values = function()
        print("printed")
        return "hello", 3, false, nil, "", "two\nlines", nil
    end,
    nil_value = function() return nil end,
    objects = function()
        return setmetatable({}, { __tostring = function() return "custom display" end }), {}
    end,
    pretty_nested = function()
        return {
            sha256 = {
                windows = { x64 = "windows-x64", arm64 = "windows-arm64" },
                linux = { x64 = "linux-x64", arm64 = "linux-arm64" },
                macos = { x64 = "macos-x64", arm64 = "macos-arm64" },
            },
            version = "1.13.2",
        }
    end,
    pretty_order = function()
        local value = {}
        value.zebra = 1
        value.alpha = 2
        value[10] = "ten"
        value[2] = "two"
        value[true] = "yes"
        value[false] = "no"
        value.z_table = { value = 1 }
        value.a_table = { value = 2 }
        return value
    end,
    pretty_array = function()
        return { "one", "two", [4] = "four", map = "value", nested = {} }
    end,
    pretty_strings = function()
        return {
            text = "quote \" slash \\ newline\n tab\t nul\0",
            ["end"] = "reserved",
            ["two words"] = "spaced",
        }
    end,
    pretty_repeated = function()
        local shared = { x = 1 }
        return { right = shared, left = shared }
    end,
    pretty_raw = function()
        return setmetatable({ visible = true }, {
            __pairs = function() error("__pairs must not be called") end,
        })
    end,
    pretty_cycle = function()
        local value = { child = {} }
        value.child.parent = value
        return value
    end,
    pretty_table_key = function()
        return { [{ identity = true }] = "value" }
    end,
    pretty_bad_value = function(kind)
        local values = {
            ["function"] = function() end,
            userdata = io.stdout,
            thread = coroutine.create(function() end),
        }
        return "before", { outer = { bad = values[kind] } }
    end,
    pretty_bad_number = function(kind)
        if kind == "key" then return { [math.huge] = true } end
        return { bad = kind == "nan" and (0 / 0) or math.huge }
    end,
    structured_error = function(code, message)
        error({ exit_code = tonumber(code), message = message })
    end,
    invalid_error = function(kind)
        local errors = {
            string_code = { exit_code = "2" },
            fraction = { exit_code = 1.5 },
            negative = { exit_code = -1 },
            large = { exit_code = 256 },
            message = { message = setmetatable({}, { __tostring = function() return "original failure" end }) },
        }
        local value = errors[kind]
        value.message = value.message or "original failure"
        error(value)
    end,
    object_error = function()
        error(setmetatable({}, { __tostring = function() return "ordinary object error" end }))
    end,
    rethrow = function()
        local value = { exit_code = 23, message = "caught error" }
        local ok, caught = pcall(error, value)
        assert(not ok and caught == value)
        error(caught)
    end,
    unwind = function(path)
        local value = { exit_code = 19, message = "before cleanup" }
        local cleanup <close> = setmetatable({}, { __close = function()
            local file <close> = assert(io.open(path, "w"))
            file:write("closed")
            value.exit_code, value.message = 99, "after cleanup"
        end })
        error(value)
    end,
    crash = function() error("intentional project error") end,
    equivalent_error = function(kind)
        if kind == "table" then error({ message = "same failure" }) end
        error("same failure")
    end,
    deploy = {
        description = [[Deploy files

Uploads the selected files to the deployment target.
Existing files are replaced.
]],
        args = { { "target", description = "Deployment target" }, { "files", type = "file", arity = "*", description = "Files to deploy" } },
        opts = {
            jobs = { short = "j", type = "integer", default = 4, description = "Parallel jobs" },
            mode = { type = { "debug", "release" }, default = "release", description = "Build mode" },
            include = { type = "directory", arity = "*", default = { "src", "lib" }, description = "Include directory" },
            verbose = { flag = true, short = "v", arity = "*", description = "Increase verbosity" },
            token = { arity = "1", parse = function() error("help called parse") end },
        },
        run = function() error("help called run") end,
    },
    empty_schema = { opts = {}, args = {}, run = function() error("help called run") end },
    hidden_options = {
        opts = { internal = { hidden = true, flag = true } },
        args = {},
        run = function(opts) print(tostring(opts.internal)) end,
    },
}
