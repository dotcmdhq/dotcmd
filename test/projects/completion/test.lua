local child = host.project_dir .. '/child'
local function hex(s)
    return s == '' and '-' or (s:gsub('.', function(c) return ('%02x'):format(c:byte()) end))
end
local function unhex(s)
    return s == '-' and '' or (s:gsub('..', function(c) return string.char(tonumber(c, 16)) end))
end
local function request(protocol, ...)
    local args = { '--complete', protocol }
    for _, arg in ipairs({ ... }) do args[#args + 1] = hex(arg) end
    if protocol == 'bash' then args[#args + 1] = hex('=:\t ') end
    local records = {}
    for kind, a, b in t.success(t.run_project(child, table.unpack(args))):gmatch('dotcmd:(%w+)\t([^\t]+)\t([^\r\n]+)') do
        if kind ~= 'quoting' then records[#records + 1] = { kind, unhex(a), unhex(b) } end
    end
    return records
end
local function values(prefix, ...)
    local result = {}
    for _, record in ipairs(request('words', prefix, ...)) do
        assert(record[1] == 'value', record[1]); result[#result + 1] = record[2]
    end
    return table.concat(result, '|')
end
local function equal(actual, expected) assert(actual == expected, ('expected %q, got %q'):format(expected, actual)) end

test('command names, aliases, hidden commands and help', function()
    equal(values('b'), 'build-docs')
    equal(values('d'), 'docs')
    equal(values('h'), '')
    equal(values('s'), 'stop')
    equal(values('--complete'), '')
    equal(values('b', '--help'), 'build-docs')
    equal(values('s', '-h'), 'stop')
    equal(values('', '--setup-completions'), 'bash|zsh|fish|powershell|pwsh')
    local help = t.success(t.run_project(child, '--help'))
    assert(not help:find('hidden', 1, true) and not help:find('--complete ', 1, true))
    equal(t.success(t.run_project(child, 'secret')), 'hidden called\n')
end)

test('option names, values, aliases, repetition and converters', function()
    equal(values('--mo', 'docs'), '--mode')
    equal(values('-m', 'docs'), '-m')
    equal(values('--i', 'docs'), '')
    equal(values('-i', 'docs'), '')
    equal(values('d', 'docs', '--mode'), 'debug')
    equal(values('--mode=r', 'docs'), '--mode=release')
    equal(values('-m=r', 'docs'), '-m=release')
    equal(values('', 'docs', '--enabled'), 'false|true')
    equal(values('--mode', 'docs', '-m', 'debug'), '')
    equal(values('--tag', 'docs', '--tag=one'), '--tag')
    equal(values('--verbose', 'docs', '-v'), '')
    equal(values('d', 'docs', '--mode=release', '--mode'), '')
    equal(values('', 'docs', '--token'), '')
    equal(values('--mo', 'docs', '--token', 'anything'), '--mode')
    equal(values('', 'custom'), '')
    equal(values('', 'docs', '--jobs'), '')
    equal(values('--mo', 'docs', '--jobs', '-2'), '--mode')
    equal(values('', 'docs', '--unknown'), '')
end)

test('positionals, option boundaries and path directives', function()
    equal(values('', 'docs'), 'local|remote')
    equal(values('l', 'docs', '--mode', 'debug'), 'local')
    equal(values('--mo', 'docs', '--'), '')
    equal(values('--', 'literal'), '--literal')
    equal(values('--li', 'stop'), '--literal')
    equal(values('--', 'stop', 'first'), '--literal')
    equal(values('f', 'stop', '--anything'), 'first')
    equal(values('', 'empty'), '')
    for _, case in ipairs({
        { { 'path', 'docs', 'local' }, 'file', '', 'path' },
        { { 'path', 'docs', 'local', 'another' }, 'file', '', 'path' },
        { { '--file=two w', 'docs' }, 'file', '--file=', 'two w' },
        { { 'path', 'docs', '--directory' }, 'directory', '', 'path' },
        { { 'path', 'raw' }, 'file', '', 'path' },
    }) do
        local result = request('words', table.unpack(case[1]))
        equal(#result, 1)
        for i = 1, 3 do equal(result[1][i], case[i + 1]) end
    end
end)

test('shell token boundaries and unfinished quoting', function()
    for _, case in ipairs({
        { 'bash', './.cmd docs --mode d', 'debug' },
        { 'bash', '"./project dir/.cmd" docs --mode "two w', 'two words' },
        { 'bash', './.cmd docs --mode=hé', '--mode=héllo' },
        { 'bash', './.cmd docs --mode two\\ w', 'two words' },
        { 'bash', 'echo hi; ./.cmd docs --mode d', 'debug' },
    }) do
        local result = request(case[1], case[2])
        equal(#result, 1); equal(result[1][2], case[3])
    end
    equal(#request('bash', './.cmd docs --mode $(touch bad)'), 0)
    equal(#request('words', '', 'missing'), 0)
    assert(t.run_project(child, '--complete', 'words', 'invalid').code == 1)
end)

local function setup_env(name)
    local home = host.project_dir .. '/' .. name .. " home ' ü"
    fs.mkdir(home)
    return home, { HOME = home, USERPROFILE = home, XDG_CONFIG_HOME = home .. '/config',
        ZDOTDIR = false, SHELL = false }
end

test('setup uses an optional shell enum and fails when detection is unavailable', function()
    local home, env = setup_env('detect')
    t.failure(t.run_project(child, { env = env }, '--setup-completions'), 'cannot detect a supported shell')
    assert(not fs.stat(home .. '/config'))
    assert(t.run_project(child, { env = env }, '--setup-completions', 'unknown').code == 2)
    env.SHELL = '/usr/bin/fish'
    t.success(t.run_project(child, { env = env }, '--setup-completions'))
    assert(fs.stat(home .. '/config/fish/completions/.cmd.fish'))
end)

test('setup preserves profiles, updates its block, and is idempotent', function()
    local home, env = setup_env('bash')
    t.write(home .. '/.bashrc', '# keep\r\n')
    t.write(home .. '/.profile', '# login\n')
    local args = { '--setup-completions', 'bash' }
    t.success(t.run_project(child, { env = env }, table.unpack(args)))
    local first = t.read(home .. '/.bashrc')
    assert(first:sub(1, 8) == '# keep\r\n')
    assert(first:find('# <<< dotcmd completions <<<\r\n', 1, true))
    assert(not fs.stat(home .. '/.bash_profile'))
    t.success(t.run_project(child, { env = env }, table.unpack(args)))
    equal(t.read(home .. '/.bashrc'), first)
    env.XDG_CONFIG_HOME = home .. '/new config'
    t.success(t.run_project(child, { env = env }, table.unpack(args)))
    local updated = t.read(home .. '/.bashrc')
    assert(updated:find('/new config/', 1, true))
    equal(select(2, updated:gsub('# >>> dotcmd completions >>>', '')), 1)
end)

test('setup validates all profiles before writing and respects ZDOTDIR', function()
    local home, env = setup_env('profiles')
    t.write(home .. '/.bash_profile', '# >>> dotcmd completions >>>\nmissing end\n')
    t.failure(t.run_project(child, { env = env }, '--setup-completions', 'bash'), 'malformed dotcmd completion block')
    assert(not fs.stat(home .. '/.bashrc') and not fs.stat(home .. '/config'))
    env.ZDOTDIR = home .. '/zsh'
    t.success(t.run_project(child, { env = env }, '--setup-completions', 'zsh'))
    assert(fs.stat(env.ZDOTDIR .. '/.zshrc') and not fs.stat(home .. '/.zshrc'))
end)

test('setup follows profile symlinks', function()
    local home, env = setup_env('symlink')
    local target = home .. '/profile'
    t.write(target, '# retained\n')
    if not t.symlink(target, home .. '/.zshrc') then return end
    t.success(t.run_project(child, { env = env }, '--setup-completions', 'zsh'))
    equal(fs.stat(home .. '/.zshrc', { follow = false }).type, 'symlink')
    assert(t.read(target):find('# retained\n', 1, true))
    assert(t.read(target):find('dotcmd completions', 1, true))
end)

test('PowerShell setup queries the selected runtime and preserves the reported profile', function()
    for _, shell in ipairs({ 'powershell', 'pwsh' }) do
        local home, variables = setup_env('profile-' .. shell)
        local profile = home .. '/redirected documents/profile.ps1'
        fs.mkdir(home .. '/redirected documents')
        t.write(profile, '# keep\r\n')
        local env = setmetatable({}, { __index = _ENV })
        env.host = setmetatable({ os = 'windows' }, { __index = host })
        env.os = setmetatable({ getenv = function(key) return variables[key] or nil end }, { __index = os })
        local query
        env.exec = function(args) query = args; return { stdout = profile, code = 0 } end
        env.print = function() end
        env.require = function(name)
            if name == 'dotcmd.completion' then return assert(loadfile(host.project_dir .. '/../completion.lua', 't', env))() end
            return require(name)
        end
        assert(loadfile(host.project_dir .. '/../main.lua', 't', env))({
            completion_scripts = { powershell = '# adapter\n' },
        })
        equal(env.main({ '--launcher', child .. '/.cmd', '--setup-completions', shell }), 0)
        equal(query[1], shell == 'pwsh' and 'pwsh' or 'powershell.exe')
        assert(query[6]:find('$PROFILE.CurrentUserAllHosts', 1, true))
        local contents = t.read(profile)
        assert(contents:find("home '' ü", 1, true), contents)
        equal(contents:sub(1, 11), '\239\187\191# keep\r\n')
        equal(t.read(variables.XDG_CONFIG_HOME .. '/dotcmd/completions.ps1'), '# adapter\n')
        equal(env.main({ '--launcher', child .. '/.cmd', '--setup-completions', shell }), 0)
        equal(t.read(profile), contents)
        local invalid = '# caf\233\r\n'
        t.write(profile, invalid)
        fs.remove(variables.XDG_CONFIG_HOME .. '/dotcmd/completions.ps1')
        t.assert_error('profile must use UTF-8', function()
            env.main({ '--launcher', child .. '/.cmd', '--setup-completions', shell })
        end)
        equal(t.read(profile), invalid)
        assert(not fs.stat(variables.XDG_CONFIG_HOME .. '/dotcmd/completions.ps1'))
    end
end)

-- Exercise adapters with actual launchers. Prepopulate the launcher's cache so
-- completion never downloads a release while tests are running.
local adapter_cache = host.project_dir .. '/adapter-cache'
local version = t.read(child .. '/.cmd'):match('^:; version=([^\r\n]+)')
local bin_dir = adapter_cache .. '/' .. version .. '/' .. host.os .. '-' .. host.arch
fs.mkdir(bin_dir)
local binary = bin_dir .. '/dotcmd' .. (host.os == 'windows' and '.exe' or '')
t.write(binary, t.read(host.executable)); fs.chmod(binary, '+x')
t.write(child .. '/two files.txt', '')
fs.mkdir(child .. '/two dirs')
fs.mkdir(child .. '/debug')
fs.mkdir(child .. '/build-docs')
for _, shell in ipairs({ 'bash', 'zsh', 'fish', 'pwsh', 'powershell' }) do
    test(shell .. ' adapter with a real launcher', function()
        local powershell = shell == 'pwsh' or shell == 'powershell'
        if host.os == 'windows' and not powershell or host.os ~= 'windows' and shell == 'powershell' then return end
        local executable = shell == 'powershell' and 'powershell.exe' or shell
        local probe = powershell and { executable, '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'exit 0' }
            or { executable, '--version' }
        probe.stdout, probe.stderr, probe.check = 'capture', 'capture', true
        local available = pcall(exec, probe)
        if host.os == 'windows' then assert(available, shell .. ' is required for Windows completion tests') end
        if not available then print('SKIP ' .. shell .. ' is not installed'); return end
        local home, env = setup_env('adapter-' .. shell)
        env.DOTCMD_CACHE_DIR = adapter_cache
        fs.mkdir(home .. '/target-dir')
        t.write(home .. '/target-file.txt', '')
        local adapter
        if powershell then
            -- Avoid Windows KnownFolders, which ignore the test's USERPROFILE.
            adapter = home .. '/completion.ps1'
            t.write(adapter, t.read(host.project_dir .. '/../completion.powershell'))
            -- Windows PowerShell reads BOM-less scripts using the ANSI code page.
            t.write(home .. '/check.ps1', '\239\187\191' .. t.read(host.project_dir .. '/check.ps1'))
        else
            t.success(t.run_project(child, { env = env }, '--setup-completions', shell))
            adapter = env.XDG_CONFIG_HOME .. (shell == 'fish' and '/fish/completions/.cmd.fish'
                or '/dotcmd/completions.' .. shell)
        end
        local command
        if powershell then command = { executable, '-NoLogo', '-NoProfile', '-NonInteractive', '-File', home .. '/check.ps1', adapter }
        elseif shell == 'bash' then command = { shell, '--noprofile', '--norc', host.project_dir .. '/check.bash', adapter }
        elseif shell == 'zsh' then command = { shell, '-f', host.project_dir .. '/check.zsh', adapter }
        else command = { shell, '--no-config', host.project_dir .. '/check.fish', adapter } end
        command.cwd, command.env, command.stdout, command.stderr = child, env, 'capture', 'capture'
        t.success(exec(command))
    end)
end
