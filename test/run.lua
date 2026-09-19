-- Discover suites and invoke each project's .cmd test with the local binary.
return function(repo)
    local t = assert(loadfile(repo .. '/test/support.lua'))()
    local windows = host.os == 'windows'
    local temp = os.tmpname()
    local work = repo .. '/target/test-' .. temp:match('[^/\\]+$')
    os.remove(temp)
    fs.mkdir(work)
    local cleanup <close> = setmetatable({}, {__close=function() fs.remove(work, {recursive=true}) end})
    local home, cache, appdata = work .. '/home', work .. '/cache', work .. '/appdata'
    fs.mkdir(home)
    local cache_root = windows and (appdata .. '/dotcmd/Cache')
        or host.os == 'macos' and (home .. '/Library/Caches/dotcmd') or (cache .. '/dotcmd')
    local binary = repo .. '/target/release/dotcmd' .. (windows and '.exe' or '')
    local binary_dir = cache_root .. '/test/' .. host.os .. '-' .. host.arch
    fs.mkdir(binary_dir)
    local cached = binary_dir .. '/dotcmd' .. (windows and '.exe' or '')
    t.write(cached, t.read(binary)); fs.make_executable(cached)
    local launcher = t.read(repo .. '/.cmd'):gsub('^:; version=[^\n]+', ':; version=test')
    local env = {HOME=home, USERPROFILE=home, XDG_CACHE_HOME=cache, LOCALAPPDATA=appdata}
    t.write(work .. '/support.lua', t.read(repo .. '/test/support.lua'))
    local function copy_project(from, to)
        fs.mkdir(to)
        for name in fs.list(from) do
            local source, destination = from .. '/' .. name, to .. '/' .. name
            if fs.stat(source).type == 'directory' then copy_project(source, destination)
            else t.write(destination, t.read(source)) end
        end
        t.write(to .. '/.cmd', launcher)
        fs.make_executable(to .. '/.cmd')
    end

    local passed, failed = 0, 0
    for name in fs.list(repo .. '/test/projects') do
        local source = repo .. '/test/projects/' .. name
        if fs.stat(source).type == 'directory' then
            local project = work .. '/' .. name .. ' project'
            copy_project(source, project)
            -- Suites contain only test blocks; supply their shared command wrapper.
            t.write(project .. '/.cmd.lua', [[return {test = function()
local t = assert(loadfile(host.project_dir .. '/../support.lua'))()
local test = t.test
]] .. t.read(project .. '/test.lua') .. '\nreturn t.finish()\nend}\n')
            local result = t.run_project(project, {'test'}, nil, env)
            io.write(result.out); io.stderr:write(result.err)
            if result.code == 0 then passed = passed + 1
            else failed = failed + 1; io.stderr:write('FAIL suite ' .. name .. '\n') end
        end
    end
    print(('%d suites passed, %d failed'):format(passed, failed))
    return failed == 0 and 0 or 1
end
