test('http rejects an insecure scheme', function()
    t.assert_error('http:', function() http('http://127.0.0.1/') end)
end)

test('http rejects invalid headers', function()
    t.assert_error('http:', function()
        http{url='https://127.0.0.1/', headers={X='bad\r\nheader'}}
    end)
end)

test('http rejects a negative timeout', function()
    t.assert_error('http:', function() http{url='https://127.0.0.1/', timeout=-1} end)
end)

test('http rejects a URL containing NUL', function()
    t.assert_error('http:', function() http{url='https://127.0.0.1/\0suffix'} end)
end)
