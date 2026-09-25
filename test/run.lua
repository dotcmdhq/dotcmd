---@type dotcmd.Env|_G
local _ENV = _ENV

-- Discover suites and run each project's commands with the local binary.
return function(repo)
    local t = assert(loadfile(repo .. '/test/support.lua'))()
    local windows = host.os == 'windows'
    local temp = os.tmpname()
    local work = repo .. '/target/test-' .. temp:match('[^/\\]+$')
    os.remove(temp)
    fs.mkdir(work)
    local cleanup <close> = setmetatable({}, { __close = function() fs.remove(work, { recursive = true }) end })

    -- Build the HTTPS fixture with a pinned toolchain; Go caches compilation.
    local go_config = {
        version = '1.27.1',
        sha256 = {
            linux = {
                x64 = '63d339f0da5ab53635a56f2490a7984dfe12dfcff22ad749f63edaf590168445',
                arm64 = '3450b45a3f9ee8568792736a5c5e70a1f2e9b36c35a8f74958c03e51d7d92bec',
            },
            macos = {
                x64 = '8f8f52c6649542cf027bbc9b9c68d1ec042f9f34808a40413f0b8b3f66f3caa4',
                arm64 = 'ee215d57e0ec269c60cc9ceca68e6bda321ba9ee5afe24f4b0988703c2d87d12',
            },
            windows = {
                x64 = 'a3911b5e0e1b1053f25ed0675f4c1c6aad1e2bfcf253df2b9be4caabd2edd95d',
                arm64 = '13b69b87bb0e83f96bc68560a8cace7f0343b1e03469f1110ea18d17e3234069',
            },
        },
    }
    local go_os = host.os == 'macos' and 'darwin' or host.os
    local go_arch = host.arch == 'x64' and 'amd64' or host.arch
    print('Preparing HTTPS test server...')
    local go = fetch {
        url = 'https://go.dev/dl/go' .. go_config.version .. '.' .. go_os .. '-' .. go_arch
            .. (windows and '.zip' or '.tar.gz'),
        sha256 = go_config.sha256[host.os][host.arch],
        prepare = function(input, output)
            extract { path = input, to = output, strip_components = 1 }
        end,
    }
    local server_binary = work .. '/http-server' .. (windows and '.exe' or '')
    exec { go .. '/bin/go' .. (windows and '.exe' or ''), 'build', '-trimpath', '-o', server_binary,
        repo .. '/test/server.go',
        env = { GOROOT = go, GOTOOLCHAIN = 'local', GOENV = 'off', CGO_ENABLED = '0',
            GOCACHE = host.cache_dir .. '/go-build', GOOS = go_os, GOARCH = go_arch },
    }
    local certificate = work .. '/test CA ü.pem'
    local server <close> = spawn { server_binary, certificate, repo .. '/test/projects/fetch/sdk.zip', repo .. '/.cmd',
        stdin = 'pipe', stdout = 'pipe', stderr = 'capture',
    }
    local server_url = server.stdout:read('l')
    if not server_url then error(server:wait().stderr) end

    local home, cache, appdata = work .. '/home', work .. '/cache', work .. '/appdata'
    fs.mkdir(home)
    local launcher = t.read(repo .. '/.cmd'):gsub('^:; version=[^\n]+', ':; version=test')
    local env = { HOME = home, USERPROFILE = home, XDG_CACHE_HOME = cache, LOCALAPPDATA = appdata,
        DOTCMD_CACHE_DIR = false, DOTCMD_TEST_URL = server_url, SSL_CERT_FILE = certificate,
        SSL_CERT_DIR = false, NO_PROXY = '*', no_proxy = '*',
    }
    t.write(work .. '/support.lua', t.read(repo .. '/test/support.lua'))
    t.write(work .. '/main.lua', t.read(repo .. '/src/main.lua'))
    t.write(work .. '/help.lua', t.read(repo .. '/src/dotcmd/help.lua'))
    t.write(work .. '/update.lua', t.read(repo .. '/src/dotcmd/update.lua'))
    t.write(work .. '/completion.lua', t.read(repo .. '/src/dotcmd/completion.lua'))
    t.write(work .. '/completion.powershell', t.read(repo .. '/src/completion.powershell'))
    local function copy_project(from, to)
        fs.mkdir(to)
        for name in fs.list(from) do
            local source, destination = from .. '/' .. name, to .. '/' .. name
            if fs.stat(source).type == 'directory' then
                copy_project(source, destination)
            else
                t.write(destination, t.read(source))
            end
        end
        t.write(to .. '/.cmd', launcher)
        fs.chmod(to .. '/.cmd', "+x")
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
            local result = t.run_project(project, { env = env }, 'test')
            io.write(result.stdout); io.stderr:write(result.stderr)
            if result.code == 0 then
                passed = passed + 1
            else
                failed = failed + 1; io.stderr:write('FAIL suite ' .. name .. '\n')
            end
        end
    end
    server.stdin:close()
    server:wait()
    print(('%d suites passed, %d failed'):format(passed, failed))
    if failed > 0 then error({ exit_code = 1 }) end
end
