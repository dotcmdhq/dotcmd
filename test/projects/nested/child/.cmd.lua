return {
    setup = {
        aliases = { 'configure' },
        description = 'Configure the project',
        opts = { quiet = { flag = true, short = 'q', description = 'Suppress output' } },
        run = function(opts) print('setup ' .. tostring(opts.quiet)) end,
        commands = {
            completions = {
                description = 'Install completions',
                args = { { 'shell', arity = '?', type = { 'bash', 'fish', 'zsh' } } },
                run = function(opts, shell) print('completions ' .. tostring(opts.quiet) .. ' ' .. tostring(shell)) end,
            },
            editor = {
                description = 'Configure an editor',
                aliases = { 'ed' },
                opts = { profile = { type = { 'local', 'shared' }, default = 'local' } },
                run = function(opts) print('editor ' .. tostring(opts.quiet) .. ' ' .. opts.profile) end,
                commands = {
                    luals = {
                        description = 'Configure LuaLS',
                        aliases = { 'lua' },
                        opts = { force = { flag = true } },
                        args = { end_opts = true, { 'ide', arity = '?', type = { 'vscode', 'zed' } } },
                        run = function(opts, ide)
                            print('luals ' .. tostring(opts.quiet) .. ' ' .. opts.profile .. ' '
                                .. tostring(opts.force) .. ' ' .. tostring(ide))
                        end,
                    },
                    tail = {
                        args = { end_opts = true, { 'first' }, { 'rest', arity = '*' } },
                        run = function(opts, first, ...)
                            print('tail ' .. tostring(opts.quiet) .. ' ' .. first .. ' ' .. table.concat({ ... }, '|'))
                        end,
                    },
                    hidden = { hidden = true, args = {}, run = function() print('hidden') end },
                },
            },
            tools = {
                description = 'Project tools',
                commands = { status = { args = {}, run = function(opts) print('status ' .. tostring(opts.quiet)) end } },
            },
        },
    },
}
