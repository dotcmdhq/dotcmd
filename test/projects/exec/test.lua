local child = host.project_dir .. "/child"

local function windows_drive_test(name, fn)
    if host.os ~= "windows" then return end
    test(name, function()
        local target = host.project_dir .. "/" .. name:gsub("[^%w]+", "-")
        fs.mkdir(target)
        local parent_drive = host.project_dir:match("^([A-Za-z]):")
        local drive
        for letter = string.byte("Z"), string.byte("D"), -1 do
            local candidate = string.char(letter) .. ":"
            if string.char(letter) ~= parent_drive and not fs.stat(candidate .. "/") then
                local result = exec { "subst.exe", candidate, target,
                    stdout = "capture", stderr = "capture", check = false }
                if result.code == 0 then drive = candidate; break end
            end
        end
        assert(drive, "no drive letter available for Windows path test")
        local cleanup <close> = setmetatable({}, { __close = function()
            exec { "subst.exe", drive, "/d", stdout = "discard", stderr = "discard", check = false }
        end })
        fs.mkdir(target .. "/cwd")
        fs.mkdir(target .. "/rooted")
        fn(drive .. "/cwd", target .. "/rooted")
    end)
end

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

test("exec composes arguments and environment from inner to outer", function()
    local inner = t.command(child, "env", "DOTCMD_COMPOSE_A", "DOTCMD_COMPOSE_B", "DOTCMD_COMPOSE_C")
    inner.env = { DOTCMD_COMPOSE_A = "inner", DOTCMD_COMPOSE_B = "inner", DOTCMD_COMPOSE_C = "inner",
        DOTCMD_COMPOSE_D = "inner" }
    inner.stdin, inner.stdout, inner.stderr, inner.check = "invalid", "invalid", "invalid", "invalid"
    local middle = { inner, "DOTCMD_COMPOSE_D", "DOTCMD_COMPOSE_E" }
    middle.env = { DOTCMD_COMPOSE_B = "middle", DOTCMD_COMPOSE_C = false, DOTCMD_COMPOSE_E = "middle" }
    middle.stdin, middle.stdout, middle.stderr, middle.check = "invalid", "invalid", "invalid", "invalid"
    local outer = { middle, "DOTCMD_COMPOSE_F" }
    outer.env = { DOTCMD_COMPOSE_C = "outer", DOTCMD_COMPOSE_D = false, DOTCMD_COMPOSE_F = "outer" }
    outer.stdout = "capture"
    local result = exec(outer)
    assert(result.stdout:gsub("\r\n", "\n") == "inner\nmiddle\nouter\n<missing>\nmiddle\nouter\n", result.stdout)
end)

test("exec composes environment update functions from inner to outer", function()
    local separator = host.path_sep
    local executable_dir, executable = host.executable:match("^(.*)[/\\]([^/\\]+)$")
    assert(executable_dir and executable)
    local inner = { executable, "--launcher", child .. "/.cmd", "env", "PATH",
        "DOTCMD_UPDATE_CHAIN", "DOTCMD_UPDATE_REMOVED", "DOTCMD_UPDATE_EMPTY", "DOTCMD_UPDATE_ABSENT" }
    inner.env = {
        DOTCMD_UPDATE_CHAIN = function(old)
            assert(old == nil)
            return "inner"
        end,
        DOTCMD_UPDATE_REMOVED = "inner",
        DOTCMD_UPDATE_EMPTY = "",
    }
    local middle = { inner }
    middle.env = {
        DOTCMD_UPDATE_CHAIN = function(old)
            assert(old == "inner")
            return old .. "+middle"
        end,
        DOTCMD_UPDATE_REMOVED = false,
        DOTCMD_UPDATE_EMPTY = function(old)
            assert(old == "")
        end,
    }
    local outer = { middle, stdout = "capture" }
    local path
    outer.env = {
        PATH = function(old)
            assert(type(old) == "string")
            path = executable_dir .. separator .. old
            return path
        end,
        DOTCMD_UPDATE_CHAIN = function(old)
            assert(old == "inner+middle")
            return old .. "+outer"
        end,
        DOTCMD_UPDATE_REMOVED = function(old)
            assert(old == nil)
            return "restored"
        end,
        DOTCMD_UPDATE_ABSENT = function(old)
            assert(old == nil)
            return false
        end,
    }
    local result = exec(outer)
    assert(result.stdout:gsub("\r\n", "\n") == path .. "\ninner+middle+outer\nrestored\n<missing>\n<missing>\n",
        result.stdout)
end)

test("exec rejects invalid environment update results", function()
    for _, update in ipairs({ function() return true end, function() return 17 end, function() return {} end }) do
        t.assert_error("must return a string, false, or nil", function()
            exec { child, env = { DOTCMD_UPDATE_INVALID = update } }
        end)
    end
end)

test("exec uses the outermost specified cwd across command layers", function()
    local inner_cwd = host.project_dir .. "/compose inner"; fs.mkdir(inner_cwd)
    local outer_cwd = host.project_dir .. "/compose outer"; fs.mkdir(outer_cwd)
    local inner = t.command(child, "cwd"); inner.cwd = inner_cwd
    local inherited = { inner, stdout = "capture" }
    local result = exec(inherited)
    assert(t.normalized(result.stdout:gsub("[\r\n]+$", "")) == t.normalized(inner_cwd))
    local overridden = { inherited, cwd = outer_cwd, stdout = "capture" }
    result = exec(overridden)
    assert(t.normalized(result.stdout:gsub("[\r\n]+$", "")) == t.normalized(outer_cwd))
end)

test("exec reads check only from the outermost command", function()
    local inner = t.command(child, "status", "17")
    inner.check = false; inner.stderr = "capture"
    local checked = { inner, stderr = "capture" }
    t.assert_error("child failure", function() exec(checked) end)
    local unchecked = { checked, stderr = "capture", check = false }
    local result = exec(unchecked)
    assert(result.code == 17 and result.stderr == "child failure")
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

windows_drive_test("exec resolves root-relative output on the child drive", function(cwd, rooted)
    local options = t.command(child, "emit"); options.cwd = cwd
    options.stdout = { path = "\\rooted\\out.bin" }; options.stderr = "discard"
    assert(exec(options).code == 0)
    assert(t.read(rooted .. "/out.bin") == "OUT\0\255")
end)

windows_drive_test("exec resolves a root-relative executable on the child drive", function(cwd, rooted)
    t.write(rooted .. "/dotcmd.exe", t.read(host.executable))
    local options = { "\\rooted\\dotcmd.exe", "--launcher", child .. "/.cmd", "emit", cwd = cwd,
        stdout = "capture", stderr = "capture" }
    local result = exec(options)
    assert(result.stdout == "OUT\0\255" and result.stderr == "ERR\0\254")
end)

windows_drive_test("exec resolves a root-relative PATH entry on the child drive", function(cwd, rooted)
    t.write(rooted .. "/dotcmd.exe", t.read(host.executable))
    local options = { "dotcmd", "--launcher", child .. "/.cmd", "emit", cwd = cwd,
        env = { PATH = "\\rooted" }, stdout = "capture", stderr = "capture" }
    local result = exec(options)
    assert(result.stdout == "OUT\0\255" and result.stderr == "ERR\0\254")
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
    assert(result.stderr == "child failure", result.stderr)
end)

test("exec omits its error message when merged stderr is inherited", function()
    local project = t.project("merged inherited check", ([[return {test = function()
        exec({host.executable, "--launcher", %q, "status", "17", stderr = "stdout"})
    end}]]):format(child .. "/.cmd"))
    local result = t.run_project(project, "test")
    assert(result.code == 17 and result.stdout == "child failure" and result.stderr == "", result.stderr)
end)
