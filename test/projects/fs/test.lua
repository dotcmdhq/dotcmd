test('fs metadata and missing paths', function()
    t.write('data-ü', 'abc')
    local info = fs.stat('data-ü')
    assert(info.type == 'file' and info.size == 3)
    assert(math.type(info.mode) == 'integer')
    if host.os == 'windows' then assert(info.mode == 0) end
    t.write('mode-copy', 'contents')
    fs.chmod('mode-copy', info.mode)
    assert(fs.stat('mode-copy').mode == info.mode)
    assert(fs.stat('missing') == nil)
    assert(fs.stat('.', { follow = false }).type == 'directory')
end)

test('fs realpath returns usable absolute paths for files and directories', function()
    fs.mkdir('realpath ü/child')
    t.write('realpath ü/file', 'contents')
    local path = fs.realpath('realpath ü/child/../file')
    assert(path == fs.realpath(host.cwd .. '/realpath ü/file'))
    assert(t.read(path) == 'contents')
    assert(fs.realpath(path) == path)
    assert(fs.realpath('realpath ü/child/..') == fs.realpath('realpath ü'))
    assert(fs.realpath('.') == fs.realpath(host.cwd))
    t.assert_error('fs.realpath:', function() fs.realpath('does-not-exist') end)
    t.assert_error('fs:', function() fs.realpath('') end)
    t.assert_error('fs:', function() fs.realpath('file\0ignored') end)
end)

test('fs realpath resolves relative links, link chains, and directory links', function()
    fs.mkdir('realpath-links/dir')
    t.write('realpath-links/dir/file', 'target')
    if not t.symlink('dir/file', 'realpath-links/link') then return end
    assert(t.symlink('link', 'realpath-links/chain'))
    assert(t.symlink('dir', 'realpath-links/alias', true))
    assert(t.symlink(fs.realpath('realpath-links/dir/file'), 'realpath-links/absolute'))
    local target = fs.realpath('realpath-links/dir/file')
    for _, path in ipairs({ 'link', 'chain', 'alias/file', 'absolute' }) do
        assert(fs.realpath('realpath-links/' .. path) == target)
    end
    assert(fs.stat('realpath-links/link', { follow = false }).type == 'symlink')
    assert(t.symlink('missing', 'realpath-links/broken'))
    t.assert_error('fs.realpath:', function() fs.realpath('realpath-links/broken') end)
    assert(t.symlink('cycle', 'realpath-links/cycle'))
    t.assert_error('fs.realpath:', function() fs.realpath('realpath-links/cycle') end)
end)

if host.os == 'windows' then
    test('fs realpath resolves Windows directory junctions', function()
        fs.mkdir('junction-target')
        t.write('junction-target/file', 'contents')
        exec { 'cmd.exe', '/d', '/c', 'mklink', '/J', 'junction', host.cwd .. '/junction-target',
            stdout = 'discard' }
        assert(fs.realpath('junction') == fs.realpath('junction-target'))
        assert(fs.realpath('junction/file') == fs.realpath('junction-target/file'))
    end)
end

test('fs mkdir creates parents and tolerates existing directories', function()
    fs.mkdir('nested/ü/child')
    fs.mkdir('nested/ü/child')
    assert(fs.stat('nested/ü/child').type == 'directory')
    t.write('parent-file', '')
    t.assert_error('fs.mkdir:', function() fs.mkdir('parent-file/child') end)
end)

test('fs iterator contents and cleanup on break/error', function()
    fs.mkdir('entries')
    t.write('entries/z', ''); t.write('entries/a', '')
    local names = {}
    for name in fs.list('entries') do names[#names + 1] = name end
    table.sort(names)
    assert(table.concat(names, ',') == 'a,z')
    t.assert_error('fs.list:', function() for _ in fs.list('missing') do end end)

    collectgarbage('collect'); collectgarbage('stop')
    for i = 1, 100 do
        for _ in fs.list('entries') do break end
        t.assert_error('stop iteration', function()
            for _ in fs.list('entries') do error('stop iteration') end
        end)
        fs.rename('entries', 'moved'); fs.rename('moved', 'entries')
    end
    collectgarbage('restart')
end)

test('fs file, empty-directory, and recursive removal', function()
    fs.mkdir('tree/child'); t.write('tree/child/file', 'data')
    t.assert_error('fs.remove:', function() fs.remove('tree') end)
    fs.remove('tree', { recursive = true })
    assert(fs.stat('tree') == nil)
    fs.remove('missing', { recursive = true })
    fs.mkdir('empty-dir'); fs.remove('empty-dir')
    assert(fs.stat('empty-dir') == nil)
    t.write('remove-file', 'data'); fs.remove('remove-file')
    assert(fs.stat('remove-file') == nil)
end)

test('fs rename replacement and marking a file executable', function()
    t.write('from', 'new'); t.write('to', 'old')
    fs.rename('from', 'to', { if_exists = 'replace' })
    assert(t.read('to') == 'new' and fs.stat('from') == nil)
    fs.chmod('to', "+x")
    assert(t.read('to') == 'new')
    t.assert_error('fs.rename:', function() fs.rename('missing', 'new') end)
end)

test('fs chmod accepts numeric modes and only the supported symbolic mode', function()
    t.write('chmod-file', 'contents')
    fs.chmod('chmod-file', 0x180) -- 0600
    fs.chmod('chmod-file', '+x')
    assert(t.read('chmod-file') == 'contents')
    if host.os == 'windows' then assert(fs.stat('chmod-file').mode == 0) end
    for _, mode in ipairs({ -1, 0x200, 0.5, '', '755', 'a+x', 'u+x', '+w', '+x\0' }) do
        t.assert_error('bad argument #2', function() fs.chmod('chmod-file', mode) end)
    end
end)

if host.os ~= 'windows' then
    test('fs chmod +x respects and preserves umask and existing permissions', function()
        local project = t.project('chmod', [[return {check = function(mode, expected, mask)
    local file = assert(io.open(host.project_dir .. '/file', 'wb')); assert(file:close())
    fs.chmod(host.project_dir .. '/file', tonumber(mode, 8))
    fs.chmod(host.project_dir .. '/file', '+x')
    assert(fs.stat(host.project_dir .. '/file').mode == tonumber(expected, 8))
    local after = host.project_dir .. '/after'
    fs.remove(after)
    file = assert(io.open(after, 'wb')); assert(file:close())
    assert(fs.stat(after).mode == (0x1b6 & ~tonumber(mask, 8))) -- 0666 minus umask
end}]])
        for _, case in ipairs({
            { '640', '022', '751' }, { '640', '077', '740' },
            { '640', '111', '640' }, { '651', '077', '751' },
        }) do
            t.success(exec { '/bin/sh', '-c', 'umask "$1"; shift; exec "$@"', 'chmod-test', case[2],
                host.executable, '--launcher', project .. '/.cmd', 'check', case[1], case[3], case[2],
                stdout = 'capture', stderr = 'capture' })
        end
    end)
end
