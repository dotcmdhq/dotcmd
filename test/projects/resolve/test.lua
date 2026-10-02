local api_base = "https://api.github.com/repos/owner/repo"
local download_base = "https://github.com/owner/repo/releases/download/v1/"
local hash_a, hash_b = string.rep("a", 64), string.rep("b", 64)

-- Run the real dispatcher/resolver with controlled HTTP bodies and captured output.
local function run(routes, ...)
    local env = setmetatable({}, { __index = _ENV })
    env._G = env
    env.io = setmetatable({}, { __index = io })
    local stdout <close> = assert(io.tmpfile())
    local result = { stdout = "", stderr = "", requests = {}, project_loads = 0 }
    env.io.stdout = stdout
    env.io.stderr = { write = function(_, ...) result.stderr = result.stderr .. table.concat { ... } end }
    env.fs = setmetatable({ stat = function(path, options)
        if path == ".cmd.lua" then return { type = "file" } end
        return fs.stat(path, options)
    end }, { __index = fs })
    env.loadfile = function(path, mode)
        if path == ".cmd.lua" then
            return function() result.project_loads = result.project_loads + 1; return {} end
        end
        return loadfile(path, mode, env)
    end
    env.require = function(name)
        if name == "dotcmd.resolve" then return assert(loadfile(host.project_dir .. "/../resolve.lua", "t", env))() end
        if name == "dotcmd.help" then return assert(loadfile(host.project_dir .. "/../help.lua", "t", env))() end
        return require(name)
    end
    env.http = function(request)
        result.requests[#result.requests + 1] = request.url
        local route = assert(routes[request.url], "unexpected request: " .. request.url)
        if request.url:sub(1, #api_base) == api_base then
            assert(request.headers.Accept == "application/vnd.github+json")
            assert(request.headers["X-GitHub-Api-Version"] == "2022-11-28")
        else
            assert(request.headers == nil)
        end
        assert(request.check ~= false and type(request.to) == "function")
        if type(route) == "string" then route = { chunks = { route } } end
        local consume = request.to()
        for _, chunk in ipairs(route.chunks or {}) do consume(chunk) end
        if route.error then error(route.error, 0) end
        return { body = consume(), url = route.final_url or request.url }
    end
    local main = assert(loadfile(host.project_dir .. "/../main.lua", "t", env))({
        version = "test", launcher = host.project_dir .. "/.cmd",
    })
    env.io.stdout = routes.stdout or stdout
    local ok, code = pcall(main, { ... })
    if ok then result.code = code
    elseif type(code) == "table" then
        result.code = code.exit_code or 1
        if code.message then result.stderr = result.stderr .. tostring(code.message) end
    else result.code = 1; result.stderr = result.stderr .. tostring(code) end
    stdout:seek("set")
    result.stdout = stdout:read("a")
    assert(result.project_loads == 1, "resolver changed project loading semantics")
    return result
end

local function asset(name, hash, size)
    return { name = name, digest = hash and "sha256:" .. hash,
        browser_download_url = download_base .. name, size = size }
end

local function release_routes(assets, tag)
    return {
        [api_base .. "/releases/" .. (tag or "latest")] = json.encode { assets = assets },
    }
end

local function count_fields(value)
    local count = 0
    for _ in pairs(value) do count = count + 1 end
    assert(count == 2 and value.url and value.sha256)
end

test("resolve URL streams binary chunks and retains the input URL", function()
    local url, bytes = "https://example.com/file", "a\0\255b"
    local result = run({ [url] = { chunks = { "", "a\0", "\255b" }, final_url = "https://example.com/temporary-token" } },
        "--resolve", "url", url)
    assert(t.success(result) == "url: " .. url .. "\nsha256: " .. sha256 { bytes = bytes } .. "\n")
    assert(#result.requests == 1)
end)

test("resolve single JSON results contain only URL and SHA-256", function()
    local url = "https://example.com/empty"
    local result = run({ [url] = "" }, "--resolve", "url", url, "--format", "json")
    local value = json.decode(t.success(result))
    count_fields(value)
    assert(value.url == url and value.sha256 == sha256 { bytes = "" })
end)

test("resolve repository default branch pins a commit URL", function()
    local commit = string.rep("c", 40)
    local url = "https://raw.githubusercontent.com/owner/repo/" .. commit .. "/dir/file.lua"
    local result = run({
        [api_base] = json.encode { default_branch = "main" },
        [api_base .. "/commits/main"] = json.encode { sha = commit }, [url] = "return {}",
    }, "--resolve", "github-file", "owner/repo", "dir/file.lua", "--format", "json")
    local value = json.decode(t.success(result))
    assert(value.url == url and value.sha256 == sha256 { bytes = "return {}" })
    assert(#result.requests == 3)
end)

test("resolve repository refs and path segments are URL encoded", function()
    local commit = string.rep("d", 40)
    local url = "https://raw.githubusercontent.com/owner/repo/" .. commit .. "/dir/a%20b%2B%23.lua"
    local result = run({ [api_base .. "/commits/release%2Fnext%2Bbuild"] = json.encode { sha = commit }, [url] = "file" },
        "--resolve", "github-file", "owner/repo", "dir/a b+#.lua", "--ref", "release/next+build")
    assert(t.success(result):find(url, 1, true))
    assert(#result.requests == 2)
end)

test("resolve releases use API SHA-256s without downloading assets", function()
    local routes = release_routes({ asset("z.zip", hash_b:upper(), 200000000), asset("a.zip", hash_a, 300000000) })
    local result = run(routes, "--resolve", "github-release", "owner/repo", "--format", "json")
    local values = json.decode(t.success(result))
    assert(#values == 2 and values[1].url == download_base .. "z.zip" and values[1].sha256 == hash_b)
    for _, value in ipairs(values) do count_fields(value) end
    assert(#result.requests == 1)
end)

test("resolve release tag is encoded and one result is still an array", function()
    local routes = release_routes({ asset("tool.zip", hash_a) }, "tags/release%2Fnext%2Bbuild")
    local result = run(routes, "--resolve", "--format", "json", "github-release", "owner/repo",
        "--tag", "release/next+build")
    local values = json.decode(t.success(result))
    assert(#values == 1 and values[1].sha256 == hash_a)
    assert(result.requests[1] == api_base .. "/releases/tags/release%2Fnext%2Bbuild")
end)

test("resolve asset filters skip downloads and budget checks for unmatched assets", function()
    local routes = release_routes {
        asset("huge.zip", nil, 300000000), asset("tool-standalone.jar", nil, 3),
        asset("tool-standalone.jar.sha256", nil, 300000000), asset("other-standalone.jar", hash_b),
    }
    routes[download_base .. "tool-standalone.jar"] = "jar"
    local result = run(routes, "--resolve", "github-release", "owner/repo", "--asset", "*-standalone.jar", "--format", "json")
    local values = json.decode(t.success(result))
    assert(#values == 2 and values[1].url == download_base .. "tool-standalone.jar")
    assert(values[1].sha256 == sha256 { bytes = "jar" } and values[2].sha256 == hash_b)
    assert(#result.requests == 2 and result.requests[2] == download_base .. "tool-standalone.jar")
end)

test("resolve asset globs match whole case-sensitive names with literal punctuation", function()
    local names = { "tool.zip", "toolXzip", "tool1.zip", "tool12.zip", "TOOL.zip", "prefix-tool.zip", "tool.zip.sha256",
        "tool+[1](x)%^-$.zip" }
    local assets = {}
    for _, name in ipairs(names) do assets[#assets + 1] = asset(name, hash_a) end
    for _, case in ipairs {
        { "tool.zip", "tool.zip" },
        { "tool?.zip", "tool1.zip" },
        { "tool*.zip", "tool.zip", "tool1.zip", "tool12.zip", "tool+[1](x)%^-$.zip" },
        { "tool+[1](x)%^-$.zip", "tool+[1](x)%^-$.zip" },
    } do
        local result = run(release_routes(assets), "--resolve", "github-release", "owner/repo", "--asset", case[1], "--format", "json")
        local values = json.decode(t.success(result))
        assert(#values == #case - 1 and #result.requests == 1)
        for i, value in ipairs(values) do assert(value.url == download_base .. case[i + 1]) end
    end
end)

test("resolve unmatched asset globs produce an empty array or empty text", function()
    for _, format in ipairs { "text", "json" } do
        local result = run(release_routes { asset("tool.zip", nil, 300000000) },
            "--resolve", "github-release", "owner/repo", "--asset", "*.jar", "--format", format)
        assert(t.success(result) == (format == "text" and "" or "[]\n"))
        assert(#result.requests == 1)
    end
end)

test("resolve release text separates URL and hash pairs with blank lines", function()
    local result = run(release_routes({ asset("a.zip", hash_a), asset("b.zip", hash_b) }),
        "--resolve", "github-release", "owner/repo")
    assert(t.success(result) == "url: " .. download_base .. "a.zip\nsha256: " .. hash_a
        .. "\n\nurl: " .. download_base .. "b.zip\nsha256: " .. hash_b .. "\n")
end)

test("resolve empty releases produce an empty JSON array or empty text", function()
    for _, format in ipairs { "text", "json" } do
        local result = run(release_routes(json.decode("[]")), "--resolve", "github-release", "owner/repo", "--format", format)
        assert(t.success(result) == (format == "text" and "" or "[]\n"))
    end
end)

test("resolve takes all assets directly from the selected release", function()
    local assets = {}
    for i = 1, 101 do assets[i] = asset(("tool-%03d.zip"):format(i), hash_a) end
    assets[101].digest = "sha256:" .. hash_b
    local routes = release_routes(assets)
    local result = run(routes, "--resolve", "github-release", "owner/repo", "--format", "json")
    local values = json.decode(t.success(result))
    assert(#values == 101 and values[101].sha256 == hash_b and #result.requests == 1)
end)

test("resolve falls back to streamed hashing for missing digests", function()
    local routes = release_routes { asset("a.zip"), asset("b.zip") }
    routes[download_base .. "a.zip"] = { chunks = { "a", "\0", "b" } }
    routes[download_base .. "b.zip"] = "second"
    local result = run(routes, "--resolve", "github-release", "owner/repo", "--format", "json")
    local values = json.decode(t.success(result))
    assert(values[1].sha256 == sha256 { bytes = "a\0b" } and values[2].sha256 == sha256 { bytes = "second" })
end)

test("resolve treats checksum files as ordinary assets without inferring hashes", function()
    local routes = release_routes { asset("a.zip"), asset("checksums.txt") }
    routes[download_base .. "checksums.txt"] = hash_a .. " *a.zip\n"
    routes[download_base .. "a.zip"] = "real"
    local result = run(routes, "--resolve", "github-release", "owner/repo", "--format", "json")
    assert(json.decode(t.success(result))[1].sha256 == sha256 { bytes = "real" })
end)

test("resolve streams enforce decimal MB budgets without Content-Length", function()
    local url = "https://example.com/file"
    local bytes = string.rep("x", 1000000)
    local result = run({ [url] = bytes }, "--resolve", "url", url, "--max-download-mb", "1")
    assert(t.success(result):find(sha256 { bytes = bytes }, 1, true))
    result = run({ [url] = bytes:sub(1, 500000) }, "--resolve", "url", url, "--max-download-mb", "0.5")
    t.success(result)
    result = run({ [url] = { chunks = { bytes, "x" } } }, "--resolve", "url", url, "--max-download-mb", "1")
    t.failure(result, "download budget exhausted")
    assert(result.stderr:find("1 MB shared limit for metadata and file bodies", 1, true), result.stderr)
    assert(result.stderr:find(".cmd --resolve --max-download-mb 64 ...", 1, true), result.stderr)
    assert(not result.stderr:find("resolve.lua:", 1, true), result.stderr)
    assert(result.stdout == "")
end)

test("resolve budget counts metadata and stops before oversized assets", function()
    local routes = release_routes { asset("large.zip", nil, 400000), asset("small.zip", nil, 5) }
    routes[api_base .. "/releases/latest"] = routes[api_base .. "/releases/latest"] .. string.rep(" ", 700000)
    routes[download_base .. "small.zip"] = "small"
    local result = run(routes, "--resolve", "github-release", "owner/repo", "--max-download-mb", "1", "--format", "json")
    t.failure(result, "download budget exhausted")
    assert(result.stderr:find("1 MB shared limit", 1, true), result.stderr)
    assert(result.stderr:find("--max-download-mb 64", 1, true), result.stderr)
    assert(result.stdout == "" and #result.requests == 1)
end)

test("resolve actual bodies can exceed reported sizes without emitting partial hashes", function()
    local routes = release_routes { asset("a.zip", nil, 1), asset("b.zip", hash_b), asset("c.zip", nil, 1) }
    routes[download_base .. "a.zip"] = { chunks = { string.rep("x", 500000), string.rep("y", 500000) } }
    local result = run(routes, "--resolve", "github-release", "owner/repo", "--max-download-mb", "1", "--format", "json")
    t.failure(result, "download budget exhausted")
    assert(result.stdout == "" and #result.requests == 2)
end)

test("resolve stops on transport failure without emitting partial results", function()
    local routes = release_routes { asset("first.zip", hash_b), asset("a.zip"), asset("b.zip") }
    routes[download_base .. "a.zip"] = { chunks = { "partial" }, error = "http: interrupted" }
    local result = run(routes, "--resolve", "github-release", "owner/repo", "--format", "json")
    t.failure(result, "http: interrupted")
    assert(result.stdout == "" and #result.requests == 2)
end)

test("resolve propagates output write failures even when the final flush succeeds", function()
    local url = "https://example.com/file"
    for _, case in ipairs {
        { 1, "url", url },
        { 1, "url", url, "--format", "json" },
        { 1, "github-release", "owner/repo", "--format", "json" },
        { 2, "github-release", "owner/repo" },
    } do
        local routes = release_routes { asset("a.zip", hash_a), asset("b.zip", hash_b) }
        routes[url] = "file"
        local writes = 0
        routes.stdout = { write = function(self)
            writes = writes + 1
            if writes == case[1] then return nil, "stdout write failed" end
            return self
        end }
        local result = run(routes, "--resolve", table.unpack(case, 2))
        t.failure(result, "stdout write failed")
        assert(writes == case[1])
    end
end)

test("resolve metadata errors and zero budgets fail cleanly", function()
    local result = run({ [api_base .. "/releases/latest"] = { error = "http: HTTP status 404" } },
        "--resolve", "github-release", "owner/repo", "--format", "json")
    t.failure(result, "http: HTTP status 404")
    assert(result.stdout == "")
    result = run({}, "--resolve", "url", "https://example.com/file", "--max-download-mb", "0")
    t.failure(result, "download budget exhausted")
    assert(result.stderr:find("0 MB shared limit", 1, true), result.stderr)
    assert(result.stderr:find("--max-download-mb 64", 1, true), result.stderr)
    assert(#result.requests == 0 and result.stdout == "")
end)

test("resolve help documents modes, units, format and first-error behavior", function()
    local result = run({}, "--help", "--resolve")
    local output = t.success(result)
    for _, expected in ipairs { "github-file", "github-release", "url", "--format", "--max-download-mb",
        "1 MB = 1,000,000 bytes", "default: 64", "Stops on the first error" } do
        assert(output:find(expected, 1, true), output)
    end
    output = t.success(run({}, "--help", "--resolve", "github-release"))
    for _, expected in ipairs { "--asset", "default: *", "Case-sensitive", "? matches one", "Quote the glob", "no matches produce []" } do
        assert(output:find(expected, 1, true), output)
    end
end)

test("resolve rejects invalid formats, limits, repositories and options", function()
    for _, argv in ipairs {
        { "url", "https://example.com/file", "--format", "lua" },
        { "url", "https://example.com/file", "--max-download-mb", "not-a-number" },
        { "github-file", "owner", "file" },
        { "url", "https://example.com/file", "--json" },
    } do
        local result = run({}, "--resolve", table.unpack(argv))
        assert(result.code == 2 and result.stdout == "" and #result.requests == 0, result.stderr)
    end
end)
