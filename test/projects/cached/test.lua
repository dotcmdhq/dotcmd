---@type dotcmd.Env|_G
local _ENV = _ENV

local function seed(bytes, name)
    local hash = sha256(bytes)
    local directory = host.cache_dir .. '/downloads/' .. hash
    fs.mkdir(directory)
    local path = directory .. '/' .. name
    t.write(path, bytes)
    return path, hash
end
local archive = t.read('sdk.zip')
local url = assert(os.getenv('DOTCMD_TEST_URL'))

test('cached downloads, verifies, and reuses a file', function()
    local bytes = 'hello\0\255world'
    local path = cached { url = url .. '/body', sha256 = sha256(bytes), name = 'fresh.bin' }
    assert(t.read(path) == bytes)
    t.write(path, 'trusted after download')
    assert(cached { url = url .. '/status/500', sha256 = sha256(bytes), name = 'fresh.bin' } == path)
    assert(t.read(path) == 'trusted after download')
end)

test('cached rejects an incorrect download hash without publishing files', function()
    local hash = string.rep('0', 64)
    t.assert_error('SHA-256 mismatch', function()
        cached { url = url .. '/body', sha256 = hash, name = 'wrong.bin' }
    end)
    for name in fs.list(host.cache_dir .. '/downloads/' .. hash) do error('leftover file: ' .. name) end
end)

test('cached downloads, verifies, and extracts an archive', function()
    local path = cached { url = url .. '/archive', sha256 = sha256(archive), name = 'fresh.zip', extract = true }
    assert(t.read(path .. '/sdk/lib/value') == 'library')
    assert(cached { url = url .. '/status/500', sha256 = sha256(archive), extract = true } == path)
end)

test('cached reuses trusted files without downloading or rehashing', function()
    local path, hash = seed('verified once', 'tool.jar')
    t.write(path, 'trusted cache entry')
    assert(cached { url = 'https://127.0.0.1/tool.jar', sha256 = hash } == path)
    assert(t.read(path) == 'trusted cache entry')
    assert(cached { url = 'https://127.0.0.1/download?id=1', sha256 = hash, name = 'tool.jar' } == path)
end)

test('cached preserves filenames and ignores URL query and fragment', function()
    local path, hash = seed('standalone executable', 'tool ü.exe')
    assert(cached { url = 'https://127.0.0.1/tool%20ü.exe?token=secret#fragment', sha256 = hash } == path)
    assert(cached { url = 'https://127.0.0.1/', sha256 = hash, name = 'tool ü.exe', extract = false } == path)
    path, hash = seed('unnamed download', 'download')
    assert(cached { url = 'https://127.0.0.1/?id=123', sha256 = hash } == path)
end)

test('cached files are shared across projects', function()
    local path, hash = seed('shared file', 'shared.jar')
    local project = t.project('consumer', ([[
assert(type(cached) == 'function')
return {test = function()
    print(cached{url='https://127.0.0.1/shared.jar', sha256=%q})
end}
]]):format(hash))
    assert(t.success(t.run_project(project, 'test')) == path .. '\n')
end)

test('cached extracts and trusts completed directories without the archive', function()
    local path, hash = seed(archive, 'sdk.zip')
    local directory = cached { url = 'https://127.0.0.1/sdk.zip', sha256 = hash, extract = true }
    local key = directory:match('/extracted/([0-9a-f]+)$')
    assert(key and #key == 64, directory)
    assert(t.read(directory .. '/sdk/lib/value') == 'library')
    t.write(directory .. '/sdk/lib/value', 'trusted prepared content')
    fs.remove(path)
    for _, options in ipairs({ true, {}, { strip_components = 0 }, { strip_components = 0.0 } }) do
        assert(cached { url = 'https://127.0.0.1/another.zip', sha256 = hash, extract = options } == directory)
    end
    assert(t.read(directory .. '/sdk/lib/value') == 'trusted prepared content')
end)

test('cached extraction keys distinguish options without depending on table field order', function()
    local _, hash = seed(archive, 'sdk.zip')
    local a = { include = { 'sdk/lib', 'sdk/bin' }, strip_components = 1 }
    local b = { strip_components = 1, include = { 'sdk/lib', 'sdk/bin' } }
    local first = cached { url = 'https://127.0.0.1/sdk.zip', sha256 = hash, extract = a }
    local second = cached { url = 'https://127.0.0.1/sdk.zip', sha256 = hash, extract = b }
    assert(first == second)
    assert(a.include[1] == 'sdk/lib' and #b.include == 2)
    assert(t.read(first .. '/lib/value') == 'library' and fs.stat(first .. '/share') == nil)
    local stripped = cached { url = 'https://127.0.0.1/sdk.zip', sha256 = hash, extract = { strip_components = 1 } }
    local selected = cached { url = 'https://127.0.0.1/sdk.zip', sha256 = hash, extract = { include = { 'sdk/lib' } } }
    assert(first ~= stripped and first ~= selected and stripped ~= selected)
    assert(fs.stat(stripped .. '/share').type == 'directory')
    assert(t.read(selected .. '/sdk/lib/value') == 'library' and fs.stat(selected .. '/sdk/bin') == nil)
end)

test('cached failed extraction publishes nothing and cleans temporary files', function()
    local _, hash = seed('not an archive', 'bad.zip')
    local before = {}
    for name in fs.list(host.cache_dir .. '/extracted') do before[name] = true end
    for _ = 1, 2 do
        t.assert_error('extract:',
        function() cached { url = 'https://127.0.0.1/bad.zip', sha256 = hash, extract = true } end)
        for name in fs.list(host.cache_dir .. '/extracted') do assert(before[name], name) end
    end
end)
