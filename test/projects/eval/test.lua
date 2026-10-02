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
        assert(output == ('"function"\n"function"\n"function"\n"table"\n"%s"\n"%s"\ntrue\n'):format(host.os, host.arch), output)
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

local function edit(inputs, history, env, fail)
    local events, output, opened, closed = {}, {}, 0, 0
    for _, input in ipairs(inputs) do
        if type(input) == "number" then events[#events + 1] = {wait = input}
        else
            for index = 1, #input do events[#events + 1] = input:sub(index, index) end
            events[#events + 1] = false -- An Escape key times out before the next input.
        end
    end
    local next_event = 0
    local milliseconds, idle, idle_frames = 0, false, {}
    local terminal = {open = function()
        opened = opened + 1
        return setmetatable({
            read = function(_, timeout)
                if idle then idle_frames[#idle_frames + 1] = table.concat(output); idle = false end
                next_event = next_event + 1
                assert(next_event <= #events + 8, "editor did not stop at EOF")
                local value = events[next_event]
                if fail then error("reader failed", 0) end
                if value == false then
                    if timeout == 40 then milliseconds = milliseconds + timeout; return "" end
                    next_event = next_event + 1
                    value = events[next_event]
                end
                if type(value) == "table" then
                    milliseconds = milliseconds + value.wait
                    idle = true
                    return ""
                end
                return value
            end,
            size = function() return 24, 6 end,
            milliseconds = function() return milliseconds end,
        }, {__close = function() closed = closed + 1 end})
    end}
    local original_console, original_stdout = package.loaded["dotcmd._console"], io.stdout
    local restore <close> = setmetatable({}, {__close = function()
        package.loaded["dotcmd._console"], io.stdout = original_console, original_stdout
    end})
    package.loaded["dotcmd._console"] = terminal
    io.stdout = {write = function(self, ...)
        for index = 1, select("#", ...) do output[#output + 1] = tostring(select(index, ...)) end
        return self
    end, flush = function(self) return self end}
    local editor = require("dotcmd.readline").new()
    for _, source in ipairs(history or {}) do editor:add(source) end
    local ok, result, chunk, message = pcall(function() return editor:read(env or _ENV, require("dotcmd.eval").compile) end)
    assert(opened == 1 and closed == 1, "raw mode must close even on read errors")
    return ok, result, table.concat(output), editor, idle_frames, chunk, message
end

local function edited(keys, expected, history, env)
    local ok, result, output, editor, idle_frames, chunk, message = edit(keys, history, env)
    assert(ok and result == expected, tostring(result) .. ": expected " .. tostring(expected))
    assert(output:find("\27[?2004h", 1, true), "bracketed paste must be enabled")
    return output, editor, idle_frames, chunk, message
end

test("terminal editor moves and deletes without corrupting UTF-8", function()
    edited({"13\27[D2\r"}, "123")
    edited({"123\1\27[3~\5\127\r"}, "2")
    edited({'"hé界"\27[D\127\r'}, '"hé"')
    edited({"10 + 20\1\27[1;5C\23\r"}, " + 20")
    edited({"123\1\11\25\r"}, "123")
    edited({"123\21\25\r"}, "123")
    edited({"123\21" .. "45\127\25\r"}, "4123")
    edited({"123\21" .. "45\1\27[3~\5\25\r"}, "5123")
    edited({"123\21" .. "45\1\4\5\25\r"}, "5123")
    edited({"123\21\127\25\r"}, "123")
end)

test("terminal history preserves drafts and edits copies of whole chunks", function()
    edited({"draft\16\14\r"}, "draft", {"41", "42"})
    edited({"\16\16\5\1272\r"}, "42", {"41", "99"})
    local output, editor = edited({"\16\r"}, "function f(x)\nreturn x * 2\nend",
        {"function f(x)\nreturn x * 2\nend"})
    assert(editor.history[1] == "function f(x)\nreturn x * 2\nend")
    assert(output:find(">> ", 1, true), output)
    assert(#require("dotcmd.readline").new().history == 0)
    for index = 1, 205 do editor:add(tostring(index)) end
    assert(#editor.history == 200 and editor.history[1] == "6")
    editor:add("205")
    assert(#editor.history == 200)
end)

test("terminal search browses history and can restore the draft", function()
    edited({"\18alpha\18\r\r"}, "alpha = 1", {"alpha = 1", "beta = 2", "alpha = 3"})
    edited({"draft\18alpha\7\r"}, "draft", {"alpha = 1"})
    edited({"\18" .. "2\r\16\r"}, "1", {"1", "2", "3"})
    edited({"\18" .. "2\r\14\r"}, "3", {"1", "2", "3"})
    edited({"draft\18" .. "2\r\14\14\r"}, "draft", {"1", "2", "3"})
    edited({"\18" .. "2\27[D\16\r"}, "1", {"1", "2", "3"})
end)

test("terminal search fits its header and positions the cursor by display width", function()
    for _, case in ipairs {
        {query = string.rep("a", 14), header = "(reverse-search: aaaaa)", column = 22},
        {query = "界", header = "(reverse-search: 界)", column = 19},
        {query = "e\u{301}", header = "(reverse-search: e\u{301})", column = 18},
        {query = "a\nb", input = "\27[200~a\nb\27[201~", header = "(reverse-search: a b)", column = 20},
    } do
        local _, _, frames = edited({"42\18" .. (case.input or case.query), 100, "\7\r"}, "42", {case.query})
        local frame = frames[1]
        assert(frame:match(".*\27%[J([^\r\n]*)") == case.header, frame)
        assert(frame:sub(-#("\27[" .. case.column .. "C")) == "\27[" .. case.column .. "C", frame)
    end
end)

test("terminal Enter continues incomplete Lua and allows editing earlier lines", function()
    edited({"function f()\rreturn 41\rend\27[A\5\1272\27[B\r"}, "function f()\nreturn 42\nend")
    edited({"{\ra = 1\r}\r"}, "{\na = 1\n}")
    local _, _, _, chunk = edited({"40 + 2\r"}, "40 + 2")
    assert(chunk() == 42)
    local _, _, _, invalid, message = edited({"local =\r"}, "local =")
    assert(invalid == nil and message:find("repl:1:", 1, true), message)
end)

test("terminal completion uses globals and table members without evaluating expressions", function()
    local env = {print = print, host = {project_dir = "/project", os = "macos"}}
    edited({"hos\9.os\r"}, "host.os", nil, env)
    edited({"host.pro\9\r"}, "host.project_dir", nil, env)
    edited({'"hos\9"\r'}, '"hos"', nil, env)
    edited({"-- hos\9\r"}, "-- hos", nil, env)
    local output = edited({"host.\9\9os\r"}, "host.os", nil, env)
    assert(output:find("os  project_dir", 1, true), output)
end)

test("terminal bracketed paste never executes its embedded newlines", function()
    edited({"\27[200~x = 1\r\nx = x + 1\27[201~\r"}, "x = 1\nx = x + 1")
    edited({"\27[200~return '\27[31m'\27[201~\r"}, "return '[31m'")
end)

test("terminal cancellation and EOF close raw mode", function()
    edited({"function unfinished()\r\3"}, false)
    edited({"\3"}, nil)
    edited({"\4"}, nil)
    edited({"123\1\4\r"}, "23")
    edited({}, nil)
    edited({"123"}, nil)
    edited({"123\1"}, nil)
    edited({"123\18"}, nil)
    edited({"\195"}, nil)
    edited({"\27[200~x = 1"}, nil)
    local ok, message = edit({}, nil, nil, true)
    assert(not ok and message == "reader failed", tostring(message))
end)

test("terminal highlights matching brackets while ignoring strings and comments", function()
    if os.getenv("NO_COLOR") == nil then
        local output = edited({"(1)\r"}, "(1)")
        assert(output:find("\27[7m(\27[0m", 1, true), output)
        assert(output:match('.*\27%[J(.*)$') == "> (1)\r\27[5C\n", output)
        output = edited({"(1)\3"}, false)
        assert(output:match('.*\27%[J(.*)$') == "> (1)\r\27[5C^C\n", output)
        output = edited({'"(1)"\r'}, '"(1)"')
        assert(not output:find("\27[7m", 1, true), output)
        output = edited({"-- (1)\r"}, "-- (1)")
        assert(not output:find("\27[7m", 1, true), output)
        output = edited({"[=[(1)]=]\r"}, "[=[(1)]=]")
        assert(not output:find("\27[7m", 1, true), output)
        local _, _, frames = edited({"(1)", 500, "\r"}, "(1)")
        assert(frames[1]:match('.*\27%[J(.*)$') == "> (1)\r\27[5C", frames[1])
    end
end)
