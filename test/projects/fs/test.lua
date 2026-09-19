---@type dotcmd.Env|_G
local _ENV = _ENV

test('fs metadata and missing paths', function()
    t.write('data-ü', 'abc')
    local info = fs.stat('data-ü')
    assert(info.type == 'file' and info.size == 3)
    assert(fs.stat('missing') == nil)
    assert(fs.stat('.', { follow = false }).type == 'directory')
end)

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
    fs.make_executable('to')
    assert(t.read('to') == 'new')
    t.assert_error('fs.rename:', function() fs.rename('missing', 'new') end)
end)
