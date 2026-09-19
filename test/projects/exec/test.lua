local child = host.project_dir .. '/child'
local function command(name, ...)
    return t.command(child, {name, ...})
end

test('exec captures stdout and stderr', function()
    local options = command('emit'); options.stdout = 'capture'; options.stderr = 'capture'
    local code, out, err = exec(options)
    assert(code == 0 and out == 'OUT\0\255' and err == 'ERR\0\254')
end)

test('exec drains large outputs concurrently', function()
    local options = command('large'); options.stdout = 'capture'; options.stderr = 'capture'
    local code, out, err = exec(options)
    assert(code == 0 and out == string.rep('o', 4194304) and err == string.rep('e', 4194304))
end)

test('exec merges stderr into stdout', function()
    local options = command('emit'); options.stdout = 'capture'; options.stderr = 'stdout'
    local code, out, err = exec(options)
    assert(code == 0 and err == nil and #out == 10)
    assert(out:find('OUT\0\255', 1, true) and out:find('ERR\0\254', 1, true))
end)

test('exec discards output', function()
    local options = command('emit'); options.stdout = 'discard'; options.stderr = 'discard'
    local code, out, err = exec(options)
    assert(code == 0 and out == nil and err == nil)
end)

test('exec inherits streams', function()
    local result = t.run_project(child, {'inherit'})
    assert(result.code == 0 and result.out == 'OUT\0\255' and result.err == 'ERR\0\254')
end)

test('exec environment overlays and removal', function()
    assert(os.getenv('USERPROFILE'))
    local options = command('env', 'PATH', 'DOTCMD_TEST_SET', 'USERPROFILE', 'DOTCMD_TEST_EMPTY')
    options.env = {DOTCMD_TEST_SET='new ü value', USERPROFILE=false, DOTCMD_TEST_EMPTY=''}
    options.stdout = 'capture'
    local code, out = exec(options)
    assert(code == 0)
    assert(out:gsub('\r\n', '\n') == os.getenv('PATH') .. '\nnew ü value\n<missing>\n\n',
        ('unexpected environment: %q'):format(out))
end)

test('exec cwd and output file redirection', function()
    local cwd = host.project_dir .. '/output'; fs.mkdir(cwd)
    local options = command('cwd'); options.cwd = cwd; options.stdout = 'capture'
    local code, out = exec(options)
    assert(code == 0 and t.normalized(out:gsub('[\r\n]+$', '')) == t.normalized(cwd))
    t.write('output/out.bin', 'old long contents')
    options = command('emit'); options.cwd = cwd
    options.stdout = {path='out.bin'}; options.stderr = {path='err.bin'}
    assert(exec(options) == 0)
    assert(t.read('output/out.bin') == 'OUT\0\255' and t.read('output/err.bin') == 'ERR\0\254')
end)

test('exec exit codes, check, and start failures', function()
    local options = command('status', '17'); options.stderr = 'capture'; options.check = false
    assert(exec(options) == 17)
    options.check = true
    t.assert_error('child failure', function() exec(options) end)
    t.assert_error('exec:', function() exec('dotcmd-executable-that-does-not-exist') end)
    options = command('emit'); options.cwd = 'missing-directory'
    t.assert_error('exec:', function() exec(options) end)
end)
