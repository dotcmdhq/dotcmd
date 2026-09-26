local args = require('dotcmd.args')
local commands = require('dotcmd.commands')
local completion = {}

-- Hex fields preserve argument boundaries across shells, including cmd.exe's
-- batch-file invocation. Neither requests nor replies are evaluated as code.
local function hex(text)
    if text == '' then return '-' end
    return (text:gsub('.', function(c) return ('%02x'):format(c:byte()) end))
end

local function unhex(text)
    if text == '-' then return '' end
    assert(type(text) == 'string' and #text > 0 and #text % 2 == 0 and not text:find('[^%x]'), 'invalid completion field')
    local value = text:gsub('..', function(pair) return string.char(tonumber(pair, 16)) end)
    assert(not value:find('\0', 1, true), 'NUL in completion field')
    return value
end

local function emit(kind, a, b)
    io.write('dotcmd:' .. kind .. '\t' .. hex(a or '') .. '\t' .. hex(b or '') .. '\n')
end

-- Tokenize only the text before the cursor. Quotes may be unfinished. Do not
-- evaluate expansions or substitutions; completion must never execute input.
local function bash_words(line, wordbreaks)
    local words, word, quote, active, redirect = {}, '', nil, false, false
    local trim, quoted_prefix = '', nil
    local function finish()
        if active then
            if not redirect then words[#words + 1] = word end
            redirect = false
        end
        word, active, trim = '', false, ''
    end
    local i = 1
    while i <= #line do
        local c, following = line:sub(i, i), line:sub(i + 1, i + 1)
        if quote == "'" then
            if c == "'" then quote = nil else word = word .. c end
        elseif c == '\\' and following ~= '' then
            if quote == '"' and not following:find('[$`"\\\n]') then
                word = word .. c
            else
                if following ~= '\n' then word = word .. following end
                i = i + 1
            end
            active = true
        elseif c == '$' and following == '(' or c == '`' then
            return -- A substitution is not a literal argument.
        elseif quote == '"' then
            if c == '"' then quote = nil else word = word .. c end
        elseif c == "'" or c == '"' then
            quote, active, quoted_prefix = c, true, word
        elseif c:match('%s') then
            finish()
        elseif c == ';' or c == '|' or c == '&' or c == '(' or c == ')' then
            finish(); words = {}; redirect = false
        elseif c == '<' or c == '>' then
            if not word:match('^%d+$') then finish() end
            word, active, redirect = '', false, true
            while line:sub(i + 1, i + 1):find('[<>]') do i = i + 1 end
        else
            word, active = word .. c, true
            if wordbreaks and wordbreaks:find(c, 1, true) then trim = word end
        end
        i = i + 1
    end
    if redirect then return end
    -- Readline replaces only the part following an unmatched opening quote.
    return words, word, quote and quoted_prefix or trim, quote
end

function completion.complete(all_commands, protocol, first, ...)
    local prefix, words, trim, quote
    if protocol == 'bash' then
        words, prefix, trim, quote = bash_words(unhex(first), unhex((...)))
        if not words or #words == 0 then return end
        table.remove(words, 1) -- executable
    elseif protocol == 'words' then
        prefix, words = unhex(first), { ... }
        for i, value in ipairs(words) do words[i] = unhex(value) end
    else
        error('unknown completion format: ' .. protocol)
    end
    ---@cast prefix string
    -- A fresh line also keeps output from project initialization separate.
    io.write('\n')
    if protocol == 'bash' then emit('quoting', trim, quote) end
    local function candidates(values, description, before, partial)
        before, partial = before or '', partial or prefix
        for _, value in ipairs(values) do
            if value ~= '' and value:sub(1, #partial) == partial then
                emit('value', before .. value, description and description:match('^[^\r\n]*') or '')
            end
        end
    end
    local function command_names(commands_by_spelling)
        local names = {}
        for name in pairs(commands_by_spelling) do names[#names + 1] = name end
        table.sort(names, function(a, b)
            local a_dash, b_dash = a:sub(1, 1) == '-', b:sub(1, 1) == '-'
            if a_dash ~= b_dash then return not a_dash end
            if a_dash then
                local a_name, b_name = a:match('^%-*(.*)$'), b:match('^%-*(.*)$')
                if a_name ~= b_name then return a_name < b_name end
            end
            return a < b
        end)
        for _, name in ipairs(names) do
            local spec = commands.find(commands_by_spelling, name)
            if spec and not spec.hidden then candidates({ name }, spec.description) end
        end
    end
    if #words == 0 then command_names(all_commands); return end
    if commands.find(all_commands, words[1]) == commands.find(all_commands, '--help') then
        local commands_by_spelling = all_commands
        for i = 2, #words do
            local command = commands.find(commands_by_spelling, words[i])
            if not command then return end
            commands_by_spelling = command.commands
            if not commands_by_spelling then return end
        end
        command_names(commands_by_spelling)
        return
    end
    local resolution = commands.resolve(all_commands, words)
    if not resolution then return end
    local command, flat, inherited_opts = resolution.command, resolution.arguments, resolution.opts

    local schema = { opts = inherited_opts,
        args = command.commands and { end_opts = true } or command.args }
    local state = args.scan(schema, flat)
    if not state then return end
    local seen, positional, options, pending, spellings =
        state.opts, #state.positionals, state.options, state.pending and schema.opts[state.pending], state.spellings
    local function values(spec, partial, before)
        if spec.parse then return end
        local kind = spec.type or 'string'
        if type(kind) == 'table' then candidates(kind, nil, before, partial)
        elseif kind == 'boolean' then candidates({ 'false', 'true' }, spec.description, before, partial)
        elseif kind == 'directory' then emit('directory', before, partial)
        elseif kind == 'file' or kind == 'string' then emit('file', before, partial) end
    end
    if pending then
        if #prefix <= 1 or prefix:sub(1, 1) ~= '-' or tonumber(prefix) ~= nil then values(pending, prefix, '') end
        return
    end
    if options and prefix:sub(1, 1) == '-' and tonumber(prefix) == nil then
        local spelling, attached = prefix:match('^([^=]+)=(.*)$')
        local key = spelling and spellings[spelling]
        if attached ~= nil then
            local spec = key and schema.opts[key]
            if spec and not spec.flag and (not seen[key] or (spec.arity == '*' or spec.arity == '+')) then values(spec, attached, spelling .. '=') end
            if spec or not (schema.args and schema.args.end_opts) then return end
        end
        local names = {}
        for name in pairs(spellings) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            local key = spellings[name]
            local spec = schema.opts[key]
            if not spec.hidden and (not seen[key] or (spec.arity == '*' or spec.arity == '+')) then candidates({ name }, spec.description) end
        end
        if not (schema.args and schema.args.end_opts) then return end
    end
    if command.commands then command_names(command.commands); return end
    if command.args == nil then emit('file', '', prefix); return end
    for i, spec in ipairs(command.args) do
        if i == positional + 1 or (spec.arity == '*' or spec.arity == '+') and positional >= i - 1 then
            values(spec, prefix, '')
            return
        end
    end
end

local function env(name)
    local value = os.getenv(name)
    return value ~= '' and value or nil
end

local function read(path)
    if not fs.stat(path) then return '' end
    local file <close> = assert(io.open(path, 'rb'))
    return assert(file:read('a'))
end

local function write(path, contents)
    if read(path) == contents then return end
    local info = fs.stat(path, { follow = false })
    if info and info.type == 'symlink' then path = fs.realpath(path) end
    info = fs.stat(path)
    fs.mkdir(assert(path:match('^(.*)[/\\]')))
    local temp = path .. '.tmp-' .. ('%016x'):format(math.random(0))
    local cleanup <close> = setmetatable({}, { __close = function() fs.remove(temp) end })
    do
        local file <close> = assert(io.open(temp, 'wb'))
        assert(file:write(contents))
    end
    if info then fs.chmod(temp, info.mode) end
    fs.rename(temp, path, { if_exists = 'replace' })
end

local function quote(path, shell)
    if shell == 'powershell' then return "'" .. path:gsub("'", "''") .. "'" end
    return "'" .. path:gsub("'", "'\\''") .. "'"
end

function completion.setup(scripts, shell)
    shell = shell or ((env('SHELL') or ''):match('([^/\\]+)$') or ''):gsub('%.exe$', '')
    assert(scripts[shell] or shell == 'pwsh',
        'cannot detect a supported shell; run .cmd --setup completions bash, zsh, fish, powershell, or pwsh')
    local family = shell == 'pwsh' and 'powershell' or shell
    local home = assert(env(host.os == 'windows' and 'USERPROFILE' or 'HOME'), 'home directory is not set')
    local config = env('XDG_CONFIG_HOME') or home .. '/.config'
    if not config:match('^[/\\]') and not config:match('^%a:[/\\]') then config = home .. '/.config' end
    local target = config .. '/dotcmd/completions.' .. (family == 'powershell' and 'ps1' or family)
    local profiles, source = {}, nil
    if shell == 'fish' then
        target = config .. '/fish/completions/.cmd.fish'
    elseif shell == 'zsh' then
        profiles = { (env('ZDOTDIR') or home) .. '/.zshrc' }
        source = '. ' .. quote(target, shell)
    elseif shell == 'bash' then
        profiles = { home .. '/.bashrc' }
        local login = home .. '/.bash_profile'
        for _, name in ipairs({ '.bash_profile', '.bash_login', '.profile' }) do
            if fs.stat(home .. '/' .. name) then login = home .. '/' .. name; break end
        end
        profiles[#profiles + 1] = login
        source = 'if [ -n "${BASH_VERSION:-}" ]; then . ' .. quote(target, shell) .. '; fi'
    else
        local executable = shell == 'powershell' and host.os == 'windows' and 'powershell.exe' or 'pwsh'
        local result = exec { executable, '-NoLogo', '-NoProfile', '-NonInteractive', '-Command',
            '[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding; [Console]::Write($PROFILE.CurrentUserAllHosts)',
            stdout = 'capture', stderr = 'capture' }
        assert(result.stdout ~= '', 'PowerShell did not report a profile path')
        profiles = { result.stdout }
        source = '. ' .. quote(target, 'powershell')
    end
    -- Validate every profile before changing any file.
    local updates = {}
    for _, path in ipairs(profiles) do
        local text = read(path)
        assert(not text:find('\0', 1, true) and (family ~= 'powershell' or utf8.len(text)),
            'profile must use UTF-8: ' .. path)
        -- Windows PowerShell 5.1 otherwise reads UTF-8 paths using the ANSI code page.
        if family == 'powershell' and host.os == 'windows' and text:sub(1, 3) ~= '\239\187\191' then text = '\239\187\191' .. text end
        local newline = text:find('\r\n', 1, true) and '\r\n' or '\n'
        local begin_marker, end_marker = '# >>> dotcmd completions >>>', '# <<< dotcmd completions <<<'
        local block = begin_marker .. newline .. source .. newline .. end_marker
        local first, last = text:find(begin_marker, 1, true), text:find(end_marker, 1, true)
        if first or last then
            assert(first and last and first < last
                and not text:find(begin_marker, first + #begin_marker, true)
                and not text:find(end_marker, last + #end_marker, true), 'malformed dotcmd completion block: ' .. path)
            text = text:sub(1, first - 1) .. block .. text:sub(last + #end_marker)
        else
            text = text .. (text ~= '' and text:sub(-1) ~= '\n' and newline or '') .. block .. newline
        end
        updates[#updates + 1] = { path, text }
    end
    write(target, scripts[family])
    for _, update in ipairs(updates) do write(update[1], update[2]) end
    print('Installed ' .. shell .. ' completions: ' .. target)
    for _, path in ipairs(profiles) do print('Configured: ' .. path) end
    print('Open a new ' .. shell .. ' shell, or enable completions now by running:')
    print((family == 'powershell' and '. ' or 'source ') .. quote(target, family))
end

return completion
