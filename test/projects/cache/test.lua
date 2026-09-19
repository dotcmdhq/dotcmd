---@type dotcmd.Env|_G
local _ENV = _ENV

local windows = host.os == 'windows'
local project = t.project('child', [[
assert(type(host.cache_dir) == 'string')
return {cache = function() print(host.cache_dir) end}
]])
local home = host.project_dir .. '/home'
local appdata = host.project_dir .. '/appdata'
local xdg = host.project_dir .. '/xdg'
local version = assert(t.read(project .. '/.cmd'):match('^:; version=([^\n]+)'))
local function environment()
    return { HOME = home, USERPROFILE = home, LOCALAPPDATA = appdata, XDG_CACHE_HOME = xdg, DOTCMD_CACHE_DIR = false }
end
local function check(root, env)
    -- Seed the launcher cache: no network or additional installed tools needed.
    local directory = root .. '/' .. version .. '/' .. host.os .. '-' .. host.arch
    fs.mkdir(directory)
    local binary = directory .. '/dotcmd' .. (windows and '.exe' or '')
    t.write(binary, t.read(host.executable)); fs.make_executable(binary)
    local result = t.success(t.run_project(project, { env = env }, 'cache'))
    assert(t.normalized(result:gsub('\n$', '')) == t.normalized(root), result)
end

test('cache uses the OS default in launcher and host', function()
    local root = windows and appdata .. '/dotcmd/Cache'
        or host.os == 'macos' and home .. '/Library/Caches/dotcmd' or xdg .. '/dotcmd'
    check(root, environment())
end)

test('cache falls back when OS environment variables are missing or empty', function()
    for _, value in ipairs({ false, '' }) do
        local env = environment()
        env.LOCALAPPDATA = value; env.XDG_CACHE_HOME = value
        local root = windows and home .. '/AppData/Local/dotcmd/Cache'
            or host.os == 'macos' and home .. '/Library/Caches/dotcmd' or home .. '/.cache/dotcmd'
        check(root, env)
    end
end)

test('cache override supports spaces and Unicode without HOME', function()
    local env = environment()
    env.DOTCMD_CACHE_DIR = host.project_dir .. '/custom cache ü'
    env.HOME = false; env.USERPROFILE = false; env.LOCALAPPDATA = false; env.XDG_CACHE_HOME = false
    check(env.DOTCMD_CACHE_DIR, env)
end)

test('cache ignores an empty override', function()
    local env = environment(); env.DOTCMD_CACHE_DIR = ''
    local root = windows and appdata .. '/dotcmd/Cache'
        or host.os == 'macos' and home .. '/Library/Caches/dotcmd' or xdg .. '/dotcmd'
    check(root, env)
end)

test('cache rejects a relative override', function()
    local env = environment(); env.DOTCMD_CACHE_DIR = 'relative/cache'
    t.failure(t.run_project(project, { env = env }, 'cache'), 'DOTCMD_CACHE_DIR must be an absolute path')
    if windows then
        for _, path in ipairs({ 'C:cache', '\\cache' }) do
            env.DOTCMD_CACHE_DIR = path
            t.failure(t.run_project(project, { env = env }, 'cache'), 'DOTCMD_CACHE_DIR must be an absolute path')
        end
    end
end)

if host.os == 'linux' then
    test('cache ignores a relative XDG_CACHE_HOME', function()
        local env = environment(); env.XDG_CACHE_HOME = 'relative/cache'
        check(home .. '/.cache/dotcmd', env)
    end)
end
