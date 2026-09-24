---@type dotcmd.Env|_G
local _ENV = _ENV

local success, failure = t.success, t.failure
local child = host.project_dir .. '/child'
local normalized = t.normalized
local empty = t.project('empty')
local broken = t.project('broken', 'this is not valid Lua!')
local load_error = host.project_dir .. '/load-error'

test('CLI help without a project', function()
    for _, args in ipairs({ {}, { '-h' }, { '-?' }, { '--help' } }) do
        local output = success(t.run_project(empty, table.unpack(args)))
        assert(output:find('--version', 1, true))
        assert(output:find('--cache-dir', 1, true))
        assert(not output:find('Arguments:', 1, true), output)
        assert(not output:find('Project commands:', 1, true), output)
        assert(output:find('Built-in commands:', 1, true), output)
    end
end)
test('CLI launcher accepts separate and attached values before commands', function()
    for _, args in ipairs({
        { '--launcher=' .. child .. '/.cmd', '-?' },
        { '--launcher', child .. '/.cmd', '-h' },
        { '--launcher', broken .. '/.cmd', '--version' },
        { '--launcher=' .. child .. '/.cmd', '--', 'nothing' },
    }) do
        local command = { host.executable, table.unpack(args) }
        command.stdout, command.stderr = 'capture', 'capture'
        local output = success(exec(command))
        if args[#args] == '--version' then
            assert(output == 'dotcmd ' .. host.version .. '\n')
        elseif args[#args] ~= 'nothing' then
            assert(output:match('args %[args%.%.%.%]%s+Print arguments as hex'), output)
        end
    end
end)
test('CLI requires the launcher when invoked as a binary', function()
    for _, args in ipairs({ { 'nothing' }, { '--launcher=', 'nothing' } }) do
        local command = { host.executable, table.unpack(args) }
        command.cwd, command.stdout, command.stderr = child, 'capture', 'capture'
        command.check = false
        local result = exec(command)
        assert(result.code == 2, result.stderr)
        assert(result.stdout == '', result.stdout)
        assert(result.stderr:gsub('\r\n', '\n') == "dotcmd: invoke the project's .cmd launcher\n", result.stderr)
    end
end)
test('CLI option errors use the shared parser', function()
    for _, case in ipairs({
        { 'requires a value', '--launcher' },
        { 'may only appear once', '--launcher=a', '--launcher=b' },
    }) do
        local command = { host.executable, table.unpack(case, 2) }
        command.stdout, command.stderr = 'capture', 'capture'
        command.check = false
        local result = exec(command)
        assert(result.code == 2, result.stderr)
        assert(result.stdout == '', result.stdout)
        assert(result.stderr:find(case[1], 1, true), result.stderr)
        assert(not result.stderr:find('stack traceback', 1, true), result.stderr)
    end
end)
test('CLI built-ins work when project loading fails', function()
    for _, project in ipairs({ empty, broken, load_error }) do
        assert(success(t.run_project(project, '--version')) == 'dotcmd ' .. host.version .. '\n')
        assert(normalized(success(t.run_project(project, '--cache-dir')):gsub('\n$', ''))
            == normalized(host.cache_dir))
        assert(success(t.run_project(project, '--licenses')):find('Lua', 1, true))
        local output = success(t.run_project(project, '--help'))
        assert(output:find('Built-in commands:', 1, true), output)
        assert(not output:find('Project commands:', 1, true), output)
        for _, name in ipairs({ '--version', '--cache-dir', '--licenses' }) do
            local result = t.run_project(project, name, 'extra')
            assert(result.code == 2, result.stderr)
            assert(result.stdout == '', result.stdout)
            assert(result.stderr:find('unexpected positional argument: extra', 1, true), result.stderr)
        end
    end
end)
test('CLI clean errors for missing project and unknown command', function()
    assert(not failure(t.run_project(empty, 'unknown'), '.cmd.lua'):find('stack traceback', 1, true))
    assert(not failure(t.run_project(broken, 'unknown'), '.cmd.lua'):find('stack traceback', 1, true))
    assert(not failure(t.run_project(load_error, 'unknown'), 'intentional project load error'):find('stack traceback', 1, true))
    assert(not failure(t.run_project(child, 'unknown'), 'unknown command'):find('stack traceback', 1, true))
    assert(not failure(t.run_project(child, '--unknown'), 'unknown command: --unknown'):find('stack traceback', 1, true))
end)
test('CLI definitions, descriptions, and Lua errors', function()
    assert(success(t.run_project(child, '--help')):match('args %[args%.%.%.%]%s+Print arguments as hex'))
    success(t.run_project(child, 'nothing'))
    failure(t.run_project(child, 'invalid'), 'integer exit code')
    failure(t.run_project(child, 'crash'), 'intentional project error')
end)
test('CLI general help shows sorted commands with first-line summaries', function()
    local output = success(t.run_project(child, '--help'))
    assert(output:find('Usage: .cmd <command> [args...]', 1, true), output)
    local project_section = assert(output:find('\nProject commands:\n', 1, true), output)
    local builtin_section = assert(output:find('\nBuilt-in commands:\n', 1, true), output)
    assert(project_section < builtin_section, output)
    assert(output:find('  --echo', 1, true) > builtin_section, output)
    assert(output:find('  --help [command...], -h, -?', 1, true) > builtin_section, output)
    assert(not output:find('\nOptions:\n', 1, true), output)
    assert(output:match('\n  deploy %[options%] <target> %[files%.%.%.%]%s+Deploy files\n'), output)
    assert(output:find('\n  empty-schema\n', 1, true), output)
    assert(output:find('\n  nothing [args...]\n', 1, true), output)
    assert(not output:find('Uploads', 1, true), output)
    assert(output:find('  args', 1, true) < output:find('  deploy', 1, true), output)
    local compact = output:gsub(' +', ' ')
    assert(compact:find('\n --help [command...], -h, -? Show help for a command, or list commands\n', 1, true), output)
    assert(not output:match('\n  %-h%s'), output)
    assert(not output:match('\n  %-%?%s'), output)
    assert(not output:match('Options:.*%-%-help'), output)
    for _, name in ipairs({ '--version', '--cache-dir', '--licenses' }) do
        local position = assert(output:find('  ' .. name, 1, true), output)
        assert(position > builtin_section, output)
    end
    assert(not output:find('--launcher', 1, true), output)
    assert(not output:find('Arguments:', 1, true), output)
    assert(success(t.run_project(empty, '--help')):find('Built-in commands:', 1, true))
end)
test('CLI hidden options remain accepted but do not appear in help', function()
    assert(success(t.run_project(child, 'hidden-options')) == 'false\n')
    assert(success(t.run_project(child, 'hidden-options', '--internal')) == 'true\n')
    assert(success(t.run_project(child, '--help', 'hidden-options')) == 'Usage: .cmd hidden-options\n')
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
    assert(success(t.run_project(child, '--help', 'empty-schema')) == 'Usage: .cmd empty-schema\n')
    local output = success(t.run_project(child, '--help', 'args'))
    assert(output == 'Usage: .cmd args [args...]\n\nPrint arguments as hex\n', output)
    assert(not failure(t.run_project(child, '--help', 'unknown'), 'unknown command'):find('stack traceback', 1, true))
end)
test('CLI built-in help accepts a command path', function()
    assert(success(t.run_project(child)) == success(t.run_project(child, '--help')))
    local output = success(t.run_project(child, '--help', '--help'))
    assert(output:find('Usage: .cmd --help [command...]\n', 1, true), output)
    assert(output:find('Command path to describe', 1, true), output)
    local result = t.run_project(child, '--help', 'deploy', 'extra')
    assert(result.code == 1, result.stderr)
    assert(result.stderr:find('unknown command: deploy extra', 1, true), result.stderr)
    assert(success(t.run_project(child, '-h', '--help')) == output)
    assert(success(t.run_project(child, '-?', '--help')) == output)
    assert(success(t.run_project(child, '--help', '--version')) == 'Usage: .cmd --version\n\nShow dotcmd version\n')
    assert(success(t.run_project(child, '-h', '--version')) == 'Usage: .cmd --version\n\nShow dotcmd version\n')
    assert(success(t.run_project(child, 'help')) == 'project help\n')
    assert(success(t.run_project(child, 'update')) == 'project update\n')
end)
test('CLI command keys use underscores and CLI names use hyphens', function()
    assert(success(t.run_project(child, 'build-docs', 'keep_under_scores')) == 'keep_under_scores\n')
    assert(success(t.run_project(child, 'already-hyphenated')) == 'hyphenated\n')
    assert(success(t.run_project(child, '--echo', '--version')) == '--version\n')
    local output = success(t.run_project(child, '--help'))
    assert(output:match('\n  build%-docs <value>, docs, docs_local, %-d%s+Build documentation\n'), output)
    assert(not output:find('build_docs', 1, true), output)
    output = success(t.run_project(child, '--help', 'build-docs'))
    assert(output:find('Usage: .cmd build-docs <value>\n', 1, true), output)
    failure(t.run_project(child, 'build_docs'), 'unknown command: build_docs')
end)
test('CLI command aliases preserve literal spellings and share argument parsing', function()
    for _, alias in ipairs({ 'docs', 'docs_local', '-d' }) do
        assert(success(t.run_project(child, alias, 'hello')) == 'hello\n')
        local result = t.run_project(child, alias)
        assert(result.code == 2, result.stderr)
        assert(result.stderr:find('missing required argument: value', 1, true), result.stderr)
        local output = success(t.run_project(child, '--help', alias))
        assert(output:find('Usage: .cmd ' .. alias .. ' <value>\n', 1, true), output)
        assert(output:find('Build documentation', 1, true), output)
    end
    failure(t.run_project(child, 'docs-local', 'hello'), 'unknown command: docs-local')
    local output = success(t.run_project(child, '--help'))
    assert(not output:match('\n  docs%s'), output)
    assert(not output:match('\n  docs_local%s'), output)
    assert(not output:match('\n  %-d%s'), output)
    for _, alias in ipairs({ '-?', '-h' }) do
        output = success(t.run_project(child, '--help', alias))
        assert(output:find('Usage: .cmd ' .. alias .. ' [command...]\n', 1, true), output)
    end
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
