local function unexpected() error('completion called parse or run') end
return {
    build_docs = {
        aliases = { 'docs' }, description = 'Build documentation\nDetails',
        opts = {
            mode = { short = 'm', type = { 'debug', 'release', 'two words', 'héllo' } },
            enabled = { type = 'boolean' },
            verbose = { short = 'v', flag = true },
            tag = { arity = '*', type = { 'one', 'two' } },
            token = { arity = '1', parse = unexpected },
            internal = { hidden = true, short = 'i', flag = true },
            file = { type = 'file' }, directory = { type = 'directory' },
            jobs = { type = 'integer' },
        },
        args = { { 'target', type = { 'local', 'remote' } }, { 'files', type = 'file', arity = '*' } },
        run = unexpected,
    },
    hidden = { hidden = true, aliases = { 'secret' }, args = {}, run = function() print('hidden called') end },
    stop = { opts = { verbose = { flag = true } },
        args = { end_opts = true, { 'values', arity = '*', type = { 'first', '--literal' } } }, run = unexpected },
    literal = { args = { { 'values', arity = '*', type = { '--literal', 'first' } } }, run = unexpected },
    empty = { args = {}, run = unexpected },
    custom = { args = { { 'value', parse = unexpected } }, run = unexpected },
    forward = { opts = { verbose = { flag = true } },
        args = { end_opts = true, { 'values', arity = '*' } }, run = unexpected },
    raw = unexpected,
}
