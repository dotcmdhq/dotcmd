local empty = t.project("empty")
local broken = t.project("broken", "this is not valid Lua!")
local failed = t.project("failed", "error('project failed')")

local function repl(project, source)
    local path = project .. "/input.lua"
    t.write(path, source)
    return exec {
        t.command(project, "--repl"), cwd = project,
        stdin = { path = path }, stdout = "capture", stderr = "capture", check = false,
    }
end

test("eval and task returns share formatting and preserve nil values", function()
    local expression = '{z = 2, a = {true, "text"}}, nil, false, nil'
    local project = t.project("printing", "return { values = function() return " .. expression .. " end }")
    local expected = t.success(t.run_project(project, "values"))
    assert(t.success(t.run_project(project, "--eval", expression)) == expected)
    assert(expected:find("\nnil\nfalse\nnil\n", 1, true), expected)
end)

test("eval accepts chunks and keeps explicit Lua print behavior", function()
    assert(t.success(t.run_project(empty, "--eval", "local x = 40; return x + 2")) == "42\n")
    assert(t.success(t.run_project(empty, "--eval", "print('hello', 42)")) == "hello\t42\n")
    assert(t.success(t.run_project(empty, "--eval", "assigned = 42")) == "")
end)

test("eval has task globals and works without a valid project", function()
    for _, project in ipairs { empty, broken, failed } do
        local output = t.success(t.run_project(project, "--eval",
            "type(fetch), type(plugin), type(exec), type(fs), host.os, host.arch, fs.realpath('.') == fs.realpath(host.project_dir)"))
        assert(output == "function\nfunction\nfunction\ntable\n" .. host.os .. "\n" .. host.arch .. "\ntrue\n", output)
    end
end)

test("eval propagates syntax errors and structured exit codes", function()
    t.failure(t.run_project(empty, "--eval", "local ="), "eval:1:")
    local result = t.run_project(empty, "--eval", "error {message = 'evaluation failed', exit_code = 23}")
    assert(result.code == 23 and result.stdout == "", result.stderr)
    assert(result.stderr:gsub("\r\n", "\n") == "dotcmd: evaluation failed\n", result.stderr)
end)

test("eval and repl validate arguments and advertise usage", function()
    for _, argv in ipairs { { "--eval" }, { "--eval", "1", "2" }, { "--repl", "extra" } } do
        local result = t.run_project(empty, table.unpack(argv))
        assert(result.code == 2 and result.stdout == "", result.stderr)
    end
    local help = t.success(t.run_project(empty, "--help"))
    assert(help:find("--eval <code>", 1, true) and help:find("--repl", 1, true), help)
end)

test("repl retains globals and uses task formatting without pipe prompts", function()
    for _, project in ipairs { empty, broken, failed } do
        assert(t.success(repl(project, "counter = 40\ncounter + 2\nreturn nil, false, nil\nprint('hello')\n"))
            == "42\nnil\nfalse\nnil\nhello\n")
    end
end)

test("repl compiles multiline statements and expressions", function()
    local result = repl(empty, "function twice(x)\nreturn x * 2\nend\ntwice(21)\n{\na = 1,\nb = {2}\n}\n")
    local expected = "42\n" .. t.success(t.run_project(empty, "--eval", "{a = 1, b = {2}}"))
    assert(t.success(result) == expected, result.stdout .. result.stderr)
end)

test("repl recovers from syntax and runtime errors", function()
    local result = repl(empty, "local =\nerror('oops', 0)\nerror {message = 'structured', exit_code = 9}\n6 * 7\n")
    assert(result.code == 0 and result.stdout:gsub("\r\n", "\n") == "42\n", result.stdout .. result.stderr)
    for _, text in ipairs { "repl:1:", "dotcmd: oops", "dotcmd: structured" } do
        assert(result.stderr:find(text, 1, true), result.stderr)
    end
    assert(not result.stderr:find("stack traceback", 1, true), result.stderr)
end)

test("repl reports incomplete input at EOF", function()
    local result = repl(empty, "if true then\n")
    assert(result.code == 0 and result.stdout == "", result.stdout .. result.stderr)
    assert(result.stderr:find("<eof>", 1, true), result.stderr)
end)
