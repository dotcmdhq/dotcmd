local function seed(bytes, name)
    local hash = sha256 { bytes = bytes }
    local directory = host.cache_dir .. '/downloads/' .. hash
    fs.mkdir(directory)
    local path = directory .. '/' .. name
    t.write(path, bytes)
    return path, hash
end
local archive = t.read('sdk.zip')
local url = assert(os.getenv('DOTCMD_TEST_URL'))

local function unpack_archive(input, output)
    extract { path = input, to = output }
end

local function prepared_entries()
    local entries = {}
    local path = host.cache_dir .. '/prepared'
    if fs.stat(path) then
        for name in fs.list(path) do entries[name] = true end
    end
    return entries
end

local function assert_entries_unchanged(before)
    local after = prepared_entries()
    for name in pairs(after) do assert(before[name], 'unexpected prepared entry: ' .. name) end
    for name in pairs(before) do assert(after[name], 'missing prepared entry: ' .. name) end
end

test('fetch downloads, verifies, and reuses a file', function()
    local bytes = 'hello\0\255world'
    local path = fetch { url = url .. '/body', sha256 = sha256 { bytes = bytes }, name = 'fresh.bin' }
    assert(t.read(path) == bytes)
    t.write(path, 'trusted after download')
    assert(fetch { url = url .. '/status/500', sha256 = sha256 { bytes = bytes }, name = 'fresh.bin' } == path)
    assert(t.read(path) == 'trusted after download')
end)

test('fetch rejects an incorrect download hash without publishing files', function()
    local hash = string.rep('0', 64)
    t.assert_error('SHA-256 mismatch for ' .. url .. '/body', function()
        fetch { url = url .. '/body', sha256 = hash, name = 'wrong.bin' }
    end)
    for name in fs.list(host.cache_dir .. '/downloads/' .. hash) do error('leftover file: ' .. name) end
end)

test('fetch downloads and prepares an archive only once', function()
    local calls = 0
    local function prepare(input, output)
        calls = calls + 1
        assert(fs.stat(input).type == 'file' and fs.stat(output) == nil)
        extract { path = input, to = output }
    end
    local options = { url = url .. '/archive', sha256 = sha256 { bytes = archive }, name = 'fresh.zip', prepare = prepare }
    local path = fetch(options)
    assert(t.read(path .. '/sdk/lib/value') == 'library')
    options.url = url .. '/status/500'
    assert(fetch(options) == path and calls == 1)
    local download = fetch { url = options.url, sha256 = options.sha256, name = options.name }
    assert(download ~= path and t.read(download) == archive)
end)

test('fetch reuses trusted files without downloading or rehashing', function()
    local path, hash = seed('verified once', 'tool.jar')
    t.write(path, 'trusted cache entry')
    assert(fetch { url = 'https://127.0.0.1/tool.jar', sha256 = hash } == path)
    assert(t.read(path) == 'trusted cache entry')
    assert(fetch { url = 'https://127.0.0.1/download?id=1', sha256 = hash, name = 'tool.jar' } == path)
end)

test('fetch preserves filenames and ignores URL query and fragment', function()
    local path, hash = seed('standalone executable', 'tool ü.exe')
    assert(fetch { url = 'https://127.0.0.1/tool%20ü.exe?token=secret#fragment', sha256 = hash } == path)
    assert(fetch { url = 'https://127.0.0.1/', sha256 = hash, name = 'tool ü.exe' } == path)
    path, hash = seed('unnamed download', 'download')
    assert(fetch { url = 'https://127.0.0.1/?id=123', sha256 = hash } == path)
end)

test('fetch files are shared across projects', function()
    local path, hash = seed('shared file', 'shared.jar')
    local project = t.project('consumer', ([[
assert(type(fetch) == 'function')
return {test = function()
    print(fetch{url='https://127.0.0.1/shared.jar', sha256=%q})
end}
]]):format(hash))
    assert(t.success(t.run_project(project, 'test')) == path .. '\n')
end)

test('fetch reuses a prepared directory even without its download', function()
    local path, hash = seed(archive, 'sdk.zip')
    local options = { url = 'https://127.0.0.1/sdk.zip', sha256 = hash, prepare = unpack_archive }
    local directory = fetch(options)
    assert(t.read(directory .. '/sdk/lib/value') == 'library')
    t.write(directory .. '/sdk/lib/value', 'trusted prepared content')
    fs.remove(path)
    assert(fetch(options) == directory)
    assert(t.read(directory .. '/sdk/lib/value') == 'trusted prepared content')
end)

test('fetch preparation can extract, rearrange, and patch in place', function()
    local input, hash = seed(archive, 'install.zip')
    local staged
    local directory = fetch {
        url = 'https://127.0.0.1/install.zip', sha256 = hash,
        prepare = function(source, output)
            staged = output
            extract { path = source, to = output, strip_components = 1 }
            fs.rename(output .. '/lib', output .. '/libexec')
            t.write(output .. '/libexec/value', 'prepared library')
        end,
    }
    assert(t.read(directory .. '/libexec/value') == 'prepared library')
    assert(fs.stat(directory .. '/lib') == nil)
    assert(t.read(input) == archive)
    assert(directory ~= staged and fs.stat(staged) == nil)
    assert(fs.stat(host.cache_dir .. '/extracted') == nil)
end)

test('fetch preparation supports file outputs and ignores return values', function()
    local input, hash = seed('original bytes', 'script ü.cmd')
    local calls = 0
    local function prepare(source, output)
        calls = calls + 1
        assert(t.read(source) == 'original bytes')
        assert(fs.stat(output) == nil)
        t.write(output, 'prepared bytes')
        fs.chmod(output, "+x")
        return 'this is not the output path'
    end
    local options = { url = 'https://127.0.0.1/file', name = 'script ü.cmd', sha256 = hash, prepare = prepare }
    local output = fetch(options)
    assert(output ~= input and output:sub(-#options.name) == options.name)
    assert(fs.stat(output).type == 'file' and t.read(output) == 'prepared bytes')
    assert(fetch(options) == output and calls == 1)
    assert(fetch { url = options.url, name = options.name, sha256 = hash } == input)
    assert(t.read(input) == 'original bytes')
end)

test('fetch preparation is invalidated by callback bytecode', function()
    local _, hash = seed(archive, 'sdk.zip')
    local source = 'return function(input, output) extract{path=input, to=output, strip_components=%d} end'
    local stripped = fetch { url = 'https://127.0.0.1/sdk.zip', sha256 = hash,
        prepare = assert(load(source:format(1)))() }
    local unstripped = fetch { url = 'https://127.0.0.1/sdk.zip', sha256 = hash,
        prepare = assert(load(source:format(0)))() }
    assert(stripped ~= unstripped)
    assert(t.read(stripped .. '/lib/value') == 'library')
    assert(t.read(unstripped .. '/sdk/lib/value') == 'library')
end)

test('fetch supports named native preparation callbacks across processes', function()
    local input, hash = seed(archive, 'native.zip')
    local options = { url = 'https://127.0.0.1/native.zip', sha256 = hash, prepare = extract }
    local output = fetch(options)
    assert(t.read(output .. '/sdk/lib/value') == 'library')
    fs.remove(input)
    local project = t.project('native preparation consumer', ([[return {test = function()
    print(fetch {url='https://127.0.0.1/native.zip', sha256=%q, prepare=extract})
end}]]):format(hash))
    assert(t.success(t.run_project(project, 'test')) == output .. '\n')
end)

test('fetch preparation is invalidated by download contents and filename', function()
    local function prepare(input, output) t.write(output, t.read(input)) end
    local _, a = seed('first source', 'first.txt')
    local _, b = seed('second source', 'first.txt')
    seed('first source', 'second.txt')
    local function run(hash, name)
        return fetch { url = 'https://127.0.0.1/' .. name, sha256 = hash, prepare = prepare }
    end
    local first, second, renamed = run(a, 'first.txt'), run(b, 'first.txt'), run(a, 'second.txt')
    assert(first ~= second and first ~= renamed)
    assert(t.read(first) == 'first source' and t.read(second) == 'second source')
end)

test('fetch preparation deliberately does not fingerprint captured values', function()
    local _, hash = seed('closure example', 'capture.txt')
    local function make_prepare(value)
        return function(_, output) t.write(output, value) end
    end
    local options = { url = 'https://127.0.0.1/capture.txt', sha256 = hash, prepare = make_prepare('one') }
    local first = fetch(options)
    options.prepare = make_prepare('two')
    assert(fetch(options) == first and t.read(first) == 'one')
end)

test('fetch prepared results are shared across processes with identical stripped bytecode', function()
    local input, hash = seed('shared preparation', 'shared-prep.txt')
    local source = [[return function(input, output)
    local from <close> = assert(io.open(input, 'rb'))
    local to <close> = assert(io.open(output, 'wb'))
    assert(to:write(from:read('a'):upper()))
end]]
    local output = fetch { url = 'https://127.0.0.1/shared-prep.txt', sha256 = hash,
        prepare = assert(load(source, '@first-project.lua'))() }
    assert(t.read(output) == 'SHARED PREPARATION')
    fs.remove(input)
    local project = t.project('prepared consumer', ([[return {test = function()
    print(fetch {url='https://127.0.0.1/shared-prep.txt', sha256=%q,
        prepare=assert(load(%q, '@second-project.lua'))()})
end}]]):format(hash, source))
    assert(t.success(t.run_project(project, 'test')) == output .. '\n')
end)

test('fetch failed extraction publishes nothing and cleans temporary files', function()
    local _, hash = seed('not an archive', 'bad.zip')
    local before = prepared_entries()
    for _ = 1, 2 do
        t.assert_error('extract:',
        function() fetch { url = 'https://127.0.0.1/bad.zip', sha256 = hash, prepare = unpack_archive } end)
        assert_entries_unchanged(before)
    end
end)

test('fetch failed preparation cleans partial files and directories and can retry', function()
    for _, directory in ipairs { false, true } do
        local input, hash = seed('failure fixture ' .. tostring(directory), 'failure.txt')
        local before = prepared_entries()
        local calls, fail = 0, true
        local options = { url = 'https://127.0.0.1/failure.txt', sha256 = hash,
            prepare = function(_, output)
                calls = calls + 1
                if directory then fs.mkdir(output) end
                t.write(directory and (output .. '/value') or output, 'finished')
                if fail then error('prep failed') end
            end,
        }
        t.assert_error('prep failed', function() fetch(options) end)
        assert_entries_unchanged(before)
        assert(fs.stat(input).type == 'file')
        fail = false
        local result = fetch(options)
        assert(t.read(directory and (result .. '/value') or result) == 'finished')
        assert(fetch(options) == result and calls == 2)
    end
end)

test('fetch rejects missing outputs and invalid prepare callbacks', function()
    local _, hash = seed('missing output fixture', 'missing.txt')
    local options = { url = 'https://127.0.0.1/missing.txt', sha256 = hash, prepare = function() return 'unused' end }
    local before = prepared_entries()
    t.assert_error('prepare must create the output file or directory', function() fetch(options) end)
    assert_entries_unchanged(before)
    for _, prepare in ipairs { false, 'script.lua', {}, print } do
        options.prepare = prepare
        t.assert_error('prepare must be a Lua function or named native function', function() fetch(options) end)
    end
end)

test('fetch preserves a competing publication and discards the losing output', function()
    local _, hash = seed('publication race', 'race.txt')
    local before = prepared_entries()
    local options, nested_result, calls = nil, nil, 0
    options = { url = 'https://127.0.0.1/race.txt', sha256 = hash,
        prepare = function(_, output)
            calls = calls + 1
            if calls == 1 then
                nested_result = fetch(options)
                t.write(output, 'loser')
            else
                t.write(output, 'winner')
            end
        end,
    }
    local result = fetch(options)
    assert(result == nested_result and t.read(result) == 'winner' and calls == 2)
    local added = 0
    for name in pairs(prepared_entries()) do
        if not before[name] then
            assert(not name:match('^%.tmp%-'), name)
            added = added + 1
        end
    end
    assert(added == 1)
end)

test('fetch positional and table forms share downloads', function()
    local hash = sha256 { bytes = 'hello\0\255world' }
    local path = fetch(url .. '/body', hash)
    assert(t.read(path) == 'hello\0\255world')
    assert(fetch { url = url .. '/body', sha256 = hash } == path)
    t.assert_error('SHA-256 mismatch', function()
        fetch(url .. '/body', string.rep('1', 64))
    end)
end)
