---@type dotcmd.Env|_G
local _ENV = _ENV

local child = host.project_dir .. '/child'

test('spawn flushes parent output before inherited child output', function()
    local result = t.run_project(child, 'ordered')
    assert(result.code == 0)
    assert(result.stdout == 'before:OUT\0\255:after', ('stdout: %q'):format(result.stdout))
    assert(result.stderr == 'before:ERR\0\254:after', ('stderr: %q'):format(result.stderr))
end)

test('spawn accepts both argument forms and inherits streams', function()
    local first <close> = spawn(t.command(child, 'noop'))
    local second <close> = spawn(table.unpack(t.command(child, 'noop')))
    assert(first:wait().code == 0 and second:wait().code == 0)
    assert(first.stdin == nil and first.stdout == nil and first.stderr == nil)
end)

test('spawn returns before exit and exposes blocking Lua pipe handles', function()
    local options = t.command(child, 'hold'); options.stdin = 'pipe'; options.stdout = 'pipe'
    local process <close> = spawn(options)
    assert(io.type(process.stdin) == 'file' and io.type(process.stdout) == 'file')
    assert(process.stdout:read('l'):gsub('\r$', '') == 'ready')
    assert(process:poll() == nil)
    assert(process.stdin:write('continue\n')); assert(process.stdin:flush())
    local result = process:wait { check = true }
    assert(result.code == 0 and result.stdout == nil and result.stderr == nil)
    assert(process:wait() == result and process:poll() == result)
end)

test('spawn pipes binary stdin and sends EOF on close', function()
    local options = t.command(child, 'echo'); options.stdin = 'pipe'; options.stdout = 'pipe'
    local process <close> = spawn(options)
    assert(process.stdin:write('input\0\255')); assert(process.stdin:close())
    assert(process.stdout:read('a') == 'input\0\255')
    assert(process:wait { check = true }.code == 0)
end)

test('spawn exposes stderr separately and can merge it into stdout', function()
    local options = t.command(child, 'emit'); options.stdout = 'pipe'; options.stderr = 'pipe'
    local process <close> = spawn(options)
    assert(process.stdout:read('a') == 'OUT\0\255')
    assert(process.stderr:read('a') == 'ERR\0\254')
    assert(process:wait().code == 0)
    options.stderr = 'stdout'
    local merged <close> = spawn(options)
    assert(merged.stderr == nil)
    local bytes = merged.stdout:read('a')
    assert(#bytes == 10 and bytes:find('OUT\0\255', 1, true) and bytes:find('ERR\0\254', 1, true))
    assert(merged:wait().code == 0)
end)

test('spawn drains captured output while Lua is reading another pipe', function()
    local options = t.command(child, 'capture_then_signal')
    options.stdin = 'pipe'; options.stdout = 'capture'; options.stderr = 'pipe'
    local process <close> = spawn(options)
    assert(process.stderr:read('l'):gsub('\r$', '') == 'ready')
    assert(process:poll() == nil)
    process.stdin:close()
    local result = process:wait { check = true }
    assert(result.stdout == string.rep('o', 4194304) and result.stderr == nil)
end)

test('spawn captures large stdout and stderr concurrently', function()
    local options = t.command(child, 'large'); options.stdout = 'capture'; options.stderr = 'capture'
    local process <close> = spawn(options)
    assert(process.stdout == nil and process.stderr == nil)
    local result = process:wait { check = true }
    assert(result.stdout == string.rep('o', 4194304) and result.stderr == string.rep('e', 4194304))
end)

test('spawn poll eventually returns the completed capture', function()
    local options = t.command(child, 'emit'); options.stdout = 'capture'; options.stderr = 'capture'
    local process <close> = spawn(options)
    local result
    local deadline = os.time() + 10
    repeat result = process:poll() until result or os.time() >= deadline
    assert(result and result.code == 0)
    assert(result.stdout == 'OUT\0\255' and result.stderr == 'ERR\0\254')
    assert(process:wait() == result)
end)

test('spawn uses child cwd for input and output files', function()
    local cwd = host.project_dir .. '/files ü'; fs.mkdir(cwd)
    t.write(cwd .. '/in.bin', 'input\0\255')
    t.write(cwd .. '/out.bin', 'old contents to replace')
    local options = t.command(child, 'echo'); options.cwd = cwd
    options.stdin = { path = 'in.bin' }; options.stdout = { path = 'out.bin' }; options.stderr = 'discard'
    local process <close> = spawn(options)
    assert(process:wait().code == 0)
    assert(t.read(cwd .. '/out.bin') == 'input\0\255')
end)

test('spawn discards input and output', function()
    local options = t.command(child, 'echo'); options.stdin = 'discard'; options.stdout = 'capture'
    local input <close> = spawn(options)
    assert(input:wait().stdout == '')
    options = t.command(child, 'emit'); options.stdout = 'discard'; options.stderr = 'discard'
    local output <close> = spawn(options)
    local result = output:wait()
    assert(result.code == 0 and result.stdout == nil and result.stderr == nil)
end)

test('spawn preserves arguments, cwd, and environment overrides', function()
    local cwd = host.project_dir .. '/cwd'; fs.mkdir(cwd)
    local options = t.command(child, 'context', 'two words', 'ü', '')
    options.cwd = cwd; options.env = { DOTCMD_SPAWN_SET = 'value ü', USERPROFILE = false }
    options.stdout = 'capture'
    local process <close> = spawn(options)
    local output = process:wait { check = true }.stdout:gsub('\r\n', '\n')
    local directory, rest = output:match('([^\n]+)\n(.*)')
    assert(t.normalized(directory) == t.normalized(cwd))
    assert(rest == 'value ü\n<missing>\ntwo words\0ü\0\0')
end)

test('spawn checks exit status only when wait requests it', function()
    local options = t.command(child, 'status'); options.stderr = 'capture'
    local process <close> = spawn(options)
    local result = process:wait()
    assert(result.code == 17 and result.stderr == 'child failure')
    assert(process:poll() == result)
    t.assert_error('child failure', function() process:wait { check = true } end)
    assert(process:wait { check = false } == result)
    process:close(); process:close(); process:kill()
    assert(process:wait() == result)
end)

test('spawn kill stops the direct child and can be repeated', function()
    local options = t.command(child, 'hold'); options.stdin = 'pipe'; options.stdout = 'pipe'
    local process <close> = spawn(options)
    assert(process.stdout:read('l'):gsub('\r$', '') == 'ready')
    process:kill(); process:kill()
    -- On Windows the launcher is a child of cmd.exe; release its input too.
    process.stdin:close()
    assert(process:wait().code ~= 0)
    process:kill()
end)

test('spawn close stops the child and closes exposed files', function()
    local options = t.command(child, 'hold'); options.stdin = 'pipe'; options.stdout = 'pipe'
    local process = spawn(options)
    assert(process.stdout:read('l'):gsub('\r$', '') == 'ready')
    process:close(); process:close()
    assert(process:wait().code ~= 0)
    assert(io.type(process.stdin) == 'closed file' and io.type(process.stdout) == 'closed file')
end)

test('spawn close stops capture readers as well as the child', function()
    local options = t.command(child, 'capture_then_signal')
    options.stdin = 'pipe'; options.stdout = 'capture'; options.stderr = 'pipe'
    local process <close> = spawn(options)
    assert(process.stderr:read('l'):gsub('\r$', '') == 'ready')
    process:close()
    local result = process:poll()
    assert(result.code ~= 0 and type(result.stdout) == 'string')
    assert(io.type(process.stdin) == 'closed file' and io.type(process.stderr) == 'closed file')
end)

test('spawn closes on Lua errors and garbage collection', function()
    local options = t.command(child, 'hold'); options.stdin = 'pipe'; options.stdout = 'pipe'
    local process
    t.assert_error('intentional failure', function()
        local running <close> = spawn(options)
        process = running
        assert(running.stdout:read('l'):gsub('\r$', '') == 'ready')
        error('intentional failure')
    end)
    assert(process:poll().code ~= 0 and io.type(process.stdin) == 'closed file')
    process = spawn(options)
    assert(process.stdout:read('l'):gsub('\r$', '') == 'ready')
    local input = process.stdin
    process = nil
    collectgarbage('collect')
    assert(io.type(input) == 'closed file')
end)

test('spawn pipes do not leak into later children', function()
    local options = t.command(child, 'echo'); options.stdin = 'pipe'; options.stdout = 'capture'
    local first <close> = spawn(options)
    options = t.command(child, 'hold'); options.stdin = 'pipe'; options.stdout = 'pipe'
    local second <close> = spawn(options)
    assert(second.stdout:read('l'):gsub('\r$', '') == 'ready')
    first.stdin:close()
    assert(first:wait().stdout == '')
    assert(second:poll() == nil)
    second.stdin:close()
    assert(second:wait().code == 0)
end)

test('spawn returns an I/O error for writes after the child exits', function()
    local options = t.command(child, 'noop'); options.stdin = 'pipe'
    local process <close> = spawn(options)
    assert(process:wait().code == 0)
    local ok, message = process.stdin:write('after exit')
    assert(ok == nil and type(message) == 'string')
end)

test('spawn reports startup and redirection errors immediately', function()
    t.assert_error('exec:', function() spawn('dotcmd-executable-that-does-not-exist') end)
    local options = t.command(child, 'noop'); options.cwd = 'missing-directory'
    t.assert_error('exec:', function() spawn(options) end)
    options = t.command(child, 'noop'); options.stdin = { path = 'missing-input' }
    t.assert_error('exec:', function() spawn(options) end)
end)
