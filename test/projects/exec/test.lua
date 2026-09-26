local child = host.project_dir .. "/child"

test("exec flushes parent output before inherited child output", function()
    local result = t.run_project(child, "ordered")
    assert(result.code == 0)
    assert(result.stdout == "before:OUT\0\255:after", ("stdout: %q"):format(result.stdout))
    assert(result.stderr == "before:ERR\0\254:after", ("stderr: %q"):format(result.stderr))
end)

test("exec captures stdout and stderr", function()
    local options = t.command(child, "emit"); options.stdout = "capture"; options.stderr = "capture"
    local result = exec(options)
    assert(result.code == 0 and result.stdout == "OUT\0\255" and result.stderr == "ERR\0\254")
end)

test("exec drains large outputs concurrently", function()
    local options = t.command(child, "large"); options.stdout = "capture"; options.stderr = "capture"
    local result = exec(options)
    assert(result.code == 0 and result.stdout == string.rep("o", 4194304) and result.stderr == string.rep("e", 4194304))
end)

test("exec merges stderr into stdout", function()
    local options = t.command(child, "emit"); options.stdout = "capture"; options.stderr = "stdout"
    local result = exec(options)
    assert(result.code == 0 and result.stderr == nil and #result.stdout == 10)
    assert(result.stdout:find("OUT\0\255", 1, true) and result.stdout:find("ERR\0\254", 1, true))
end)

test("exec discards output", function()
    local options = t.command(child, "emit"); options.stdout = "discard"; options.stderr = "discard"
    local result = exec(options)
    assert(result.code == 0 and result.stdout == nil and result.stderr == nil)
end)

test("exec inherits streams", function()
    local result = t.run_project(child, "inherit")
    assert(result.code == 0 and result.stdout == "OUT\0\255" and result.stderr == "ERR\0\254")
end)

test("exec environment overlays and removal", function()
    assert(os.getenv("USERPROFILE"))
    local options = t.command(child, "env", "PATH", "DOTCMD_TEST_SET", "USERPROFILE", "DOTCMD_TEST_EMPTY")
    options.env = { DOTCMD_TEST_SET = "new ü value", USERPROFILE = false, DOTCMD_TEST_EMPTY = "" }
    options.stdout = "capture"
    local result = exec(options)
    assert(result.code == 0 and result.stderr == nil)
    assert(result.stdout:gsub("\r\n", "\n") == os.getenv("PATH") .. "\nnew ü value\n<missing>\n\n",
        ("unexpected environment: %q"):format(result.stdout))
end)

test("exec cwd and output file redirection", function()
    local cwd = host.project_dir .. "/output"; fs.mkdir(cwd)
    local options = t.command(child, "cwd"); options.cwd = cwd; options.stdout = "capture"
    local result = exec(options)
    assert(result.code == 0 and t.normalized(result.stdout:gsub("[\r\n]+$", "")) == t.normalized(cwd))
    t.write("output/out.bin", "old long contents")
    options = t.command(child, "emit"); options.cwd = cwd
    options.stdout = { path = "out.bin" }; options.stderr = { path = "err.bin" }
    assert(exec(options).code == 0)
    assert(t.read("output/out.bin") == "OUT\0\255" and t.read("output/err.bin") == "ERR\0\254")
end)

test("exec exit codes, check, and start failures", function()
    local options = t.command(child, "status", "17"); options.stderr = "capture"; options.check = false
    local result = exec(options)
    assert(result.code == 17 and result.stdout == nil and result.stderr == "child failure")
    options.check = nil
    local err = t.assert_error("child failure", function() exec(options) end)
    assert(type(err) == "table" and err.exit_code == 17)
    assert(err.message:find("exited with code 17", 1, true))
    t.assert_error("exec:", function() exec("dotcmd-executable-that-does-not-exist") end)
    options = t.command(child, "emit"); options.cwd = "missing-directory"
    t.assert_error("exec:", function() exec(options) end)
end)

test("exec positional calls check nonzero exits by default", function()
    local project = t.project("default check", ([[return {test = function()
        exec(host.executable, "--launcher", %q, "status", "17")
    end}]]):format(child .. "/.cmd"))
    local result = t.run_project(project, "test")
    assert(result.code == 17 and result.stdout == "", result.stderr)
    assert(result.stderr:find("exec:", 1, true) and not result.stderr:find("stack traceback", 1, true), result.stderr)
end)
