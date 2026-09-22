local child = host.project_dir .. '/child'
local commands = require('dotcmd.commands')
local function succeeds(expected, ...)
    local output = t.success(t.run_project(child, ...))
    assert(output == expected, output)
end

test('leaves require a run function', function()
    t.assert_error('command setup incomplete must define run', function()
        commands.normalize({ setup = { commands = { incomplete = {} } } })
    end)
    t.assert_error('command setup incomplete must define run', function()
        commands.normalize({ setup = { commands = { incomplete = { run = true } } } })
    end)
end)
test('commands and aliases cannot claim the same spelling', function()
    local run = function() end
    t.assert_error('duplicate command setup second', function()
        commands.normalize({ setup = { commands = {
            first = { aliases = { 'second' }, run = run }, second = run,
        } } })
    end)
    t.assert_error('duplicate command setup shared', function()
        commands.normalize({ setup = { commands = {
            first = { aliases = { 'shared' }, run = run },
            second = { aliases = { 'shared' }, run = run },
        } } })
    end)
    t.assert_error('duplicate command setup foo-bar', function()
        commands.normalize({ setup = { commands = { foo_bar = run, ['foo-bar'] = run } } })
    end)
end)
local function rejects(code, expected, ...)
    local result = t.run_project(child, ...)
    assert(result.code == code, result.stderr .. result.stdout)
    assert(result.stderr:find(expected, 1, true), result.stderr)
end
local function hex(s)
    return s == '' and '-' or (s:gsub('.', function(c) return ('%02x'):format(c:byte()) end))
end
local function values(prefix, ...)
    local command = { '--complete', 'words', hex(prefix) }
    for _, value in ipairs({ ... }) do command[#command + 1] = hex(value) end
    local result = t.success(t.run_project(child, table.unpack(command)))
    local names = {}
    for encoded in result:gmatch('dotcmd:value\t([^\t]+)\t[^\r\n]+') do
        names[#names + 1] = encoded == '-' and '' or (encoded:gsub('..', function(pair)
            return string.char(tonumber(pair, 16))
        end))
    end
    return table.concat(names, '|')
end

test('groups run bare and inherit options across nested dispatch', function()
    succeeds('setup false\n', 'setup')
    succeeds('setup true\n', 'configure', '-q')
    succeeds('completions false bash\n', 'setup', 'completions', 'bash')
    succeeds('completions true fish\n', 'setup', 'completions', '--quiet', 'fish')
    succeeds('editor true shared\n', 'setup', '--quiet', 'ed', '--profile', 'shared')
    succeeds('luals true shared true zed\n', 'setup', '--quiet', 'editor', '--profile', 'shared',
        'lua', '--force', 'zed')
    succeeds('luals true local false vscode\n', 'setup', 'editor', 'luals', '--quiet', 'vscode')
    succeeds('status true\n', 'setup', 'tools', 'status', '--quiet')
    rejects(1, 'unknown subcommand: missing', 'setup', 'missing')
    rejects(1, 'unknown subcommand: missing', 'setup', 'editor', 'missing')
    rejects(2, 'unknown option: --missing', 'setup', '--missing')
    rejects(1, 'unknown subcommand: --missing', 'setup', '--', '--missing')
    rejects(2, 'may only appear once', 'setup', '--quiet', 'editor', '--quiet', 'luals')
    rejects(2, 'expected one of: vscode, zed', 'setup', 'editor', 'luals', 'other')
end)

test('a leaf controls positional option boundaries', function()
    succeeds('tail true value --quiet|--force\n', 'setup', 'editor', 'tail', '--quiet', 'value', '--quiet', '--force')
    succeeds('tail false --quiet rest\n', 'setup', 'editor', 'tail', '--', '--quiet', 'rest')
    succeeds('luals false local false zed\n', 'setup', '--', 'editor', 'luals', 'zed')
    rejects(2, 'unexpected positional argument', 'setup', 'editor', 'luals', 'zed', '--quiet')
end)

test('help shows groups, paths, aliases, and inherited options', function()
    local root = t.success(t.run_project(child, '--help'))
    assert(root:find('setup [options] [command]', 1, true), root)
    local group = t.success(t.run_project(child, '--help', 'configure'))
    assert(group:find('Usage: .cmd configure [options] [command]', 1, true), group)
    assert(group:find('Commands:', 1, true) and group:find('completions', 1, true), group)
    local nested = t.success(t.run_project(child, '--help', 'setup', 'ed'))
    assert(nested:find('Usage: .cmd setup ed [options] [command]', 1, true), nested)
    assert(nested:find('luals', 1, true) and not nested:find('hidden', 1, true), nested)
    local leaf = t.success(t.run_project(child, '--help', 'setup', 'editor', 'lua'))
    assert(leaf:find('Usage: .cmd setup editor lua [options] [ide]', 1, true), leaf)
    assert(leaf:find('--quiet', 1, true) and leaf:find('--profile', 1, true)
        and leaf:find('--force', 1, true), leaf)
    local bare = t.success(t.run_project(child, 'setup', 'tools'))
    assert(bare:find('Usage: .cmd setup tools [options] <command>', 1, true), bare)
    rejects(1, 'unknown command: setup editor missing', '--help', 'setup', 'editor', 'missing')
end)

test('completion follows nested groups and inherited options', function()
    assert(values('s') == 'setup')
    assert(values('', 'setup') == 'completions|ed|editor|tools')
    assert(values('l', 'setup', 'editor') == 'lua|luals')
    assert(values('', 'setup', 'editor', '--profile') == 'local|shared')
    assert(values('z', 'setup', 'editor', 'luals') == 'zed')
    assert(values('--q', 'setup', 'editor', 'luals') == '--quiet')
    assert(values('--f', 'setup', 'editor', 'luals') == '--force')
    assert(values('--q', 'setup', 'editor', 'luals', 'zed') == '')
    assert(values('', '--help', 'setup', 'editor') == 'lua|luals|tail')
    assert(values('l', '--help', 'setup', 'editor', 'luals') == '')
    assert(values('l', 'setup', 'editor', 'missing') == '')
end)
