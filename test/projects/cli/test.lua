local success, failure = t.success, t.failure
local child = host.project_dir .. "/child"
local version = t.version()
local normalized = t.normalized
local empty = t.project("empty")
local broken = t.project("broken", "this is not valid Lua!")
local load_error = host.project_dir .. "/load-error"

test("CLI help without a project", function()
    local bare = t.run_project(empty)
    assert(bare.code == 2 and bare.stderr == "", bare.stderr)
    local explicit = success(t.run_project(empty, "--help"))
    assert((bare.stdout:gsub("\r\n", "\n")) == explicit, bare.stdout)
    for _, args in ipairs({ { "-h" }, { "-?" }, { "--help" } }) do
        local output = success(t.run_project(empty, table.unpack(args)))
        assert(output:find("--version", 1, true))
        assert(output:find("--cache-dir", 1, true))
        assert(not output:find("Arguments:", 1, true), output)
        assert(not output:find("Project tasks:", 1, true), output)
        assert(output:find("Built-in tasks:", 1, true), output)
        assert(output:find("No .cmd.lua found. Run .cmd --init to create one.", 1, true), output)
    end
end)
test("CLI initializes a missing project and suggests setup", function()
    local project = t.project("initialize")
    local path = project .. "/.cmd.lua"
    local output = success(t.run_project(project, "--init"))
    assert(output:find("Created .cmd.lua\n", 1, true), output)
    assert(output:find("Optional: run .cmd --setup completions to enable shell completions.", 1, true), output)
    local source = t.read(path)
    assert(source == "---@type Tasks\nreturn {}\n", source)
    local help = success(t.run_project(project, "--help"))
    assert(not help:find("Run .cmd --init", 1, true), help)
    failure(t.run_project(project, "--init"), ".cmd.lua already exists")
    assert(t.read(path) == source)
end)
test("CLI init refuses existing and broken project files", function()
    for _, project in ipairs({ child, broken }) do
        local path = project .. "/.cmd.lua"
        local source = t.read(path)
        failure(t.run_project(project, "--init"), ".cmd.lua already exists")
        assert(t.read(path) == source)
    end
end)
test("CLI takes the launcher as its first argument", function()
    for _, args in ipairs({
        { child .. "/.cmd", "-?" },
        { child .. "/.cmd", "-h" },
        { broken .. "/.cmd", "--version" },
        { child .. "/.cmd", "nothing" },
    }) do
        local command = { host.executable, table.unpack(args) }
        command.stdout, command.stderr = "capture", "capture"
        local output = success(exec(command))
        if args[#args] == "--version" then
            assert(output == "dotcmd " .. version .. "\n")
        elseif args[#args] ~= "nothing" then
            assert(output:match("args %[args%.%.%.%]%s+Print arguments as hex"), output)
        end
    end
end)
test("CLI requires the launcher when invoked as a binary", function()
    for _, args in ipairs({ {}, { "", "nothing" } }) do
        local command = { host.executable, table.unpack(args) }
        command.cwd, command.stdout, command.stderr = child, "capture", "capture"
        command.check = false
        local result = exec(command)
        assert(result.code == 2, result.stderr)
        assert(result.stdout == "", result.stdout)
        assert(result.stderr:gsub("\r\n", "\n") == "dotcmd: invoke the project's .cmd launcher\n", result.stderr)
    end
end)
test("CLI built-ins work when project loading fails", function()
    for _, project in ipairs({ empty, broken, load_error }) do
        assert(success(t.run_project(project, "--version")) == "dotcmd " .. version .. "\n")
        assert(normalized(success(t.run_project(project, "--cache-dir")):gsub("\n$", ""))
            == normalized(host.cache_dir))
        assert(success(t.run_project(project, "--licenses")):find("Lua", 1, true))
        local output = success(t.run_project(project, "--help"))
        assert(output:find("Built-in tasks:", 1, true), output)
        assert(not output:find("Project tasks:", 1, true), output)
        for _, name in ipairs({ "--version", "--cache-dir", "--licenses" }) do
            local result = t.run_project(project, name, "extra")
            assert(result.code == 2, result.stderr)
            assert(result.stdout == "", result.stdout)
            assert(result.stderr:find("unexpected positional argument: extra", 1, true), result.stderr)
        end
    end
end)
test("CLI built-ins work when checking the project file fails", function()
    local env = setmetatable({}, { __index = _ENV })
    env._G = env
    env.host = setmetatable({ project_dir = child }, { __index = host })
    env.fs = setmetatable({ stat = function(path, options)
        if path == ".cmd.lua" then error("stat failure") end
        return fs.stat(path, options)
    end }, { __index = fs })
    local main = assert(loadfile(host.project_dir .. "/../main.lua", "t", env))({
        version = version, launcher = child .. "/.cmd",
    })
    assert(main({ "--version" }) == 0)
end)
test("CLI clean errors for missing project and unknown task", function()
    assert(not failure(t.run_project(empty, "unknown"), "unknown task"):find("stack traceback", 1, true))
    assert(not failure(t.run_project(broken, "unknown"), ".cmd.lua"):find("stack traceback", 1, true))
    assert(not failure(t.run_project(load_error, "unknown"), "intentional project load error"):find("stack traceback", 1, true))
    assert(not failure(t.run_project(child, "unknown"), "unknown task"):find("stack traceback", 1, true))
    assert(not failure(t.run_project(child, "--unknown"), "unknown task: --unknown"):find("stack traceback", 1, true))
end)
test("CLI preserves built-in resolution errors without a project file", function()
    local subtask = t.run_project(empty, "--setup", "nonexistent")
    assert(subtask.code == 1, subtask.stderr)
    assert(subtask.stderr:gsub("\r\n", "\n") == [[dotcmd: unknown subtask: nonexistent
Run .cmd --help to list available tasks.
]], subtask.stderr)

    local option = t.run_project(empty, "--setup", "--bogus")
    assert(option.code == 2, option.stderr)
    assert(option.stderr:gsub("\r\n", "\n") == [[dotcmd: unknown option: --bogus
Run .cmd --help to list available tasks.
]], option.stderr)
end)
test("CLI definitions, descriptions, and Lua errors", function()
    assert(success(t.run_project(child, "--help")):match("args %[args%.%.%.%]%s+Print arguments as hex"))
    success(t.run_project(child, "nothing"))
    assert(not failure(t.run_project(child, "crash"), "intentional project error")
        :find("stack traceback", 1, true))
end)
test("CLI prints all returned values on separate lines, preserving nils", function()
    assert(success(t.run_project(child, "nothing")) == "")
    assert(success(t.run_project(child, "nil-value")) == "nil\n")
    assert(success(t.run_project(child, "values")) == "printed\nhello\n3\nfalse\nnil\n\ntwo\nlines\nnil\n")
    assert(success(t.run_project(child, "objects")) == "custom display\n{}\n")
end)

test("CLI pretty-prints nested tables with scalar fields before nested fields", function()
    local expected = [[{
    version = "1.13.2",
    sha256 = {
        linux = {
            arm64 = "linux-arm64",
            x64 = "linux-x64"
        },
        macos = {
            arm64 = "macos-arm64",
            x64 = "macos-x64"
        },
        windows = {
            arm64 = "windows-arm64",
            x64 = "windows-x64"
        }
    }
}
]]
    assert(success(t.run_project(child, "pretty-nested")) == expected)
end)

test("CLI pretty-printing orders named keys deterministically by value and key type", function()
    local expected = [[{
    alpha = 2,
    zebra = 1,
    [2] = "two",
    [10] = "ten",
    [false] = "no",
    [true] = "yes",
    a_table = {
        value = 2
    },
    z_table = {
        value = 1
    }
}
]]
    assert(success(t.run_project(child, "pretty-order")) == expected)
end)

test("CLI pretty-printing supports arrays mixed with named entries and empty tables", function()
    local output = success(t.run_project(child, "pretty-array"))
    local expected = [[{
    "one",
    "two",
    map = "value",
    [4] = "four",
    nested = {}
}
]]
    assert(output == expected, output)
    assert(not output:match(",\n%s*}"), output)
    assert(success(t.run_project(child, "objects")):sub(-3) == "{}\n")
end)

test("CLI pretty-printing double-quotes strings and quotes reserved and non-identifier keys", function()
    local output = success(t.run_project(child, "pretty-strings"))
    local expected = [[{
    ["end"] = "reserved",
    text = "quote \" slash \\ newline\n tab\t nul\000",
    ["two words"] = "spaced"
}
]]
    assert(output == expected, output)
    local chunk, message = load("return " .. output, "pretty output", "t", {})
    assert(chunk, message)
    local value = chunk()
    assert(value.text == "quote \" slash \\ newline\n tab\t nul\0")
end)

test("CLI pretty-printing expands repeated table references independently", function()
    local expected = [[{
    left = {
        x = 1
    },
    right = {
        x = 1
    }
}
]]
    assert(success(t.run_project(child, "pretty-repeated")) == expected)
end)

test("CLI pretty-printing uses raw iteration", function()
    assert(success(t.run_project(child, "pretty-raw")) == "{\n    visible = true\n}\n")
end)

test("CLI pretty-printing shows cycles and table keys as pseudo-Lua", function()
    local output = success(t.run_project(child, "pretty-cycle"))
    assert(output:find("parent = <table: ", 1, true), output)
    assert(output:sub(-8) == "    }\n}\n", output)

    output = success(t.run_project(child, "pretty-table-key"))
    assert(output:find("[<table: ", 1, true), output)
    assert(output:find(">] = \"value\"", 1, true), output)
end)

test("CLI pretty-printing shows unsupported nested values as pseudo-Lua", function()
    local expected = {
        ["function"] = "bad = <function: ",
        userdata = "bad = <file ",
        thread = "bad = <thread: ",
    }
    for kind, fragment in pairs(expected) do
        local output = success(t.run_project(child, "pretty-bad-value", kind))
        assert(output:sub(1, 9) == "before\n{\n", output)
        assert(output:find(fragment, 1, true), output)
        assert(output:sub(-8) == "    }\n}\n", output)
    end
end)

test("CLI pretty-printing shows non-finite numeric values and keys as pseudo-Lua", function()
    for _, kind in ipairs({ "nan", "infinity", "key" }) do
        local output = success(t.run_project(child, "pretty-bad-number", kind))
        assert(output:find("<", 1, true) and output:find(">", 1, true), output)
    end
end)

test("CLI structured errors have custom exit codes and optional clean diagnostics", function()
    local result = t.run_project(child, "structured-error", "23", "failure ü")
    assert(result.code == 23 and result.stdout == "", result.stderr)
    assert(result.stderr:gsub("\r\n", "\n") == "dotcmd: failure ü\n", result.stderr)
    result = t.run_project(child, "structured-error", "-", "default failure")
    assert(result.code == 1 and result.stderr:gsub("\r\n", "\n") == "dotcmd: default failure\n")
    result = t.run_project(child, "rethrow")
    assert(result.code == 23 and result.stderr:gsub("\r\n", "\n") == "dotcmd: caught error\n")
end)

test("CLI preserves diagnostics when structured error metadata is invalid", function()
    for _, kind in ipairs({ "string_code", "fraction", "negative", "large", "message" }) do
        local output = failure(t.run_project(child, "invalid-error", kind), "original failure")
        assert(output:gsub("\r\n", "\n") == "dotcmd: original failure\n", output)
    end
    assert(not failure(t.run_project(child, "object-error"), "ordinary object error")
        :find("stack traceback", 1, true))
end)

test("CLI formats string and table errors consistently apart from Lua source locations", function()
    local text = failure(t.run_project(child, "equivalent-error", "string"), "same failure")
    local object = failure(t.run_project(child, "equivalent-error", "table"), "same failure")
    text = text:gsub("^dotcmd: .-:%d+: ", "dotcmd: ")
    assert(text == object, text .. object)
end)

test("CLI structured errors unwind resources without losing their diagnostic", function()
    local path = host.project_dir .. "/closed.txt"
    local result = t.run_project(child, "unwind", path)
    assert(result.code == 19 and result.stderr:gsub("\r\n", "\n") == "dotcmd: before cleanup\n", result.stderr)
    assert(t.read(path) == "closed")
end)

test("CLI preserves structured project loading errors while keeping built-ins available", function()
    local project = t.project("structured load error", "error { exit_code = 31, message = \"load failed\" }")
    local result = t.run_project(project, "build")
    assert(result.code == 31 and result.stderr:gsub("\r\n", "\n") == "dotcmd: load failed\n")
    assert(success(t.run_project(project, "--version")) == "dotcmd " .. version .. "\n")
end)
test("CLI general help shows sorted tasks with first-line summaries", function()
    local output = success(t.run_project(child, "--help"))
    assert(output:find("Usage: .cmd <task> [args...]", 1, true), output)
    local project_section = assert(output:find("\nProject tasks:\n", 1, true), output)
    local builtin_section = assert(output:find("\nBuilt-in tasks:\n", 1, true), output)
    assert(project_section < builtin_section, output)
    assert(output:find("  --echo", 1, true) > builtin_section, output)
    assert(output:find("  --help [task...], -h, -?", 1, true) > builtin_section, output)
    assert(not output:find("\nOptions:\n", 1, true), output)
    assert(output:match("\n  deploy %[options%] <target> %[files%.%.%.%]%s+Deploy files\n"), output)
    assert(output:find("\n  empty-schema\n", 1, true), output)
    assert(output:find("\n  nothing [args...]\n", 1, true), output)
    assert(not output:find("Uploads", 1, true), output)
    assert(output:find("  args", 1, true) < output:find("  deploy", 1, true), output)
    local compact = output:gsub(" +", " ")
    assert(compact:find("\n --help [task...], -h, -? Show help for a task, or list tasks\n", 1, true), output)
    assert(not output:match("\n  %-h%s"), output)
    assert(not output:match("\n  %-%?%s"), output)
    assert(not output:match("Options:.*%-%-help"), output)
    for _, name in ipairs({ "--version", "--cache-dir", "--licenses" }) do
        local position = assert(output:find("  " .. name, 1, true), output)
        assert(position > builtin_section, output)
    end
    assert(not output:find("Arguments:", 1, true), output)
    assert(success(t.run_project(empty, "--help")):find("Built-in tasks:", 1, true))
end)
test("CLI hidden options remain accepted but do not appear in help", function()
    assert(success(t.run_project(child, "hidden-options")) == "false\n")
    assert(success(t.run_project(child, "hidden-options", "--internal")) == "true\n")
    assert(success(t.run_project(child, "--help", "hidden-options")) == "Usage: .cmd hidden-options\n")
end)
test("CLI task help shows full descriptions and schema metadata without running code", function()
    local expected = [[Usage: .cmd deploy [options] <target> [files...]

Deploy files

Uploads the selected files to the deployment target.
Existing files are replaced.

Arguments:
 target Deployment target
 files Files to deploy (file)

Options:
 --include <directory> Include directory (repeatable; default: [src, lib])
 -j, --jobs <integer> Parallel jobs (default: 4)
 --mode <debug|release> Build mode (default: release)
 --token <value> (required)
 -v, --verbose Increase verbosity (repeatable)
]]
    for _, flag in ipairs({ "--help", "-h", "-?" }) do
        local output = success(t.run_project(child, flag, "deploy"))
        assert(output:gsub(" +", " ") == expected, output)
    end
end)
test("CLI task help handles raw functions, empty schemas, and unknown tasks", function()
    assert(success(t.run_project(child, "--help", "nothing")) == "Usage: .cmd nothing [args...]\n")
    assert(success(t.run_project(child, "--help", "empty-schema")) == "Usage: .cmd empty-schema\n")
    local output = success(t.run_project(child, "--help", "args"))
    assert(output == "Usage: .cmd args [args...]\n\nPrint arguments as hex\n", output)
    assert(not failure(t.run_project(child, "--help", "unknown"), "unknown task"):find("stack traceback", 1, true))
end)
test("CLI built-in help accepts a task path", function()
    local bare = t.run_project(child)
    assert(bare.code == 2 and bare.stderr == "", bare.stderr)
    assert((bare.stdout:gsub("\r\n", "\n")) == success(t.run_project(child, "--help")))
    local output = success(t.run_project(child, "--help", "--help"))
    assert(output:find("Usage: .cmd --help [task...]\n", 1, true), output)
    assert(output:find("Task path to describe", 1, true), output)
    local result = t.run_project(child, "--help", "deploy", "extra")
    assert(result.code == 1, result.stderr)
    assert(result.stderr:find("unknown task: deploy extra", 1, true), result.stderr)
    assert(success(t.run_project(child, "-h", "--help")) == output)
    assert(success(t.run_project(child, "-?", "--help")) == output)
    assert(success(t.run_project(child, "--help", "--version")) == "Usage: .cmd --version\n\nShow dotcmd version\n")
    assert(success(t.run_project(child, "-h", "--version")) == "Usage: .cmd --version\n\nShow dotcmd version\n")
    assert(success(t.run_project(child, "help")) == "project help\n")
    assert(success(t.run_project(child, "update")) == "project update\n")
end)
test("CLI task keys use underscores and CLI names use hyphens", function()
    assert(success(t.run_project(child, "build-docs", "keep_under_scores")) == "keep_under_scores\n")
    assert(success(t.run_project(child, "already-hyphenated")) == "hyphenated\n")
    assert(success(t.run_project(child, "--echo", "--version")) == "--version\n")
    local output = success(t.run_project(child, "--help"))
    assert(output:match("\n  build%-docs <value>, docs, docs_local, %-d%s+Build documentation\n"), output)
    assert(not output:find("build_docs", 1, true), output)
    output = success(t.run_project(child, "--help", "build-docs"))
    assert(output:find("Usage: .cmd build-docs <value>\n", 1, true), output)
    failure(t.run_project(child, "build_docs"), "unknown task: build_docs")
end)
test("CLI task aliases preserve literal spellings and share argument parsing", function()
    for _, alias in ipairs({ "docs", "docs_local", "-d" }) do
        assert(success(t.run_project(child, alias, "hello")) == "hello\n")
        local result = t.run_project(child, alias)
        assert(result.code == 2, result.stderr)
        assert(result.stderr:find("missing required argument: value", 1, true), result.stderr)
        local output = success(t.run_project(child, "--help", alias))
        assert(output:find("Usage: .cmd " .. alias .. " <value>\n", 1, true), output)
        assert(output:find("Build documentation", 1, true), output)
    end
    failure(t.run_project(child, "docs-local", "hello"), "unknown task: docs-local")
    local output = success(t.run_project(child, "--help"))
    assert(not output:match("\n  docs%s"), output)
    assert(not output:match("\n  docs_local%s"), output)
    assert(not output:match("\n  %-d%s"), output)
    for _, alias in ipairs({ "-?", "-h" }) do
        output = success(t.run_project(child, "--help", alias))
        assert(output:find("Usage: .cmd " .. alias .. " [task...]\n", 1, true), output)
    end
end)
test("CLI argument boundaries and Unicode", function()
    local args = { "", "two words", "héllo", "--help", "-h", "-?", "--version", "--cache-dir",
        "--licenses", "--launcher", "--", "quote\"inside", "backslash\\",
        "line\nbreak", "$HOME", "%PATH%", "!PATH!", "&|<>^" }
    local expected = #args .. "\n"
    for _, arg in ipairs(args) do
        expected = expected .. arg:gsub(".", function(c) return ("%02x"):format(c:byte()) end) .. "\n"
    end
    assert(success(t.run_project(child, "args", table.unpack(args))) == expected)
end)
test("CLI project cwd and invocation directory", function()
    local cwd = child .. "/subdirectory"; fs.mkdir(cwd)
    local expected = normalized(child) .. "\n" .. normalized(cwd)
        .. "\n" .. host.os .. "\n" .. host.arch .. "\n"
    local launchers = { child .. "/.cmd", "../.cmd", ".././.cmd" }
    if host.os == "windows" then launchers[#launchers + 1] = "..\\.cmd" end
    for _, launcher in ipairs(launchers) do
        local actual = success(exec {
            host.executable, launcher, "context", cwd = cwd,
            stdout = "capture", stderr = "capture",
        })
        assert(normalized(actual) == expected, actual)
    end
    local actual = success(exec {
        host.executable, ".cmd", "context", cwd = child,
        stdout = "capture", stderr = "capture",
    })
    expected = normalized(child) .. "\n" .. normalized(child)
        .. "\n" .. host.os .. "\n" .. host.arch .. "\n"
    assert(normalized(actual) == expected, actual)
end)
test("CLI treats a launcher path beginning with a dash as a path", function()
    t.project("-launcher", "return {}")
    assert(success(exec {
        host.executable, "-launcher/.cmd", "--version", cwd = host.project_dir,
        stdout = "capture", stderr = "capture",
    }) == "dotcmd " .. version .. "\n")
end)
test("CLI enters the project before loading Lua and running children", function()
    local project = t.project("working directory ü", [[
assert(fs.realpath(".") == fs.realpath(host.project_dir))
assert(fs.read("marker") == "project")
fs.write("loaded", "project")
return { check = function()
    fs.write("ran", "project")
    local command = { host.executable, host.project_dir .. "/probe/.cmd", "directory" }
    for _, directory in ipairs({ host.project_dir, host.invocation_dir }) do
        local options = { command, stdout = "capture" }
        if directory == host.invocation_dir then options.cwd = directory end
        local output = exec(options).stdout:gsub("[\r\n]+$", "")
        assert(fs.realpath(output) == fs.realpath(directory))
        local process <close> = spawn(options)
        output = process:wait().stdout:gsub("[\r\n]+$", "")
        assert(fs.realpath(output) == fs.realpath(directory))
    end
end }
]])
    local caller = project .. "/caller"; fs.mkdir(caller)
    t.write(project .. "/marker", "project")
    t.write(caller .. "/marker", "caller")
    t.write(project .. "/probe/.cmd.lua", [[
return { directory = function() print(host.invocation_dir) end }
]])
    success(t.run_project(project, { cwd = caller }, "check"))
    assert(t.read(project .. "/loaded") == "project" and not fs.stat(caller .. "/loaded"))
    assert(t.read(project .. "/ran") == "project" and not fs.stat(caller .. "/ran"))
end)
test("CLI reports an unavailable project working directory", function()
    failure(t.run_project(child .. "/missing", { cwd = host.project_dir }, "--version"),
        "cannot change working directory")
end)
test("CLI explicit exit status propagation is silent", function()
    for _, code in ipairs({ 0, 1, 42, 255 }) do
        local result = t.run_project(child, "status", tostring(code))
        assert(result.code == code and result.stdout == "" and result.stderr == "", result.stderr)
    end
end)

test("API index lists runtime entries without command help", function()
    local api = require("dotcmd.api")
    for _, project in ipairs({ empty, broken, load_error }) do
        local output = success(t.run_project(project, "--api"))
        assert(output:match("^Lua API\n"), output)
        for _, section in ipairs({ "Functions:", "Runtime tables:" }) do
            assert(output:find(section, 1, true), output)
        end
        for name in pairs(api.schema.fields) do assert(output:find("  " .. name .. " ", 1, true), output) end
        local types = assert(output:find("\nType definitions:\n", 1, true), output)
        local names = {}
        for name in pairs(api.definitions) do names[#names + 1] = name end
        table.sort(names)
        local previous = types
        for _, name in ipairs(names) do
            local position = assert(output:find("\n  " .. name .. "  ", types, true), output)
            assert(position > previous, output)
            previous = position
        end
        assert(not output:find("Examples:", 1, true) and not output:find("Usage:", 1, true), output)
        assert(not output:find("---@", 1, true) and not output:find("\27", 1, true), output)
        assert(not output:find("  show ", 1, true), output)
    end
    local help = success(t.run_project(empty, "--help", "--api"))
    assert(help:find("Usage: .cmd --api [name]", 1, true), help)
    assert(help:find("Examples:\n  .cmd --api fetch\n  .cmd --api fs.stat\n  .cmd --api Task", 1, true), help)
    assert(not help:find("--luals", 1, true), help)
end)

test("API function documentation includes overloads without expanding referenced types", function()
    local output = success(t.run_project(empty, "--api", "fetch"))
    for _, text in ipairs({ "fetch(options: FetchOptions) -> string", "fetch(url: string, sha256: string) -> string",
        "Accepts (url, sha256) or an options table.",
        "Arguments (overload 1):\n  [1] options  FetchOptions\n    Pinned download and optional preparation.",
        "Arguments (overload 2):\n  [1] url  string\n  [2] sha256  string" }) do
        assert(output:find(text, 1, true), output)
    end
    assert(not output:find("\nFetchOptions\n", 1, true) and not output:find("\nPrepare\n", 1, true), output)
    assert(output:find("\nExamples:\n\nDownload and extract an archive into the prepared cache.", 1, true), output)
end)

test("API entries use concise signatures and declaration-first field rows", function()
    local stat = success(t.run_project(empty, "--api", "fs.stat"))
    assert(stat:find("fs.stat(path: string, options?: { follow?: boolean }) -> Stat|nil", 1, true), stat)
    assert(stat:find("Missing paths return nil; follow defaults to true.", 1, true), stat)
    assert(not stat:find("\nStat\n", 1, true), stat)
    local exec_docs = success(t.run_project(empty, "--api", "exec"))
    assert(exec_docs:find("exec(command: Command|ExecCommand) -> ExecResult\n"
        .. "exec(program: string, arguments...: string) -> ExecResult", 1, true), exec_docs)
    assert(exec_docs:find("exec(program: string, arguments...: string) -> ExecResult\n\n"
        .. "Executes without a shell", 1, true), exec_docs)
    assert(not exec_docs:find("\nCommand\n", 1, true), exec_docs)
    local command = success(t.run_project(empty, "--api", "Command"))
    assert(command:find("Command\nProgram or nested command", 1, true), command)
    assert(command:find("  [1] command  string|Command\n"
        .. "    Program string or inner command at index 1.", 1, true), command)
    local fields = assert(command:find("\nFields:\n", 1, true), command)
    local examples = assert(command:find("\nExamples:\n\n"
        .. "Forward all task arguments with named fields first and ... last:\n\n"
        .. "    exec { cwd = host.invocation_dir, env = env, program, ... }\n\n", 1, true), command)
    assert(examples > fields, command)
    local host_docs = success(t.run_project(empty, "--api", "host"))
    assert(host_docs:find("  arch  \"x64\"|\"arm64\"\n"
        .. "  cache_dir  string\n    Shared cache root; honors DOTCMD_CACHE_DIR.", 1, true), host_docs)
    local if_exists = success(t.run_project(empty, "--api", "IfExists"))
    assert(if_exists:find("IfExists\n\"error\"|\"skip\"|\"replace\"", 1, true), if_exists)
    local json_docs = success(t.run_project(empty, "--api", "json.encode"))
    assert(json_docs:find("json.encode(value: any, options?: JsonEncodeOptions) -> string", 1, true), json_docs)
end)

test("API dotted paths and named type definitions remain available", function()
    local fs_docs = success(t.run_project(empty, "--api", "fs"))
    assert(fs_docs:find("Fields:", 1, true) and fs_docs:find("chmod", 1, true), fs_docs)
    local task = success(t.run_project(empty, "--api", "Task"))
    assert(task:match("^Task\n"), task)
    for _, text in ipairs({ "Fields:", "run?", "opts?", "args?", "tasks?", "Option",
        "Arguments", "Tasks" }) do
        assert(task:find(text, 1, true), task)
    end
    local option = success(t.run_project(empty, "--api", "Option"))
    assert(option:find("Extends ValueSpec", 1, true), option)
    local cwd = success(t.run_project(empty, "--api", "ExecCommand.cwd"))
    assert(cwd:find("Child working directory", 1, true), cwd)
    local json = success(t.run_project(empty, "--api", "json"))
    assert(json:find("Encode and decode JSON.", 1, true) and json:find("__jsontype", 1, true), json)
end)

test("API lookup errors identify the entry and available members", function()
    for _, case in ipairs({
        { "unknown", "unknown API entry \"unknown\"", "Available entries:" },
        { "fs.stats", "unknown API member \"fs.stats\"", "Available members of fs:" },
        { "fetch.path", "API entry \"fetch\" has no declared members" },
        { "fs..stat", "unknown API member \"fs.\"", "Available members of fs:" },
        { "", "unknown API entry \"\"", "Available entries:" },
    }) do
        local result = t.run_project(empty, "--api", case[1])
        assert(result.code == 2 and result.stdout == "", result.stderr)
        assert(result.stderr:find(case[2], 1, true), result.stderr)
        if case[3] then assert(result.stderr:find(case[3], 1, true), result.stderr) end
        assert(not result.stderr:find("stack traceback", 1, true), result.stderr)
    end
    local extra = t.run_project(empty, "--api", "fetch", "extra")
    assert(extra.code == 2 and extra.stderr:find("unexpected positional argument: extra", 1, true), extra.stderr)
end)

test("API discovery follows ordinary project loading without invoking schema predicates", function()
    local project = t.project("api-project", [[
fs.write("loaded", "yes")
local api = require("dotcmd.api")
api.definitions.Sha256Options.validate = function() error("must not run") end
return {}
]])
    local output = success(t.run_project(project, "--api", "sha256"))
    assert(t.read(project .. "/loaded") == "yes")
    assert(output:find("Hash exactly one of bytes or a file path.", 1, true), output)
end)
