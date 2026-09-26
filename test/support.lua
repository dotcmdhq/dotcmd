local t = {}

function t.read(path)
    local file <close> = assert(io.open(path, "rb"))
    return assert(file:read("a"))
end

function t.write(path, bytes)
    local file <close> = assert(io.open(path, "wb"))
    assert(file:write(bytes))
end

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
    command.stdout, command.stderr = "capture", "capture"
    command.check = false
    local result = exec(command)
    if host.os == "windows" and result.code ~= 0
        and (result.stdout .. result.stderr):lower():find("privilege", 1, true) then
        print("SKIP symlink creation requires Windows Developer Mode or privileges")
        return false
    end
    assert(result.code == 0, result.stderr .. result.stdout)
    return true
end

function t.command(project, ...)
    return { host.executable, "--launcher", project .. "/.cmd", ... }
end

function t.run_project(project, config, ...)
    local options
    if type(config) == "table" then
        options = t.command(project, ...)
    else
        options = t.command(project, config, ...)
        config = {}
    end
    options.cwd = config.cwd or project
    options.env = config.env
    options.stdout = "capture"; options.stderr = "capture"
    options.check = false
    return exec(options)
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
    assert(result.code == 0, result.stderr .. result.stdout)
    assert(result.stderr == "", result.stderr)
    return (result.stdout:gsub("\r\n", "\n"))
end

function t.failure(result, expected)
    assert(result.code == 1, "expected exit 1, got " .. result.code .. "\n" .. result.stdout .. result.stderr)
    if expected then assert(result.stderr:find(expected, 1, true), result.stderr) end
    return result.stderr
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
