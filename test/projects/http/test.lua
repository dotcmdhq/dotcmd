local url = assert(os.getenv('DOTCMD_TEST_URL'))
local bytes = 'hello\0\255world'

test('http downloads binary responses in both argument forms', function()
    local response = http(url .. '/body')
    assert(response.status == 200 and response.body == bytes)
    assert(response.url == url .. '/body')
    assert(response.headers['content-type'][1] == 'application/octet-stream')
    assert(http { url = url .. '/body' }.body == bytes)
end)

test('http sends methods and binary request bodies', function()
    for _, method in ipairs { 'GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'CUSTOM' } do
        local response = http { url = url .. '/echo', method = method, body = bytes }
        assert(response.status == 200 and response.body == bytes)
        assert(response.headers['x-method'][1] == method)
    end
end)

test('http preserves repeated request and response headers', function()
    local response = http { url = url .. '/echo', headers = { ['X-Test'] = { 'first', 'second', '' } } }
    local seen = response.headers['x-seen']
    assert(#seen == 3 and seen[1] == 'first' and seen[2] == 'second' and seen[3] == '')
    local cookies = response.headers['set-cookie']
    assert(#cookies == 2 and cookies[1] == 'first=1' and cookies[2] == 'second=2')
    assert(http { url = url .. '/echo', headers = { ['X-Test'] = 'single' } }.headers['x-seen'][1] == 'single')
end)

test('http HEAD and 204 responses have no body', function()
    local response = http { url = url .. '/body', method = 'HEAD' }
    assert(response.status == 200 and response.body == '')
    assert(tonumber(response.headers['content-length'][1]) == #bytes)
    response = http { url = url .. '/status/204' }
    assert(response.status == 204 and response.body == '')
end)

test('http checks error statuses by default and can disable checking', function()
    for _, code in ipairs { 404, 500 } do
        local response = http { url = url .. '/status/' .. code, check = false }
        assert(response.status == code and response.body == 'status body')
        t.assert_error('HTTP status ' .. code, function()
            http(url .. '/status/' .. code)
        end)
    end
end)

test('http follows redirects and keeps only the final response', function()
    for _, target in ipairs { '/body', url .. '/body' } do
        local response = http(url .. '/redirect/302?to=' .. target)
        assert(response.status == 200 and response.body == bytes)
        assert(response.headers['x-redirect-only'] == nil and response.headers.location == nil)
        assert(response.url == url .. '/body')
    end
end)

test('http exposes the final URL for HEAD requests', function()
    local response = http { url = url .. '/redirect/302?to=/body', method = 'HEAD' }
    assert(response.url == url .. '/body' and response.body == '')
end)

test('http redirect status controls the method and body', function()
    local response = http { url = url .. '/redirect/303?to=/echo', method = 'POST', body = bytes }
    assert(response.headers['x-method'][1] == 'GET' and response.body == '')
    for _, code in ipairs { 301, 302, 307, 308 } do
        response = http { url = url .. '/redirect/' .. code .. '?to=/echo', method = 'PUT', body = bytes }
        assert(response.headers['x-method'][1] == 'PUT' and response.body == bytes)
    end
end)

test('http rejects redirect loops and HTTPS downgrades', function()
    for _, path in ipairs { '/loop', '/redirect/302?to=http://127.0.0.1/' } do
        t.assert_error('http:', function() http { url = url .. path, timeout = 5 } end)
    end
end)

test('http saves downloads relative to cwd and replaces existing files', function()
    local path = 'download ü.bin'
    t.write(path, string.rep('old contents', 100))
    local response = http { url = url .. '/redirect/302?to=/body', to = path }
    assert(response.status == 200 and response.body == nil and t.read(path) == bytes)
    assert(response.headers['x-redirect-only'] == nil)
end)

test('http failed statuses preserve files and remove temporary downloads', function()
    fs.mkdir('status')
    t.write('status/existing', 'keep me')
    for _, path in ipairs { 'status/existing', 'status/missing' } do
        local response = http { url = url .. '/status/404', to = path, check = false }
        assert(response.status == 404 and response.body == nil)
        t.assert_error('HTTP status 500', function()
            http { url = url .. '/status/500', to = path }
        end)
    end
    assert(t.read('status/existing') == 'keep me' and fs.stat('status/missing') == nil)
    for name in fs.list('status') do assert(name == 'existing', name) end
end)

test('http timeouts and interrupted downloads preserve files and clean up', function()
    fs.mkdir('interrupted')
    t.write('interrupted/existing', 'keep me')
    for _, endpoint in ipairs { '/slow', '/truncated' } do
        t.assert_error('http:', function() http { url = url .. endpoint, timeout = 1 } end)
        for _, path in ipairs { 'interrupted/existing', 'interrupted/missing' } do
            t.assert_error('http:', function() http { url = url .. endpoint, to = path, timeout = 1 } end)
        end
    end
    assert(t.read('interrupted/existing') == 'keep me' and fs.stat('interrupted/missing') == nil)
    for name in fs.list('interrupted') do assert(name == 'existing', name) end
end)

test('http reports output file errors', function()
    t.assert_error('http:', function() http { url = url .. '/body', to = 'missing-parent/out' } end)
    fs.mkdir('directory')
    t.assert_error('http:', function() http { url = url .. '/body', to = 'directory' } end)
    assert(fs.stat('directory').type == 'directory')
end)

test('http verifies certificate trust and hostname', function()
    local client = t.project('client', [[
return {get = function(url) io.write(http(url).body) end}
]])
    assert(t.success(t.run_project(client, 'get', url .. '/body')) == bytes)
    t.failure(t.run_project(client, { env = { SSL_CERT_FILE = false, SSL_CERT_DIR = false } },
        'get', url .. '/body'), 'http:')
    t.failure(t.run_project(client, 'get', url:gsub('127%.0%.0%.1', 'localhost') .. '/body'), 'http:')
    t.write('invalid CA.pem', 'not a certificate')
    t.failure(t.run_project(client, { env = { SSL_CERT_FILE = host.cwd .. '/invalid CA.pem' } },
        'get', url .. '/body'), 'http:')
end)

test('http rejects an insecure scheme', function()
    t.assert_error('http:', function() http('http://127.0.0.1/') end)
end)

test('http rejects invalid headers', function()
    t.assert_error('http:', function()
        http { url = 'https://127.0.0.1/', headers = { X = 'bad\r\nheader' } }
    end)
end)

test('http rejects a negative timeout', function()
    t.assert_error('http:', function() http { url = 'https://127.0.0.1/', timeout = -1 } end)
end)

test('http rejects a URL containing NUL', function()
    t.assert_error('http:', function() http { url = 'https://127.0.0.1/\0suffix' } end)
end)
