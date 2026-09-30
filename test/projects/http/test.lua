local url = assert(os.getenv("DOTCMD_TEST_URL"))
local bytes = "hello\0\255world"

test("http downloads binary responses in both argument forms", function()
    local response = http(url .. "/body")
    assert(response.status == 200 and response.body == bytes)
    assert(response.url == url .. "/body")
    assert(response.headers["content-type"][1] == "application/octet-stream")
    assert(http { url = url .. "/body" }.body == bytes)
end)

test("http sends methods and binary request bodies", function()
    for _, method in ipairs { "GET", "POST", "PUT", "PATCH", "DELETE", "CUSTOM" } do
        local response = http { url = url .. "/echo", method = method, body = bytes }
        assert(response.status == 200 and response.body == bytes)
        assert(response.headers["x-method"][1] == method)
    end
end)

test("http preserves repeated request and response headers", function()
    local response = http { url = url .. "/echo", headers = { ["X-Test"] = { "first", "second", "" } } }
    local seen = response.headers["x-seen"]
    assert(#seen == 3 and seen[1] == "first" and seen[2] == "second" and seen[3] == "")
    local cookies = response.headers["set-cookie"]
    assert(#cookies == 2 and cookies[1] == "first=1" and cookies[2] == "second=2")
    assert(http { url = url .. "/echo", headers = { ["X-Test"] = "single" } }.headers["x-seen"][1] == "single")
    assert(response.headers["x-user-agent"][1] == "dotcmd/" .. t.version())
    response = http { url = url .. "/echo", headers = { ["User-Agent"] = "custom/1.0" } }
    assert(response.headers["x-user-agent"][1] == "custom/1.0")
end)

test("http HEAD and 204 responses have no body", function()
    local response = http { url = url .. "/body", method = "HEAD" }
    assert(response.status == 200 and response.body == "")
    assert(tonumber(response.headers["content-length"][1]) == #bytes)
    response = http { url = url .. "/status/204" }
    assert(response.status == 204 and response.body == "")
end)

test("http checks error statuses by default and can disable checking", function()
    for _, code in ipairs { 404, 500 } do
        local response = http { url = url .. "/status/" .. code, check = false }
        assert(response.status == code and response.body == "status body")
        t.assert_error("HTTP status " .. code, function()
            http(url .. "/status/" .. code)
        end)
    end
end)

test("http follows redirects and keeps only the final response", function()
    for _, target in ipairs { "/body", url .. "/body" } do
        local response = http(url .. "/redirect/302?to=" .. target)
        assert(response.status == 200 and response.body == bytes)
        assert(response.headers["x-redirect-only"] == nil and response.headers.location == nil)
        assert(response.url == url .. "/body")
    end
end)

test("http exposes the final URL for HEAD requests", function()
    local response = http { url = url .. "/redirect/302?to=/body", method = "HEAD" }
    assert(response.url == url .. "/body" and response.body == "")
end)

test("http redirect status controls the method and body", function()
    local response = http { url = url .. "/redirect/303?to=/echo", method = "POST", body = bytes }
    assert(response.headers["x-method"][1] == "GET" and response.body == "")
    for _, code in ipairs { 301, 302, 307, 308 } do
        response = http { url = url .. "/redirect/" .. code .. "?to=/echo", method = "PUT", body = bytes }
        assert(response.headers["x-method"][1] == "PUT" and response.body == bytes)
    end
end)

test("http rejects redirect loops and HTTPS downgrades", function()
    for _, path in ipairs { "/loop", "/redirect/302?to=http://127.0.0.1/" } do
        t.assert_error("http:", function() http { url = url .. path, timeout = 5 } end)
    end
end)

test("http saves downloads relative to cwd and replaces existing files", function()
    local path = "download ü.bin"
    t.write(path, string.rep("old contents", 100))
    local response = http { url = url .. "/redirect/302?to=/body", to = path }
    assert(response.status == 200 and response.body == nil and t.read(path) == bytes)
    assert(response.headers["x-redirect-only"] == nil)
end)

test("http failed statuses preserve files and remove temporary downloads", function()
    fs.mkdir("status")
    t.write("status/existing", "keep me")
    for _, path in ipairs { "status/existing", "status/missing" } do
        local response = http { url = url .. "/status/404", to = path, check = false }
        assert(response.status == 404 and response.body == nil)
        t.assert_error("HTTP status 500", function()
            http { url = url .. "/status/500", to = path }
        end)
    end
    assert(t.read("status/existing") == "keep me" and fs.stat("status/missing") == nil)
    for name in fs.list("status") do assert(name == "existing", name) end
end)

test("http timeouts and interrupted downloads preserve files and clean up", function()
    fs.mkdir("interrupted")
    t.write("interrupted/existing", "keep me")
    for _, endpoint in ipairs { "/slow", "/truncated" } do
        t.assert_error("http:", function() http { url = url .. endpoint, timeout = 1 } end)
        for _, path in ipairs { "interrupted/existing", "interrupted/missing" } do
            t.assert_error("http:", function() http { url = url .. endpoint, to = path, timeout = 1 } end)
        end
    end
    assert(t.read("interrupted/existing") == "keep me" and fs.stat("interrupted/missing") == nil)
    for name in fs.list("interrupted") do assert(name == "existing", name) end
end)

test("http reports output file errors", function()
    t.assert_error("http:", function() http { url = url .. "/body", to = "missing-parent/out" } end)
    fs.mkdir("directory")
    t.assert_error("http:", function() http { url = url .. "/body", to = "directory" } end)
    assert(fs.stat("directory").type == "directory")
end)

test("http verifies certificate trust and hostname", function()
    local client = t.project("client", [[
return {get = function(url) io.write(http(url).body) end}
]])
    assert(t.success(t.run_project(client, "get", url .. "/body")) == bytes)
    t.failure(t.run_project(client, { env = { SSL_CERT_FILE = false, SSL_CERT_DIR = false } },
        "get", url .. "/body"), "http:")
    t.failure(t.run_project(client, "get", url:gsub("127%.0%.0%.1", "localhost") .. "/body"), "http:")
    t.write("invalid CA.pem", "not a certificate")
    t.failure(t.run_project(client, { env = { SSL_CERT_FILE = host.cwd .. "/invalid CA.pem" } },
        "get", url .. "/body"), "http:")
end)

test("http rejects an insecure scheme", function()
    t.assert_error("http:", function() http("http://127.0.0.1/") end)
end)

test("http rejects invalid headers", function()
    t.assert_error("http:", function()
        http { url = "https://127.0.0.1/", headers = { X = "bad\r\nheader" } }
    end)
end)

test("http rejects a negative timeout", function()
    t.assert_error("http:", function() http { url = "https://127.0.0.1/", timeout = -1 } end)
end)

test("http rejects a URL containing NUL", function()
    t.assert_error("http:", function() http { url = "https://127.0.0.1/\0suffix" } end)
end)

test("http streams final response bodies into SHA-256", function()
    for _, path in ipairs { "/body", "/redirect/302?to=/body", "/redirect/307?to=/redirect/302?to=/body" } do
        local response = http { url = url .. path, to = sha256 }
        assert(response.status == 200 and response.url == url .. "/body")
        assert(response.body == sha256 { bytes = bytes })
        assert(response.headers["x-redirect-only"] == nil)
    end
    for _, options in ipairs {
        { url = url .. "/body", method = "HEAD", to = sha256 },
        { url = url .. "/status/204", to = sha256 },
    } do
        local response = http(options)
        assert(response.body == sha256 { bytes = "" })
    end
end)

test("http composes consumers over a large chunked response", function()
    local initialized, completed, calls = 0, 0, 0
    local function counted_hash()
        initialized = initialized + 1
        local consume, count = sha256(), 0
        return function(...)
            if select("#", ...) == 0 then
                completed = completed + 1
                return { bytes = count, digest = consume() }
            end
            assert(select("#", ...) == 1)
            local chunk = ...
            assert(type(chunk) == "string")
            calls = calls + 1
            count = count + #chunk
            consume(chunk)
            return "ignored"
        end
    end
    local response = http { url = url .. "/chunks", to = counted_hash }
    assert(initialized == 1 and completed == 1 and calls > 1)
    assert(response.body.bytes == 1024 * 1024)
    assert(response.body.digest == sha256 { bytes = string.rep("a\0\255b", 262144) })
end)

test("http consumer failures abort transfers and preserve error objects", function()
    local failure = { message = "byte limit exceeded" }
    local completed, received = false, 0
    local ok, err = pcall(http, {
        url = url .. "/slow", timeout = 5,
        to = function()
            return function(chunk)
                if chunk == nil then completed = true; return end
                received = received + #chunk
                assert(received <= 0, failure)
            end
        end,
    })
    assert(not ok and err == failure and received > 0 and not completed)
    assert(http { url = url .. "/body", to = sha256 }.body == sha256 { bytes = bytes })
end)

test("http skips consumer completion after transport or checked status failures", function()
    for _, path in ipairs { "/truncated", "/slow", "/status/404", "/loop" } do
        local completed, initialized = false, 0
        t.assert_error("http:", function()
            http { url = url .. path, timeout = 1,
                to = function()
                    initialized = initialized + 1
                    return function(chunk)
                        if chunk == nil then completed = true end
                    end
                end,
            }
        end)
        assert(initialized == 1 and not completed)
    end
    local response = http { url = url .. "/status/404", check = false, to = sha256 }
    assert(response.status == 404)
    assert(response.body == sha256 { bytes = "status body" })
end)

test("http propagates factory and completion errors and requires a consumer function", function()
    local failure = {}
    local ok, err = pcall(http, { url = url .. "/body", to = function() error(failure) end })
    assert(not ok and err == failure)
    ok, err = pcall(http, { url = url .. "/body", to = function()
        return function(chunk)
            if chunk == nil then error(failure) end
        end
    end })
    assert(not ok and err == failure)
    t.assert_error("function expected", function()
        http { url = url .. "/body", to = function() return 123 end }
    end)
end)

test("http consumers preserve false and nil results and support nested requests", function()
    for _, expected in ipairs { false, "value" } do
        local response = http { url = url .. "/body", to = function()
            return function(chunk)
                if chunk == nil then return expected, "ignored" end
            end
        end }
        assert(response.body == expected)
    end
    local nested = false
    local response = http { url = url .. "/body", to = function()
        return function(chunk)
            if chunk ~= nil then
                assert(http { url = url .. "/body", to = sha256 }.body == sha256 { bytes = bytes })
                nested = true
                collectgarbage("collect")
            end
        end
    end }
    assert(nested and response.body == nil)
end)
