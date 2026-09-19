---@type dotcmd.Env|_G
local _ENV = _ENV

local tar = assert(loadfile(host.project_dir .. '/tar.lua'))()
local function fixture(name, entries)
    t.write(name .. '.tar', tar(entries))
    return name .. '.tar'
end
local function fails(path, options)
    options = options or {}; options.path = path; options.to = options.to or 'failed'
    t.assert_error('extract:', function() extract(options) end)
    assert(fs.stat(options.to, { follow = false }) == nil)
    for name in fs.list('.') do assert(not name:find('.extract-', 1, true), name) end
end

for _, format in ipairs({ 'tar', 'tar.gz', 'tar.xz', 'zip' }) do
    test('extract ' .. format .. ' by contents, including Unicode', function()
        local path = 'sdk-' .. format .. '.bin'
        t.write(path, t.read('fixtures/sdk.' .. format))
        assert(extract { path = path, to = 'out-' .. format } == true)
        assert(t.read('out-' .. format .. '/sdk/lib/value') == 'library')
        assert(t.read('out-' .. format .. '/sdk/share/ü.txt') == 'unicode')
        assert(t.read('out-' .. format .. '/sdk/share/large') == string.rep('\0', 65536))
        if host.os ~= 'windows' then
            local code, out = exec { './out-' .. format .. '/sdk/bin/run', stdout = 'capture' }
            assert(code == 0 and out == 'sdk works\n')
        end
    end)
end

test('extract defaults to a sibling directory in both forms', function()
    fs.mkdir('downloads')
    t.write('downloads/sdk.zip', t.read('fixtures/sdk.zip'))
    extract('downloads/sdk.zip')
    assert(t.read('downloads/sdk/sdk/lib/value') == 'library')
    t.write('downloads/tool.tar.xz', t.read('fixtures/sdk.tar.xz'))
    extract { path = 'downloads/tool.tar.xz' }
    assert(t.read('downloads/tool/sdk/lib/value') == 'library')
    t.write('downloads/unknown', t.read('fixtures/sdk.tar'))
    extract('downloads/unknown')
    assert(t.read('downloads/unknown.unpacked/sdk/lib/value') == 'library')
end)

test('extract selects exact paths and subtrees before stripping', function()
    extract { path = 'fixtures/sdk.tar.gz', to = 'selected', strip_components = 1, include = { 'sdk/bin/', './sdk/lib/value' } }
    assert(t.read('selected/lib/value') == 'library')
    assert(fs.stat('selected/bin/run').type == 'file')
    assert(fs.stat('selected/share') == nil)
    fails('fixtures/sdk.zip', { include = { 'bin' } })
    fails('fixtures/sdk.zip', { include = { 'sdk/lib', 'missing' } })
    fails(fixture('prefix', { { name = 'sdk/library/file', data = 'no' } }), { include = { 'sdk/lib' } })
end)

test('extract strips components and skips exhausted paths', function()
    extract { path = 'fixtures/sdk.tar', to = 'stripped', strip_components = 2 }
    assert(t.read('stripped/value') == 'library' and t.read('stripped/ü.txt') == 'unicode')
    extract { path = 'fixtures/sdk.tar', to = 'all-skipped', strip_components = 100 }
    for _ in fs.list('all-skipped') do error('expected an empty directory') end
end)

test('extract refuses existing destinations and missing parents', function()
    fs.mkdir('existing'); t.write('existing/keep', 'unchanged')
    t.assert_error('destination already exists', function() extract { path = 'fixtures/sdk.zip', to = 'existing' } end)
    assert(t.read('existing/keep') == 'unchanged')
    t.write('existing-file', 'unchanged')
    t.assert_error('destination already exists', function() extract { path = 'fixtures/sdk.zip', to = 'existing-file' } end)
    assert(t.read('existing-file') == 'unchanged')
    fails('fixtures/sdk.zip', { to = 'absent/child' })
    assert(fs.stat('absent') == nil)
end)

test('extract cleans up malformed archives and validates options', function()
    t.write('garbage', 'not an archive'); fails('garbage')
    t.write('truncated.tar.gz', t.read('fixtures/sdk.tar.gz'):sub(1, 40)); fails('truncated.tar.gz')
    local zip = t.read('fixtures/sdk.zip')
    local data = assert(zip:find('#!/bin/sh', 1, true))
    t.write('bad-crc.zip', zip:sub(1, data - 1) .. '!' .. zip:sub(data + 1))
    fails('bad-crc.zip')
    fails('missing.tar')
    fails('fixtures/sdk.zip', { strip_components = -1 })
    fails('fixtures/sdk.zip', { include = {} })
    fails('fixtures/sdk.zip', { include = { other = 'sdk' } })
    t.assert_error('extract:', function() extract { path = 'bad\0name' } end)
end)

test('extract rejects traversal even when stripping or selecting', function()
    t.write('sentinel', 'unchanged')
    for _, name in ipairs({ '../sentinel', '/absolute', 'C:/absolute', 'sdk/../../sentinel', 'sdk\\..\\sentinel' }) do
        local path = fixture('unsafe', { { name = name, data = 'bad' } })
        fails(path); fails(path, { strip_components = 1 }); fails(path, { include = { 'missing' } })
        assert(t.read('sentinel') == 'unchanged')
    end
end)

test('extract rejects duplicate outputs and special files', function()
    fails(fixture('duplicates', { { name = 'a/file', data = 'one' }, { name = 'b/file', data = 'two' } }),
        { strip_components = 1 })
    fails(fixture('special', { { name = 'pipe', type = '6' } }))
    if host.os == 'windows' then
        fails(fixture('case-alias', { { name = 'file', data = 'one' }, { name = 'FILE', data = 'two' } }))
        for _, name in ipairs({ 'CON', 'file:stream', 'file.', 'NUL.txt' }) do
            fails(fixture('windows-name', { { name = name, data = 'bad' } }))
        end
    end
end)

test('extract preserves forward hardlinks and rejects missing targets', function()
    extract { path = fixture('hard', { { name = 'sdk/alias', type = '1', link = 'sdk/file' }, { name = 'sdk/file', data = 'contents' } }), strip_components = 1 }
    assert(t.read('hard/alias') == 'contents' and t.read('hard/file') == 'contents')
    t.write('hard/file', 'changed'); assert(t.read('hard/alias') == 'changed')
    fails('hard.tar', { strip_components = 1, include = { 'sdk/alias' } })
    fails(fixture('hard-cycle', { { name = 'a', type = '1', link = 'b' }, { name = 'b', type = '1', link = 'a' } }))
end)

test('extract preserves internal symlinks and rejects unsafe link graphs', function()
    local path = fixture('links', {
        { name = 'sdk/link',  type = '2', link = 'file' }, { name = 'sdk/file', data = 'contents' },
        { name = 'sdk/alias', type = '2', link = 'link' },
        { name = 'sdk/dirlink', type = '2', link = 'dir' }, { name = 'sdk/dir/file', data = 'nested' },
    })
    local ok, message = pcall(function() extract { path = path, strip_components = 1 } end)
    if not ok and host.os == 'windows' then
        -- Windows may deny symlink creation without Developer Mode/privileges.
        local error = tostring(message):lower()
        assert(error:find('privilege', 1, true) or error:find('not permitted', 1, true)
            or error:find('permission denied', 1, true), tostring(message))
        assert(fs.stat('links') == nil)
    else
        assert(ok, message)
        assert(fs.stat('links/link', { follow = false }).type == 'symlink')
        assert(t.read('links/link') == 'contents')
        assert(t.read('links/alias') == 'contents')
        assert(fs.stat('links/dirlink').type == 'directory' and t.read('links/dirlink/file') == 'nested')
    end
    fails(path, { strip_components = 1, include = { 'sdk/link' } })
    fails(fixture('escape-link', { { name = 'link', type = '2', link = '../sentinel' } }))
    fails(fixture('absolute-link', { { name = 'link', type = '2', link = '/tmp' } }))
    fails(fixture('link-cycle', { { name = 'a', type = '2', link = 'b' }, { name = 'b', type = '2', link = 'a' } }))
    fails(fixture('write-through-link', { { name = 'dir', type = '2', link = '.' }, { name = 'dir/file', data = 'bad' } }))
    fails(fixture('indirect-escape', {
        { name = 'deep',      type = '5' },
        { name = 'link',      type = '2', link = '.' },
        { name = 'deep/escape', type = '2', link = '../link/../sentinel' },
    }))
    assert(t.read('sentinel') == 'unchanged')
end)

test('extract leaves the caller cwd and locale unchanged', function()
    local locale = os.setlocale(nil, 'ctype')
    local cwd = host.cwd
    extract { path = 'fixtures/sdk.zip', to = 'trailing-slash/' }
    assert(os.setlocale(nil, 'ctype') == locale and host.cwd == cwd)
    assert(t.read('trailing-slash/sdk/lib/value') == 'library')
end)
