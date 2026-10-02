local t = {}

function t.read(path)
    local bytes = fs.read(path)
    assert(bytes, "missing file: " .. path)
    return bytes
end

t.write = fs.write

function t.normalized(path)
    return (path:gsub("\\", "/"):gsub("/%./", "/"):gsub("/+$", ""))
end

function t.symlink(target, path, directory)
    local command
    if host.os == "windows" then
        command = { "cmd.exe", "/d", "/c", "mklink" }
        if directory then command[#command + 1] = "/D" end
        command[#command + 1] = path:gsub("/", "\\")
        command[#command + 1] = target:gsub("/", "\\")
    else
        command = { "ln", "-s", target, path }
    end
    local result = exec {
        command,
        stdout = "capture",
        stderr = "capture",
        check = false,
    }
    if host.os == "windows" and result.exit_code ~= 0
        and (result.stdout .. result.stderr):lower():find("privilege", 1, true) then
        print("SKIP symlink creation requires Windows Developer Mode or privileges")
        return false
    end
    assert(result.exit_code == 0, result.stderr .. result.stdout)
    return true
end

function t.junction(target, path)
    assert(host.os == "windows")
    local result = exec {
        { "cmd.exe", "/d", "/c", "mklink", "/J", path:gsub("/", "\\"), (target:gsub("/", "\\")) },
        stdout = "capture",
        stderr = "capture",
        check = false,
    }
    assert(result.exit_code == 0, result.stderr .. result.stdout)
end

function t.command(project, ...)
    return { host.executable, project .. "/.cmd", ... }
end

function t.run_project(project, config, ...)
    local command
    if type(config) == "table" then
        command = t.command(project, ...)
    else
        command = t.command(project, config, ...)
        config = {}
    end
    return exec {
        command,
        cwd = config.cwd or project,
        env = config.env,
        stdout = "capture",
        stderr = "capture",
        check = false,
    }
end

function t.project(name, source)
    local path = host.project_dir .. "/" .. name
    fs.mkdir(path)
    t.write(path .. "/.cmd", t.read(host.project_dir .. "/.cmd"))
    fs.chmod(path .. "/.cmd", "+x")
    if source then t.write(path .. "/.cmd.lua", source) end
    return path
end

function t.success(result)
    assert(result.exit_code == 0, result.stderr .. result.stdout)
    assert(result.stderr == "", result.stderr)
    return (result.stdout:gsub("\r\n", "\n"))
end

function t.failure(result, expected)
    assert(result.exit_code == 1, "expected exit 1, got " .. result.exit_code .. "\n" .. result.stdout .. result.stderr)
    if expected then assert(result.stderr:find(expected, 1, true), result.stderr) end
    return result.stderr
end

function t.version()
    return assert(t.success(t.run_project(host.project_dir, "--version")):match("^dotcmd (.-)\n$"))
end

local passed, failed = 0, 0
function t.assert_error(expected, fn)
    local ok, message = pcall(fn)
    assert(not ok, "expected an error")
    local text = type(message) == "table" and message.message or tostring(message)
    assert(text:find(expected, 1, true), text)
    return message
end

function t.test(name, fn)
    local ok, message = xpcall(fn, debug.traceback)
    if ok then
        passed = passed + 1; print("PASS " .. name)
    else
        local text = type(message) == "table" and message.message or tostring(message)
        failed = failed + 1; io.stderr:write("FAIL " .. name .. "\n" .. text .. "\n")
    end
end

function t.finish()
    print(("%d passed, %d failed"):format(passed, failed))
    if failed > 0 then error({ exit_code = 1 }) end
end

return t
