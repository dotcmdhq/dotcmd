local windows = host.os == "windows"
local project = t.project("child")
local home = host.project_dir .. "/home"
local appdata = host.project_dir .. "/appdata"
local xdg = host.project_dir .. "/xdg"
local version = assert(t.read(project .. "/.cmd"):match("^:; version=([^\n]+)"))
local function environment()
    return { HOME = home, USERPROFILE = home, LOCALAPPDATA = appdata, XDG_CACHE_HOME = xdg, DOTCMD_CACHE_DIR = false }
end
local function run(env)
    -- Cache selection belongs to the launcher, so these tests invoke the script.
    local options = windows
        and { "cmd.exe", "/d", "/c", "call", project .. "/.cmd", "--cache-dir" }
        or { "/bin/sh", "-c", "\"$@\"", "dotcmd-test", project .. "/.cmd", "--cache-dir" }
    options.cwd = project; options.env = env
    options.stdout = "capture"; options.stderr = "capture"
    options.check = false
    return exec(options)
end
local function invoke(project, env)
    local options = windows
        and { "cmd.exe", "/d", "/c", "call", project .. "/.cmd", "--cache-dir" }
        or { "/bin/sh", "-c", "\"$@\"", "dotcmd-test", project .. "/.cmd", "--cache-dir" }
    options.cwd = project; options.env = env
    options.stdout = "capture"; options.stderr = "capture"
    options.check = false
    return exec(options)
end
local function bootstrap_project(name, hash, url)
    local project = t.project(name)
    local launcher = t.read(project .. "/.cmd")
    local key = "sha_" .. host.os .. "_" .. host.arch
    local count
    launcher, count = launcher:gsub("(:; " .. key .. "=)[^\r\n]+", "%1" .. hash)
    assert(count == 1)
    launcher, count = launcher:gsub('(:; url=")[^"]+(")', "%1" .. url .. "%2")
    assert(count == 1)
    launcher, count = launcher:gsub('(set "dotcmd_url=)[^"]+(")', "%1" .. url .. "%2")
    assert(count == 1)
    t.write(project .. "/.cmd", launcher)
    fs.chmod(project .. "/.cmd", "+x")
    return project
end
local function cached_binary(cache)
    return cache .. "/" .. version .. "/" .. host.os .. "-" .. host.arch
        .. "/dotcmd" .. host.exe_suffix
end
local function check(root, env)
    -- Seed the launcher cache so it uses the updated binary without a download.
    local directory = root .. "/" .. version .. "/" .. host.os .. "-" .. host.arch
    fs.mkdir(directory)
    local binary = directory .. "/dotcmd" .. host.exe_suffix
    t.write(binary, t.read(host.executable)); fs.chmod(binary, "+x")
    local result = t.success(run(env))
    assert(t.normalized(result:gsub("\n$", "")) == t.normalized(root), result)
end

test("cache uses the OS default in launcher and host", function()
    local root = windows and appdata .. "/dotcmd/Cache"
        or host.os == "macos" and home .. "/Library/Caches/dotcmd" or xdg .. "/dotcmd"
    check(root, environment())
end)

test("launcher downloads and reuses a verified binary", function()
    local url = assert(os.getenv("DOTCMD_TEST_HTTP_URL"))
    local hash = sha256 { path = host.executable }
    local cache = host.project_dir .. "/bootstrap cache ü"
    local env = environment(); env.DOTCMD_CACHE_DIR = cache
    local fresh = bootstrap_project("bootstrap fresh", hash, url .. "/binary")
    local result = invoke(fresh, env)
    -- A fresh download may write downloader progress to stderr.
    assert(result.exit_code == 0, result.stderr .. result.stdout)
    local output = result.stdout:gsub("\r\n", "\n")
    assert(t.normalized(output:gsub("\n$", "")) == t.normalized(cache), output)
    assert(sha256 { path = cached_binary(cache) } == hash)

    local cached = bootstrap_project("bootstrap cached", hash, url .. "/status/500")
    output = t.success(invoke(cached, env))
    assert(t.normalized(output:gsub("\n$", "")) == t.normalized(cache), output)
end)

test("launcher rejects a downloaded binary with the wrong SHA-256", function()
    local url = assert(os.getenv("DOTCMD_TEST_HTTP_URL"))
    local cache = host.project_dir .. "/bootstrap mismatch"
    local env = environment(); env.DOTCMD_CACHE_DIR = cache
    local project = bootstrap_project("bootstrap wrong hash", string.rep("0", 64), url .. "/binary")
    t.failure(invoke(project, env), "SHA-256")
    assert(not fs.stat(cached_binary(cache)))
    local directory = cache .. "/" .. version .. "/" .. host.os .. "-" .. host.arch
    if fs.stat(directory) then
        for name in fs.list(directory) do error("leftover bootstrap file: " .. name) end
    end
end)

test("cache falls back when OS environment variables are missing or empty", function()
    for _, value in ipairs({ false, "" }) do
        local env = environment()
        env.LOCALAPPDATA = value; env.XDG_CACHE_HOME = value
        local root = windows and home .. "/AppData/Local/dotcmd/Cache"
            or host.os == "macos" and home .. "/Library/Caches/dotcmd" or home .. "/.cache/dotcmd"
        check(root, env)
    end
end)

test("cache override supports spaces and Unicode without HOME", function()
    local env = environment()
    env.DOTCMD_CACHE_DIR = host.project_dir .. "/custom cache ü"
    env.HOME = false; env.USERPROFILE = false; env.LOCALAPPDATA = false; env.XDG_CACHE_HOME = false
    check(env.DOTCMD_CACHE_DIR, env)
end)

test("cache ignores an empty override", function()
    local env = environment(); env.DOTCMD_CACHE_DIR = ""
    local root = windows and appdata .. "/dotcmd/Cache"
        or host.os == "macos" and home .. "/Library/Caches/dotcmd" or xdg .. "/dotcmd"
    check(root, env)
end)

test("cache rejects a relative override", function()
    local env = environment(); env.DOTCMD_CACHE_DIR = "relative/cache"
    t.failure(run(env), "DOTCMD_CACHE_DIR must be an absolute path")
    t.failure(t.run_project(project, { env = env }, "--cache-dir"), "DOTCMD_CACHE_DIR must be an absolute path")
    if windows then
        for _, path in ipairs({ "C:cache", "\\cache" }) do
            env.DOTCMD_CACHE_DIR = path
            t.failure(run(env), "DOTCMD_CACHE_DIR must be an absolute path")
            t.failure(t.run_project(project, { env = env }, "--cache-dir"), "DOTCMD_CACHE_DIR must be an absolute path")
        end
    end
end)

if host.os == "linux" then
    test("cache ignores a relative XDG_CACHE_HOME", function()
        local env = environment(); env.XDG_CACHE_HOME = "relative/cache"
        check(home .. "/.cache/dotcmd", env)
    end)
end
