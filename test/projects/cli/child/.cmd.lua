---@type dotcmd.Env|_G
local _ENV = _ENV

assert(type(host) == 'table') -- Available while loading the project, not just in commands.
assert(select('#', ...) == 0)
local function hex(value)
    return (value:gsub('.', function(c) return ('%02x'):format(c:byte()) end))
end
return {
    help = function() print('project help') end,
    update = function() print('project update') end,
    __echo = function(value) print(value) end,
    build_docs = {
        aliases = { 'docs', 'docs_local', '-d' },
        description = 'Build documentation',
        args = { { 'value' } },
        run = function(value) print(value) end,
    },
    ['already-hyphenated'] = function() print('hyphenated') end,
    args = {description = 'Print arguments as hex', run = function(...)
        print(select('#', ...))
        for i = 1, select('#', ...) do print(hex(select(i, ...))) end
    end},
    context = function() print(host.cwd); print(host.project_dir); print(host.os); print(host.arch) end,
    status = function(code) return tonumber(code) end,
    nothing = function() end,
    invalid = function() return false end,
    crash = function() error('intentional project error') end,
    deploy = {
        description = [[Deploy files

Uploads the selected files to the deployment target.
Existing files are replaced.
]],
        args = { { 'target', description = 'Deployment target' }, { 'files', type = 'file', arity = '*', description = 'Files to deploy' } },
        opts = {
            jobs = { short = 'j', type = 'integer', default = 4, description = 'Parallel jobs' },
            mode = { type = { 'debug', 'release' }, default = 'release', description = 'Build mode' },
            include = { type = 'directory', arity = '*', default = { 'src', 'lib' }, description = 'Include directory' },
            verbose = { flag = true, short = 'v', arity = '*', description = 'Increase verbosity' },
            token = { arity = '1', parse = function() error('help called parse') end },
        },
        run = function() error('help called run') end,
    },
    empty_schema = { opts = {}, args = {}, run = function() error('help called run') end },
    hidden_options = {
        opts = { internal = { hidden = true, flag = true } },
        args = {},
        run = function(opts) print(tostring(opts.internal)) end,
    },
}
