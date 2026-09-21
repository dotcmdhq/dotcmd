---@type dotcmd.Env|_G
local _ENV = _ENV

local template = t.read(host.project_dir .. '/.cmd')
local function release(version)
    return (template:gsub('^:; version=[^\n]+', function() return ':; version=' .. version end))
end
local original, replacement = release('1.0.0'), release('2.0.0')
local base = 'https://github.com/vlaaad/dotcmd/releases/'

-- Isolate dispatcher globals and downloads, while using the native filesystem.
local function run(options, ...)
    options = options or {}
    fs.remove(host.project_dir .. '/fixture', { recursive = true })
    local project = t.project('fixture')
    fs.remove(project .. '/.cmd.lua')
    if options.source then t.write(project .. '/.cmd.lua', options.source) end
    local path = project .. '/' .. (options.name or '.cmd')
    fs.remove(path, { recursive = true })
    if options.directory then fs.mkdir(path)
    elseif not options.missing then t.write(path, options.original or original) end
    if options.mode then fs.chmod(path, options.mode) end
    if options.setup then options.setup(path, project) end
    local env = setmetatable({}, { __index = _ENV })
    env._G = env
    env.host, env.io, env.fs = {}, {}, {}
    for k, v in pairs(host) do env.host[k] = v end
    for k, v in pairs(io) do env.io[k] = v end
    for k, v in pairs(fs) do env.fs[k] = v end
    for k, v in pairs(options.fs or {}) do env.fs[k] = v end
    env.host.cwd = project
    env.host.version = options.version or '1.0.0'
    local result = { stdout = '', stderr = '', path = path, requests = {} }
    env.print = function(value) result.stdout = result.stdout .. value .. '\n' end
    env.io.stderr = { write = function(_, value) result.stderr = result.stderr .. value end }
    env.io.open = function() error('updater must not access launcher contents through Lua') end
    env.loadfile = function(file, mode) return loadfile(file, mode, env) end
    env.http = function(request)
        result.requests[#result.requests + 1] = request.url
        assert(request.check)
        if request.url == base .. 'latest' then
            assert(request.method == 'HEAD' and request.path == nil)
            if options.lookup_error then error('lookup failed') end
            return { url = options.latest_url or base .. 'tag/2.0.0' }
        end
        assert(request.path and request.method == nil)
        if options.download then return options.download(request, path) end
        t.write(request.path, options.replacement or replacement)
        return {}
    end
    assert(loadfile(host.project_dir .. '/../main.lua', 't', env))()
    local args = { ... }
    table.insert(args, 1, path)
    table.insert(args, 1, '--launcher')
    local ok, code = pcall(env.main, args)
    result.code = ok and code or 1
    if not ok then result.stderr = result.stderr .. tostring(code) end
    for name in fs.list(project) do
        assert(not name:find('.tmp-', 1, true), 'temporary update file was not removed: ' .. name)
    end
    return result
end

test('update defaults to latest and accepts exact releases including downgrades', function()
    for _, args in ipairs({ {}, { 'latest' }, { '2.0.0' }, { '0.1.36' } }) do
        local selected = args[1] == '0.1.36' and '0.1.36' or '2.0.0'
        local result = run({ replacement = release(selected) }, '--update', table.unpack(args))
        assert(t.success(result):find(' to ' .. selected, 1, true))
        local latest = not args[1] or args[1] == 'latest'
        assert(#result.requests == (latest and 2 or 1))
        if latest then assert(result.requests[1] == base .. 'latest') end
        assert(result.requests[#result.requests] == base .. 'download/' .. selected .. '/dotcmd.cmd')
        assert(t.read(result.path) == release(selected))
    end
end)

test('update accepts nonnumeric tags and encodes them as a URL path segment', function()
    for _, case in ipairs({
        { 'v2.0-rc1', 'v2.0-rc1' }, { '2026.09', '2026.09' }, { 'nightly', 'nightly' },
        { 'release/next+build', 'release%2Fnext%2Bbuild' },
        { 'tag?query#fragment%', 'tag%3Fquery%23fragment%25' },
    }) do
        local result = run({ replacement = release(case[1]) }, '--update', case[1])
        t.success(result)
        assert(result.requests[1] == base .. 'download/' .. case[2] .. '/dotcmd.cmd')
        assert(t.read(result.path) == release(case[1]))
    end
    local result = run({ latest_url = base .. 'tag/release%2Fnext%2Bbuild' }, '--update')
    assert(t.success(result):find(' to release/next+build', 1, true))
    assert(result.requests[2] == base .. 'download/release%2Fnext%2Bbuild/dotcmd.cmd')
end)

test('update compares runtime versions and leaves same-version local edits alone', function()
    local edited = replacement .. '\n:; # local edit\n'
    for _, args in ipairs({ {}, { '2.0.0' } }) do
        local result = run({ version = '2.0.0', original = edited, download = function() error('must not download') end }, '--update', table.unpack(args))
        assert(t.success(result):find('already up to date (2.0.0)', 1, true))
        assert(t.read(result.path) == edited)
        assert(#result.requests == (#args == 0 and 1 or 0))
    end
end)

test('update uses the selected launcher and preserves Unix permissions', function()
    local result = run({ name = 'custom launcher ü.cmd', mode = 0x1e8 }, '--update') -- 0750
    t.success(result)
    assert(t.read(result.path) == replacement)
    assert(t.read(host.project_dir .. '/fixture/.cmd') == template)
    if host.os ~= 'windows' then assert(fs.stat(result.path).mode == 0x1e8) end
end)

test('update works without a project and with broken project Lua', function()
    t.success(run(nil, '--update'))
    for _, source in ipairs({ 'this is invalid Lua!', 'error("broken project")' }) do
        t.success(run({ source = source }, '--update'))
    end
end)

test('update argument errors and help do not download or change the launcher', function()
    for _, args in ipairs({
        { '' }, { '.' }, { '..' }, { 'latest', 'extra' },
    }) do
        local result = run(nil, '--update', table.unpack(args))
        assert(result.code == 2 and result.stdout == '', result.stderr)
        assert(#result.requests == 0 and t.read(result.path) == original)
    end
    local result = run(nil, '--help', '--update')
    local help = t.success(result)
    assert(help:find('Usage: .cmd --update [version]', 1, true))
    assert(help:find('default: latest', 1, true) and help:find('including local edits', 1, true))
    assert(#result.requests == 0)
end)

test('update treats launcher contents as opaque bytes regardless of format', function()
    local contents = '# future launcher format\r\n:; v=next\r\n\0\255'
    for _, args in ipairs({ {}, { '2.0.0' } }) do
        local result = run({ replacement = contents }, '--update', table.unpack(args))
        t.success(result)
        assert(t.read(result.path) == contents)
    end
end)

test('update leaves the launcher intact when latest cannot be resolved', function()
    for _, options in ipairs({ { lookup_error = true }, { latest_url = base .. 'latest' } }) do
        local result = run(options, '--update')
        t.failure(result)
        assert(#result.requests == 1 and t.read(result.path) == original)
    end
end)

test('update leaves the launcher intact on download and publication failures', function()
    for _, options in ipairs({
        { download = function() error('download failed') end },
        { download = function(request) t.write(request.path, 'partial'); error('download failed') end },
        { fs = { chmod = function() error('chmod failed') end, rename = function() error('rename failed') end } },
        { fs = { rename = function() error('rename failed') end } },
    }) do
        local result = run(options, '--update')
        t.failure(result, 'failed')
        assert(t.read(result.path) == original)
    end
end)

test('update refuses missing launchers and directories', function()
    local result = run({ missing = true }, '--update')
    t.failure(result, 'fs.realpath:')
    assert(#result.requests == 0)
    result = run({ directory = true }, '--update')
    t.failure(result, 'fs.rename:')
    assert(fs.stat(result.path).type == 'directory')
end)

test('update follows launcher link chains and preserves all aliases and target permissions', function()
    local shared = host.project_dir .. '/shared ü'
    fs.mkdir(shared)
    local target, alias = shared .. '/launcher', host.project_dir .. '/other-launcher'
    t.write(target, original)
    if not t.symlink('shared ü/launcher', alias) then return end
    for _, fail in ipairs({ false, true }) do
        t.write(target, original)
        fs.chmod(target, 0x1e8) -- 0750
        local real = fs.realpath(target)
        local result = run({ missing = true,
            source = 'assert(host.project_dir:match("/fixture$")); return {}',
            setup = function(path, project)
                assert(t.symlink('../shared ü/launcher', project .. '/link'))
                assert(t.symlink('link', path))
            end,
            fs = { rename = function(from, to, options)
                assert(to == real and from:sub(1, #real + 5) == real .. '.tmp-')
                if fail then error('publication failed') end
                return fs.rename(from, to, options)
            end },
        }, '--update')
        if fail then t.failure(result, 'publication failed') else t.success(result) end
        local expected = fail and original or replacement
        assert(t.read(target) == expected and t.read(alias) == expected and t.read(result.path) == expected)
        for _, path in ipairs({ alias, result.path, host.project_dir .. '/fixture/link' }) do
            assert(fs.stat(path, { follow = false }).type == 'symlink')
        end
        if host.os ~= 'windows' then assert(fs.stat(target).mode == 0x1e8) end
        for name in fs.list(shared) do assert(name == 'launcher', name) end
    end
end)

test('update leaves broken symlinks intact', function()
    local probe = host.project_dir .. '/broken-probe'
    if not t.symlink('nonexistent', probe) then return end
    local result = run({ missing = true, setup = function(path)
        assert(t.symlink('nonexistent', path))
    end }, '--update')
    t.failure(result, 'fs.realpath:')
    assert(fs.stat(result.path, { follow = false }).type == 'symlink' and #result.requests == 0)
end)

test('update through the running launcher preserves exit codes after replacement', function()
    local project = t.project('launcher', [[
local request = http
http = function(options)
    local server = os.getenv('DOTCMD_TEST_URL')
    if options.method == 'HEAD' then
        options.url = server .. '/latest-release'
        local response = request(options)
        response.url = 'https://github.com/vlaaad/dotcmd/releases/' .. response.url:sub(#server + 2)
        return response
    end
    options.url = server .. '/launcher/' .. assert(options.url:match('/download/([^/]+)/dotcmd.cmd$'))
    return request(options)
end
return {}
]])
    local cache = project .. '/cache'
    local windows = host.os == 'windows'
    for _, version in ipairs({ '1.0.0', '2.0.0', '0.1.36' }) do
        local directory = cache .. '/' .. version .. '/' .. host.os .. '-' .. host.arch
        fs.mkdir(directory)
        local binary = directory .. '/dotcmd' .. (windows and '.exe' or '')
        t.write(binary, t.read(host.executable)); fs.chmod(binary, "+x")
    end
    -- Different byte offsets and line endings expose Windows batch resumption bugs.
    t.write(project .. '/.cmd', windows and original:gsub('\n', '\r\n') or original)
    fs.chmod(project .. '/.cmd', "+x")
    local function invoke(version)
        local command = windows
            and { 'cmd.exe', '/d', '/c', 'call', project .. '/.cmd', '--update', version }
            or { '/bin/sh', '-c', '"$@"', 'dotcmd-test', project .. '/.cmd', '--update', version }
        command.cwd = project
        command.env = { DOTCMD_CACHE_DIR = cache }
        command.stdout, command.stderr = 'capture', 'capture'
        return exec(command)
    end
    for _, version in ipairs({ 'latest', '0.1.36' }) do
        t.success(invoke(version))
        assert(t.read(project .. '/.cmd') == release(version == 'latest' and '2.0.0' or version))
    end
    local before = t.read(project .. '/.cmd')
    t.failure(invoke('9.9.9'), 'HTTP status 404')
    assert(invoke('').code == 2)
    assert(t.read(project .. '/.cmd') == before)
end)
