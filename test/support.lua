local t = {}

function t.read(path)
    local file <close> = assert(io.open(path, 'rb'))
    return assert(file:read('a'))
end

function t.write(path, bytes)
    local file <close> = assert(io.open(path, 'wb'))
    assert(file:write(bytes))
end

function t.normalized(path)
    return (path:gsub('\\', '/'):gsub('/%./', '/'):gsub('/+$', ''))
end

function t.command(project, args)
    local options = host.os == 'windows'
        and {'cmd.exe', '/d', '/c', 'call', project .. '/.cmd'}
        or {'/bin/sh', '-c', '"$@"', 'dotcmd-test', project .. '/.cmd'}
    for _, arg in ipairs(args or {}) do options[#options+1] = arg end
    return options
end

function t.run_project(project, args, cwd, env)
    local options = t.command(project, args)
    options.cwd = cwd or project
    options.env = env
    options.stdout = 'capture'; options.stderr = 'capture'
    options.check = false
    local code, out, err = exec(options)
    return {code=code, out=out, err=err}
end

function t.project(name, source)
    local path = host.project_dir .. '/' .. name
    fs.mkdir(path)
    t.write(path .. '/.cmd', t.read(host.project_dir .. '/.cmd'))
    fs.make_executable(path .. '/.cmd')
    if source then t.write(path .. '/.cmd.lua', source) end
    return path
end

function t.success(result)
    assert(result.code == 0, result.err .. result.out)
    assert(result.err == '', result.err)
    return (result.out:gsub('\r\n', '\n'))
end

function t.failure(result, expected)
    assert(result.code == 1, 'expected exit 1, got ' .. result.code .. '\n' .. result.out .. result.err)
    if expected then assert(result.err:find(expected, 1, true), result.err) end
    return result.err
end

local passed, failed = 0, 0
function t.assert_error(expected, fn)
    local ok, message = pcall(fn)
    assert(not ok, 'expected an error')
    assert(tostring(message):find(expected, 1, true), tostring(message))
end

function t.test(name, fn)
    local ok, message = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; print('PASS ' .. name)
    else failed = failed + 1; io.stderr:write('FAIL ' .. name .. '\n' .. message .. '\n') end
end

function t.finish()
    print(('%d passed, %d failed'):format(passed, failed))
    return failed == 0 and 0 or 1
end

return t
