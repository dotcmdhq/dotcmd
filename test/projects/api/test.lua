local S = require("dotcmd.schema")
local api = require("dotcmd.api")

test("API registry describes every public global", function()
    local globals = { host = host, fs = fs, json = json, http = http, exec = exec, spawn = spawn,
        sha256 = sha256, extract = extract, fetch = fetch, plugin = plugin, task = task, prepend_path = prepend_path }
    assert(S.validate(api, globals) == globals)
    -- Resolve nested named types without losing the root registry's scope.
    assert(S.validate_call(S.at(api, { "fs", "stat" }), "path", { follow = false }))
    assert(S.validate_call(S.at(api, { "exec" }), { { "program", "inner" }, "outer", env = {
        NAME = function(old) return old end,
    } }))
    assert(S.validate_call(S.at(api, { "sha256" })))
    assert(S.validate_call(S.at(api, { "sha256" }), { bytes = "" }))
    t.assert_error("fs.stat: argument \"path\" must be a string, got number", function()
        S.validate_call(S.at(api, { "fs", "stat" }), 42)
    end)
end)

test("Lua entry points validate before doing any work", function()
    t.assert_error("prepend_path:", function() prepend_path() end)
    t.assert_error("prepend_path:", function() prepend_path("bin", false) end)
    t.assert_error("fetch: argument \"options\"", function() fetch(false) end)
    t.assert_error("fetch: field \"options.sha256\" is required", function() fetch { url = "https://example.com/file" } end)
    t.assert_error("fetch: field \"options.prepare\" must be Prepare or nil", function()
        fetch { url = "https://example.com/file", sha256 = "unused", prepare = false }
    end)
    t.assert_error("plugin: argument \"sha256\" must be a string, got number", function() plugin("https://example.com/file", 42) end)
    t.assert_error("fetch: unknown field \"options.preapre\"", function()
        fetch { url = "https://example.com/file", sha256 = "unused", preapre = function() end }
    end)
end)

test("prepend_path preserves directory order and handles absent and empty PATH", function()
    local update = prepend_path("sdk ü/bin", "other sdk/bin")
    local prefix = "sdk ü/bin" .. host.path_sep .. "other sdk/bin"
    assert(update() == prefix and update("") == prefix)
    assert(update("existing") == prefix .. host.path_sep .. "existing")
    assert(prepend_path("bin")("bin") == "bin" .. host.path_sep .. "bin")
end)

test("native custom errors identify arguments and fields", function()
    t.assert_error("fs: argument \"path\" must be nonempty", function() fs.read("") end)
    t.assert_error("exec: argument \"command\" requires an executable", function() exec {} end)
    t.assert_error("http: field \"options.url\" is required", function() http {} end)
    t.assert_error("http: field \"options.timeout\" must be a nonnegative integer", function()
        http { url = "https://example.com/", timeout = -1 }
    end)
    t.assert_error("extract: field \"options.strip_components\" must be nonnegative", function()
        extract { path = "unused", strip_components = -1 }
    end)
    t.assert_error("sha256: specify exactly one of \"options.bytes\" or \"options.path\"", function() sha256 {} end)
    t.assert_error("json.decode: expected one string argument \"text\"", function() json.decode(42) end)
end)

test("native functions retain permissive argument handling", function()
    local stat = fs.stat(".", { follow = true, unrelated = 42 }, "ignored")
    assert(stat.type == "directory")
    assert(sha256 { bytes = "", unrelated = 42 } == sha256 { bytes = "" })
    assert(json.encode(true, { pretty = false, unrelated = 42 }) == "true")
    -- Native functions have not been wrapped in Lua validators.
    assert(debug.getinfo(fs.stat, "S").what == "C")
    assert(debug.getinfo(http, "S").what == "C")
end)

test("task definitions use local recursive references", function()
    local tasks = S.registry { definitions = api.definitions, schema = S.ref { name = "Tasks" } }
    local value = {
        run = function() end,
        group = { opts = { verbose = { flag = true, short = "v" } }, tasks = {
            child = { args = { { "path", type = "file" }, { "extras", arity = "*" } }, run = function() end },
        } },
    }
    assert(S.validate(tasks, value) == value)
end)

test("API children inherit fields without repeating definitions", function()
    for child, parent in pairs({ ExecCommand = "Command", SpawnCommand = "Command",
        FetchOptions = "PinnedSource", Option = "ValueSpec", Argument = "ValueSpec" }) do
        assert(api.definitions[child].extends.name == parent)
    end
    assert(api.definitions.ExecCommand.fields.cwd == nil and api.definitions.FetchOptions.fields.url == nil)
    assert(S.validate_call(S.at(api, { "exec" }), { "program", "arg", stdout = "capture", cwd = "." }))
    assert(S.validate_call(S.at(api, { "spawn" }), { "program", "arg", stdin = "pipe", env = { KEY = "value" } }))
    assert(S.validate_call(S.at(api, { "fetch" }), { url = "https://example.com", sha256 = "hash", name = "tool" }))
    t.assert_error("fetch: field \"options.url\" must be a string, got number", function()
        S.validate_call(S.at(api, { "fetch" }), { url = 42, sha256 = "hash" })
    end)
end)
