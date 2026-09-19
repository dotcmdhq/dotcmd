---@type dotcmd.Env|_G
local _ENV = _ENV

local success, failure = t.success, t.failure
local child = host.project_dir .. '/child'
local normalized = t.normalized
local windows = host.os == 'windows'
local empty = t.project('empty')
local broken = t.project('broken', 'this is not valid Lua!')

test('CLI help without a project', function()
    for _, args in ipairs({ {}, { '-h' }, { '--help' } }) do
        assert(success(t.run_project(empty, table.unpack(args))):find('--version', 1, true))
    end
end)
test('CLI built-ins skip broken project code', function()
    assert(success(t.run_project(broken, '--version')) == 'dotcmd ' .. host.version .. '\n')
    assert(success(t.run_project(broken, '--licenses')):find('Lua', 1, true))
end)
test('CLI clean errors for missing project and unknown command', function()
    assert(not failure(t.run_project(empty, 'unknown'), 'no .cmd.lua'):find('stack traceback', 1, true))
    assert(not failure(t.run_project(child, 'unknown'), 'unknown command'):find('stack traceback', 1, true))
end)
test('CLI definitions, descriptions, and Lua errors', function()
    assert(success(t.run_project(child, '--help')):find('args  Print arguments as hex', 1, true))
    success(t.run_project(child, 'nothing'))
    failure(t.run_project(child, 'invalid'), 'integer exit code')
    failure(t.run_project(child, 'crash'), 'intentional project error')
    failure(t.run_project(broken, '--help'), '.cmd.lua')
end)
test('CLI argument boundaries and Unicode', function()
    local args = { '', 'two words', 'héllo', '--help', 'quote"inside', 'backslash\\' }
    if not windows then
        args[#args + 1] = 'line\nbreak'; args[#args + 1] = '$HOME'
    end
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
