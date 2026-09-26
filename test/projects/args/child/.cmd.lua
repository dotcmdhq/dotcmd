local function equal(actual, expected)
    assert(type(actual) == type(expected), 'value type mismatch')
    if type(expected) == 'table' then
        for key, value in pairs(expected) do equal(actual[key], value) end
        for key in pairs(actual) do assert(expected[key] ~= nil, 'unexpected field: ' .. tostring(key)) end
    else
        assert(actual == expected, 'value mismatch: ' .. tostring(actual) .. ' ~= ' .. tostring(expected))
        if type(expected) == 'number' then assert(math.type(actual) == math.type(expected)) end
    end
end

local function command(spec, ...)
    local expected = table.pack(...)
    spec.run = function(...) equal(table.pack(...), expected) end
    return spec
end

local flags = { debug = { flag = true }, enabled = { type = 'boolean', default = true } }
local types = {
    jobs = { type = 'integer' }, ratio = { type = 'number' }, enabled = { type = 'boolean' },
    mode = { type = { 'debug', 'release' } }, file = { type = 'file' }, dir = { type = 'directory' },
}
local arities = {
    one = { arity = '1' }, optional = {},
    plus = { arity = '+', type = 'integer' }, star = { arity = '*', type = 'boolean' },
    verbose = { flag = true, arity = '*' }, must = { flag = true, arity = '1' },
}
local defaults = {
    jobs = { type = 'integer', default = 4 }, enabled = { type = 'boolean', default = false },
    include = { arity = '*', default = { 'fallback' } },
}
local target = { { 'target', arity = '?', default = 'all' } }
local shared_default = { { value = 1 } }

return {
    raw = command({}, '--', '--help', '--x=y', ''),
    opts_only = command({ opts = {} }, {}, 'hello', 'world'),
    args_only = command({ args = { { 'value', type = 'integer' } } }, 42),
    both = command({ opts = {}, args = { { 'value', type = 'integer' } } }, {}, 42),
    no_args = command({ args = {} }),
    long_options = command({ opts = { name = {}, output_dir = {} } },
        { name = 'two words', output_dir = 'a=b' }, 'first', 'last'),
    short_flag = command({ opts = { help = { flag = true, short = 'h?' } } }, { help = true }),
    short_values = command({ opts = {
        jobs = { type = 'integer', short = 'j' }, output_dir = { short = 'o', arity = '1' },
        verbose = { flag = true, short = 'v', arity = '*' },
    } }, { jobs = -3, output_dir = '', verbose = { true, true } }),
    end_opts = command({
        opts = { debug = { flag = true, short = 'd' } },
        args = { end_opts = true, { 'value', type = 'integer' }, { 'rest', arity = '*' } },
    }, { debug = true }, 42, '--debug', '--', '-d'),
    end_opts_one = command({
        opts = { debug = { flag = true } },
        args = { end_opts = true, { 'value', type = 'integer' } },
    }, { debug = false }, 42),
    end_opts_unknown = command({
        opts = { debug = { flag = true } },
        args = { end_opts = true, { 'rest', arity = '*' } },
    }, { debug = false }, '--other=value', '--debug', '--'),
    attached = command({ opts = { name = {}, pattern = {} } }, { name = '', pattern = '-foo' }),
    separator = command({ opts = { debug = { flag = true } } }, { debug = false }, '--debug', '--', '-x'),
    raw_separator = command({ args = { end_opts = true, { 'values', arity = '*' } } }, '--', '--debug'),
    flags = command({ opts = flags }, { debug = true, enabled = false }),
    absent_flags = command({ opts = flags }, { debug = false, enabled = true }),
    types = command({ opts = types, args = { { 'value', type = 'number' } } }, {
        jobs = -3, ratio = 125.0, enabled = true, mode = 'release',
        file = 'not-created.txt', dir = 'not-created/',
    }, -2.5),
    arities = command({ opts = arities }, {
        one = 'x', plus = { 1, 2 }, star = { false, true }, verbose = { true, true }, must = true,
    }),
    absent_collections = command({ opts = arities }, {
        one = 'x', plus = { 1 }, star = {}, verbose = {}, must = true,
    }),
    one_arg = command({ args = { { 'first' } } }, 'a'),
    optional_arg = command({ args = { { 'first' }, { 'last', arity = '?' } } }, 'a', nil),
    optional_boolean = command({ opts = {}, args = { { 'last', arity = '?', type = 'boolean' } } }, {}, false),
    rest = command({ args = { { 'first' }, { 'rest', arity = '*', type = 'integer' } } }, 'a', 2, 3),
    empty_rest = command({ args = { { 'first' }, { 'rest', arity = '*' } } }, 'a'),
    plus = command({ args = { { 'rest', arity = '+', type = 'integer' } } }, 2),
    required_rest = command({ args = { { 'first' }, { 'rest', arity = '+' } } }, 'a', 'b'),
    optional_only = command({ args = { { 'last', arity = '?' } } }, nil),
    defaults = command({ opts = defaults, args = target }, { jobs = 4, enabled = false, include = { 'fallback' } }, 'all'),
    supplied = command({ opts = defaults, args = target }, { jobs = 0, enabled = false, include = { 'src' } }, ''),
    rest_default = command({ args = { { 'values', arity = '*', type = 'integer', default = { 2, 3 } } } }, 2, 3),
    false_default = command({ args = { { 'value', arity = '?', type = 'boolean', default = false } } }, false),
    shared_default = {
        opts = { items = {
            arity = '*', default = shared_default,
            parse = function() error('default was parsed') end,
        } },
        run = function(opts) assert(opts.items == shared_default) end,
    },
    custom = command({
        opts = {
            disabled = { arity = '1', parse = function() return false end },
            object = { parse = function(text) return { text = text } end },
        },
        args = { { 'value', parse = tonumber } },
    }, { disabled = false, object = { text = 'hello' } }, 5),
    invalid_custom = command({ opts = { value = {
        parse = function() return nil, 'must be positive' end,
    } } }),
    custom_number = command({ args = { { 'value', parse = tonumber } } }, 5),
    parser_bug = command({ opts = { value = {
        parse = function() error('parser bug') end,
    } } }),
    cli_errors = command({ opts = { name = {}, debug = { flag = true } } }, { name = '-', debug = false }, '-'),
    status = { opts = {}, args = {}, run = function() error({ exit_code = 42 }) end },
    results = { opts = {}, args = {}, run = function() return 42, nil, false end },
}
