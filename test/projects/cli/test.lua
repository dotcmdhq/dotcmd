---@type dotcmd.Env|_G
local _ENV = _ENV

local success, failure = t.success, t.failure
local child = host.project_dir .. '/child'
local normalized = t.normalized
local empty = t.project('empty')
local broken = t.project('broken', 'this is not valid Lua!')

test('CLI help without a project', function()
    for _, args in ipairs({ {}, { '-h' }, { '-?' }, { '--help' } }) do
        local output = success(t.run_project(empty, table.unpack(args)))
        assert(output:find('--version', 1, true))
        assert(output:find('--cache-dir', 1, true))
        assert(not output:find('Arguments:', 1, true), output)
    end
end)
test('CLI launcher accepts attached values and options in either order', function()
    for _, args in ipairs({
        { '--launcher=' .. child .. '/.cmd', '-?' },
        { '-h', '--launcher', child .. '/.cmd' },
        { '--version', '--launcher', broken .. '/.cmd' },
        { '--launcher=' .. child .. '/.cmd', '--', 'nothing' },
    }) do
        local command = { host.executable, table.unpack(args) }
        command.stdout, command.stderr = 'capture', 'capture'
        local output = success(exec(command))
        if args[1] == '--version' then
            assert(output == 'dotcmd ' .. host.version .. '\n')
        elseif args[#args] ~= 'nothing' then
            assert(output:match('args%s+Print arguments as hex'), output)
        end
    end
end)
test('CLI option errors use the shared parser', function()
    for _, case in ipairs({
        { 'requires a value', '--launcher' },
        { 'does not take a value', '--help=true' },
        { 'may only appear once', '-h', '-?' },
        { 'unknown option', '--unknown' },
    }) do
        local command = { host.executable, table.unpack(case, 2) }
        command.stdout, command.stderr = 'capture', 'capture'
        local result = exec(command)
        assert(result.code == 2, result.stderr)
        assert(result.stdout == '', result.stdout)
        assert(result.stderr:find(case[1], 1, true), result.stderr)
        assert(not result.stderr:find('stack traceback', 1, true), result.stderr)
    end
end)
test('CLI built-ins skip broken project code', function()
    assert(success(t.run_project(broken, '--version')) == 'dotcmd ' .. host.version .. '\n')
    assert(normalized(success(t.run_project(broken, '--cache-dir')):gsub('\n$', ''))
        == normalized(host.cache_dir))
    assert(success(t.run_project(broken, '--licenses')):find('Lua', 1, true))
end)
test('CLI clean errors for missing project and unknown command', function()
    assert(not failure(t.run_project(empty, 'unknown'), 'no .cmd.lua'):find('stack traceback', 1, true))
    assert(not failure(t.run_project(child, 'unknown'), 'unknown command'):find('stack traceback', 1, true))
end)
test('CLI definitions, descriptions, and Lua errors', function()
    assert(success(t.run_project(child, '--help')):match('args%s+Print arguments as hex'))
    success(t.run_project(child, 'nothing'))
    failure(t.run_project(child, 'invalid'), 'integer exit code')
    failure(t.run_project(child, 'crash'), 'intentional project error')
    failure(t.run_project(broken, '--help'), '.cmd.lua')
end)
test('CLI general help shows sorted commands with first-line summaries', function()
    local output = success(t.run_project(child, '--help'))
    assert(output:find('Usage: .cmd [options] <command> [args...]', 1, true), output)
    assert(output:match('\n  deploy%s+Deploy files\n'), output)
    assert(not output:find('Uploads', 1, true), output)
    assert(output:find('  args', 1, true) < output:find('  deploy', 1, true), output)
    local compact = output:gsub(' +', ' ')
    assert(compact:find('-h, -?, --help Show help for a command, or list commands', 1, true), output)
    assert(compact:find('--launcher <string> Path to the project launcher', 1, true), output)
    assert(not output:find('Arguments:', 1, true), output)
    assert(not success(t.run_project(empty, '--help')):find('Commands:', 1, true))
end)
test('CLI command help shows full descriptions and schema metadata without running code', function()
    local expected = [[Usage: .cmd deploy [options] <target> [files...]

Deploy files

Uploads the selected files to the deployment target.
Existing files are replaced.

Arguments:
 target Deployment target
 files Files to deploy (file)

Options:
 --include <directory> Include directory (repeatable; default: [src, lib])
 -j, --jobs <integer> Parallel jobs (default: 4)
 --mode <debug|release> Build mode (default: release)
 --token <value> (required)
 -v, --verbose Increase verbosity (repeatable)
]]
    for _, flag in ipairs({ '--help', '-h', '-?' }) do
        local output = success(t.run_project(child, flag, 'deploy'))
        assert(output:gsub(' +', ' ') == expected, output)
    end
end)
test('CLI command help handles raw functions, empty schemas, and unknown commands', function()
    assert(success(t.run_project(child, '--help', 'nothing')) == 'Usage: .cmd nothing [args...]\n')
    assert(success(t.run_project(child, '--help', 'empty_schema')) == 'Usage: .cmd empty_schema\n')
    local output = success(t.run_project(child, '--help', 'args'))
    assert(output == 'Usage: .cmd args [args...]\n\nPrint arguments as hex\n', output)
    assert(not failure(t.run_project(child, '--help', 'unknown'), 'unknown command'):find('stack traceback', 1, true))
end)
test('CLI argument boundaries and Unicode', function()
    local args = { '', 'two words', 'héllo', '--help', '-h', '-?', '--version', '--cache-dir',
        '--licenses', '--launcher', '--', 'quote"inside', 'backslash\\',
        'line\nbreak', '$HOME', '%PATH%', '!PATH!', '&|<>^' }
    local expected = #args .. '\n'
    for _, arg in ipairs(args) do
        expected = expected .. arg:gsub('.', function(c) return ('%02x'):format(c:byte()) end) .. '\n'
    end
    assert(success(t.run_project(child, 'args', table.unpack(args))) == expected)
end)
test('CLI caller cwd and project directory', function()
    local cwd = child .. '/subdirectory'; fs.mkdir(cwd)
    local actual = success(t.run_project(child, { cwd = cwd }, 'context'))
    local expected = normalized(cwd) .. '\n' .. normalized(child) .. '\n' .. host.os .. '\n' .. host.arch .. '\n'
    assert(normalized(actual) == expected, actual)
end)
test('CLI exit status propagation', function()
    for _, code in ipairs({ 0, 1, 42, 255 }) do assert(t.run_project(child, 'status', tostring(code)).code == code) end
end)
