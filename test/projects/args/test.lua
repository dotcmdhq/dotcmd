---@type dotcmd.Env|_G
local _ENV = _ENV

local child = host.project_dir .. '/child'
local args = require('dotcmd.args')

local function succeeds(name, ...)
    t.success(t.run_project(child, name:gsub('_', '-'), ...))
end

local function rejects(name, expected, ...)
    local result = t.run_project(child, name:gsub('_', '-'), ...)
    assert(result.code == 2, result.stdout .. result.stderr)
    assert(result.stdout == '', result.stdout)
    assert(result.stderr:find(expected, 1, true), result.stderr)
    assert(not result.stderr:find('stack traceback', 1, true), result.stderr)
end

test('scan preserves raw values and option boundaries without resolving the schema', function()
    local function unexpected() error('scan called a converter') end
    local command = {
        opts = {
            mode = { short = 'm', parse = unexpected },
            enabled = { type = 'boolean' },
            tag = { arity = '*' },
            jobs = { type = 'integer', default = 4 },
            required = { arity = '1' },
        },
        args = { { 'values', arity = '+', parse = unexpected } },
    }
    local state = assert(args.scan(command, { '-m', 'raw', '--enabled=false', '--tag=one', '--tag=two', '--', 'tail', '--literal' }))
    assert(state.opts.mode == 'raw' and state.opts.enabled == 'false')
    assert(table.concat(state.opts.tag, '|') == 'one|two')
    assert(state.opts.jobs == nil and state.opts.required == nil)
    assert(table.concat(state.positionals, '|') == 'tail|--literal' and not state.options)
    assert(state.spellings['-m'] == 'mode' and state.spellings['--mode'] == 'mode')
    state = assert(args.scan(command, {}))
    assert(state.options and #state.positionals == 0 and next(state.opts) == nil)
    state = assert(args.scan(command, { '--jobs' }))
    assert(state.pending == 'jobs')
    local parsed, message = args.parse(command, { '--jobs' })
    assert(parsed == nil and message == 'option --jobs requires a value')
    local invalid, message = args.scan(command, { '--unknown' })
    assert(invalid == nil and message == 'unknown option: --unknown')
end)

test('args absent preserves raw varargs and option-looking strings', function()
    succeeds('raw', '--', '--help', '--x=y', '')
end)

test('opts and args independently control the run signature', function()
    succeeds('opts_only', 'hello', 'world')
    succeeds('args_only', '42')
    succeeds('both', '42')
    succeeds('no_args')
    rejects('no_args', 'unexpected positional argument', 'extra')
    rejects('opts_only', 'unknown option', '--unknown')
end)

test('long options accept separate and attached values and interspersed positionals', function()
    succeeds('long_options', 'first', '--name', 'two words', '--output-dir=a=b', 'last')
    succeeds('attached', '--name=', '--pattern=-foo')
end)

test('short aliases share values and occurrence counts with long options', function()
    for _, spelling in ipairs({ '-h', '-?', '--help' }) do succeeds('short_flag', spelling) end
    succeeds('short_values', '-j', '-3', '-o=', '-v', '--verbose')
    succeeds('short_values', '-j=-3', '--output-dir=', '--verbose', '-v')
    rejects('short_flag', 'option --help may only appear once', '-h', '-?')
    rejects('short_flag', 'option --help may only appear once', '--help', '-h')
    rejects('short_flag', 'does not take a value', '-h=true')
    rejects('short_values', 'option --jobs requires a value', '-j')
    rejects('short_values', 'unknown option', '-vv')
    rejects('short_values', 'unknown option', '-j3')
end)

test('option keys use underscores while long spellings use hyphens', function()
    succeeds('short_values', '--jobs=-3', '-o', '', '-v', '-v')
    rejects('short_values', 'unknown option: --output_dir=x', '--output_dir=x')
    rejects('short_values', 'missing required option: --output-dir')
    rejects('short_values', 'option --output-dir requires a value', '-o')
    rejects('short_values', 'option --output-dir may only appear once', '-o=a', '--output-dir=b')
end)

test('args.end_opts preserves the tail while still parsing positionals', function()
    succeeds('end_opts', '-d', '42', '--debug', '--', '-d')
    succeeds('end_opts_one', '42')
    succeeds('end_opts_one', '--', '42')
    succeeds('end_opts_unknown', '--other=value', '--debug', '--')
    rejects('end_opts_one', 'does not take a value', '--debug=true')
    rejects('end_opts_one', 'value: expected an integer', '--unknown')
    rejects('end_opts_one', 'missing required argument: value')
    rejects('end_opts_one', 'value: expected an integer', 'oops')
    rejects('end_opts_one', 'unexpected positional argument: --debug', '42', '--debug')
    rejects('end_opts_one', 'unexpected positional argument: --', '42', '--')
end)

test('separator ends option recognition only when opts is declared', function()
    succeeds('separator', '--', '--debug', '--', '-x')
    succeeds('raw_separator', '--', '--debug')
end)

test('flags and boolean values are distinct and false counts as present', function()
    succeeds('flags', '--debug', '--enabled', 'false')
    succeeds('absent_flags')
    rejects('flags', 'does not take a value', '--debug=true')
    rejects('flags', 'requires a value', '--enabled')
    rejects('flags', 'expected true or false', '--enabled', 'yes')
    rejects('flags', 'may only appear once', '--enabled=false', '--enabled=true')
end)

test('built-in types convert options and positional values', function()
    succeeds('types', '--jobs', '-3', '--ratio=1.25e2', '--enabled=true', '--mode=release',
        '--file=not-created.txt', '--dir=not-created/', '-2.5')
    rejects('types', 'expected an integer', '--jobs=1.5')
    rejects('types', 'expected an integer', '--jobs=9223372036854775808')
    rejects('types', 'expected a finite number', '--ratio=1e999')
    rejects('types', 'expected a finite number', '--ratio=oops')
    rejects('types', 'expected one of: debug, release', '--mode=other')
    rejects('args_only', 'value: expected an integer', 'oops')
end)

test('all option arities count occurrences and repeated results stay arrays', function()
    succeeds('arities', '--one=x', '--plus=1', '--plus=2', '--star=false', '--star=true', '--verbose', '--verbose', '--must')
    succeeds('absent_collections', '--one=x', '--plus=1', '--must')
    rejects('arities', 'missing required option: --must', '--one=x', '--plus=1')
    rejects('arities', 'missing required option: --plus', '--one=x', '--must')
    rejects('arities', 'missing required option: --one', '--plus=1', '--must')
    rejects('flags', 'may only appear once', '--debug', '--debug')
end)

test('positional arities preserve scalar slots and expand varargs', function()
    rejects('one_arg', 'missing required argument: first')
    rejects('one_arg', 'unexpected positional argument: b', 'a', 'b')
    succeeds('optional_arg', 'a')
    succeeds('optional_boolean', 'false')
    succeeds('rest', 'a', '2', '3')
    succeeds('empty_rest', 'a')
    succeeds('plus', '2')
    rejects('required_rest', 'missing required argument: rest', 'a')
    rejects('optional_only', 'unexpected positional argument', 'a', 'b')
end)

test('defaults are final values, preserve false, and are replaced by supplied collections', function()
    succeeds('defaults')
    succeeds('supplied', '--jobs=0', '--include=src', '')
    succeeds('rest_default')
    succeeds('false_default')
end)

test('defaults pass through without invoking custom parsers', function()
    succeeds('shared_default')
end)

test('custom parsers validate and may return false or tables', function()
    succeeds('custom', '--disabled=x', '--object=hello', '5')
    rejects('invalid_custom', '--value: must be positive', '--value=-1')
    rejects('custom_number', 'value: invalid value', 'oops')
    local result = t.run_project(child, 'parser-bug', '--value=x')
    assert(result.stdout == '')
    t.failure(result, 'parser bug')
end)

test('malformed CLI input fails before run', function()
    rejects('cli_errors', 'unknown option', '--unknown=x')
    rejects('cli_errors', 'unknown option', '-n')
    rejects('cli_errors', 'requires a value', '--name')
    rejects('cli_errors', 'requires a value', '--name', '--debug')
    rejects('cli_errors', 'requires a value', '--name', '--')
    rejects('cli_errors', 'may only appear once', '--name=a', '--name=b')
    succeeds('cli_errors', '--name', '-', '-')
end)

test('parsed commands preserve exit status', function()
    assert(t.run_project(child, 'status').code == 42)
end)

test('parsed commands print returned values independently of exit status', function()
    assert(t.success(t.run_project(child, 'results')) == '42\nnil\nfalse\n')
end)

test('help describes positional arities and defaults without parsing', function()
    for _, case in ipairs({
        { 'one_arg', '<first>' }, { 'optional_arg', '<first> [last]' },
        { 'rest', '<first> [rest...]' }, { 'required_rest', '<first> <rest...>' },
        { 'defaults', '[options] [target]' },
    }) do
        local name = case[1]:gsub('_', '-')
        local output = t.success(t.run_project(child, '--help', name))
        assert(output:find('Usage: .cmd ' .. name .. ' ' .. case[2] .. '\n', 1, true), output)
    end
    local output = t.success(t.run_project(child, '--help', 'defaults')):gsub(' +', ' ')
    assert(output:find('target (default: all)', 1, true), output)
    assert(output:find('--enabled <boolean> (default: false)', 1, true), output)
    assert(output:find('--include <string> (repeatable; default: [fallback])', 1, true), output)
    output = t.success(t.run_project(child, '--help', 'arities')):gsub(' +', ' ')
    assert(output:find('--plus <integer> (required; repeatable)', 1, true), output)
    output = t.success(t.run_project(child, '--help', 'short-flag'))
    assert(output:find('-h, -?, --help', 1, true), output)
    output = t.success(t.run_project(child, '--help', 'long-options'))
    assert(output:find('--output-dir <string>', 1, true), output)
end)
