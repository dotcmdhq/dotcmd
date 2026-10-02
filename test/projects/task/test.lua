local project = t.project("invocation", [[
project_loads = (project_loads or 0) + 1
local count = 0
local value = {answer = 42}
local failure = {message = "task failed", exit_code = 23}
return {
    values = function() return "hello", nil, false, value, nil end,
    capture = function()
        local results = table.pack(task("values"))
        assert(results.n == 5 and results[1] == "hello" and results[2] == nil
            and results[3] == false and results[4] == value and results[5] == nil)
        return results.n
    end,
    delegate = function() return task("values") end,
    nothing = function() end,
    output = function() print("printed"); return "returned" end,
    raw = function(...) return select("#", ...), ... end,
    counter = function() count = count + 1; return count, project_loads, session_marker end,
    composed = function() task("counter"); return task("counter") end,
    group = {
        aliases = {"g"}, opts = {jobs = {type = "integer", default = 4}, verbose = {flag = true}},
        tasks = {leaf = {
            aliases = {"l"}, args = {{"amount", type = "integer", arity = "?", default = 10}, {"optional", arity = "?"}},
            run = function(opts, amount, optional) return opts.jobs * amount, opts.verbose, optional end,
        }},
    },
    fail = function() error(failure) end,
    catch = function()
        local ok, caught = pcall(task, "fail")
        assert(not ok and caught == failure)
        return caught.exit_code
    end,
}
]])

local function evaluate(source)
    return t.run_project(project, "--eval", source)
end

local function repl(source)
    local path = project .. "/input.lua"
    t.write(path, source)
    return exec {t.command(project, "--repl"), stdin = {path = path},
        stdout = "capture", stderr = "capture", check = false}
end

test("task returns original values and nils without printing them", function()
    assert(t.success(evaluate('local values = table.pack(task("values")); return values.n, values[1], values[3], values[4].answer'))
        == '5\n"hello"\nfalse\n42\n')
    assert(t.success(evaluate('local values = table.pack(task("nothing")); return values.n')) == "0\n")
    assert(t.success(t.run_project(project, "capture")) == "5\n")
    assert(t.success(t.run_project(project, "delegate")) == t.success(t.run_project(project, "values")))
    assert(t.success(evaluate('local value = task("output"); return value')) == 'printed\n"returned"\n')
end)

test("task uses CLI aliases, nested options, conversions, defaults, and optional nils", function()
    assert(t.success(evaluate('task("g", "--jobs", "6", "l", "7")')) == "42\nfalse\nnil\n")
    assert(t.success(evaluate('task("group", "leaf", "--verbose")')) == "40\ntrue\nnil\n")
    assert(t.success(evaluate('task("raw", "--flag", "two words", "")')) == '3\n"--flag"\n"two words"\n""\n')
end)

test("task shares closures and globals without reloading the project", function()
    assert(t.success(repl('session_marker = 42\ntask("counter")\ntask("counter")\n'))
        == "1\n1\n42\n2\n1\n42\n")
    assert(t.success(t.run_project(project, "composed")) == "2\n1\nnil\n")
end)

test("task invokes built-ins with no extra results in eval and REPL", function()
    local expected = t.success(t.run_project(project, "--help", "--api"))
    assert(t.success(evaluate('task("--help", "--api")')) == expected)
    assert(t.success(repl('task("--help", "--api")\n42\n')) == expected .. "42\n")
    local documentation = t.success(evaluate('task("--api", "task")'))
    assert(documentation:find("task(arguments...: string)", 1, true), documentation)
    assert(documentation:find("without reloading .cmd.lua", 1, true), documentation)
end)

test("task propagates errors and uses CLI failure codes", function()
    assert(t.success(t.run_project(project, "catch")) == "23\n")
    local failed = evaluate('task("fail")')
    assert(failed.code == 23 and failed.stdout == "", failed.stderr)
    assert(failed.stderr:find("task failed", 1, true), failed.stderr)
    failed = evaluate('task("unknown")')
    assert(failed.code == 1 and failed.stderr:find("unknown task", 1, true), failed.stderr)
    failed = evaluate('task("group", "leaf", "invalid")')
    assert(failed.code == 2 and failed.stderr:find("expected an integer", 1, true), failed.stderr)
    local cli = t.run_project(project, "group", "leaf", "invalid")
    assert(cli.code == 2 and cli.stderr == failed.stderr:gsub("^dotcmd: ", "dotcmd "), cli.stderr)
    assert(cli.stderr:match("^dotcmd group leaf: "), cli.stderr)
    local caught = t.success(evaluate([[local ok, failure = pcall(task, "group", "leaf", "invalid")
assert(not ok and failure.exit_code == 2 and failure.message:match("^group leaf: "))
assert(failure.detail == nil and failure.path == nil and getmetatable(failure) == nil)
local fields = 0; for _ in pairs(failure) do fields = fields + 1 end
return fields]]))
    assert(caught == "2\n", caught)
    failed = evaluate('task("group")')
    assert(failed.code == 2 and failed.stderr == "" and failed.stdout:find("leaf", 1, true), failed.stdout .. failed.stderr)
    failed = evaluate('task({"raw"})')
    assert(failed.code == 1 and failed.stderr:find("must be a string", 1, true), failed.stderr)
    local result = repl('task("fail")\ntask("unknown")\ntask("group", "leaf", "invalid")\n42\n')
    assert(result.code == 0 and result.stdout:gsub("\r\n", "\n") == "42\n", result.stdout .. result.stderr)
end)

test("task keeps built-ins available when project loading fails", function()
    local broken = t.project("broken", 'error {message = "load failed", exit_code = 31}')
    local expected = t.success(t.run_project(broken, "--help", "--api"))
    assert(t.success(t.run_project(broken, "--eval", 'task("--help", "--api")')) == expected)
    local failed = t.run_project(broken, "--eval", 'task("unknown")')
    assert(failed.code == 31 and failed.stderr:find("load failed", 1, true), failed.stderr)
end)
