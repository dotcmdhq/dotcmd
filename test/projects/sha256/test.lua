---@type dotcmd.Env|_G
local _ENV = _ENV

test('sha256 known vectors and binary strings', function()
    assert(sha256 { bytes = '' } == 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')
    assert(sha256 { bytes = 'abc' } == 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
    assert(sha256 { bytes = string.rep('a', 1000000) } == 'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0')
    assert(sha256 { bytes = 'a\0\255b' } == 'fcd85e9c993cd598fe7a2088e571af403a43adbc2ff8a39a4e67aec0dc69d960')
end)

test('sha256 streamed files and file errors', function()
    t.write('million', string.rep('a', 1000000))
    assert(sha256 { path = 'million' } == 'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0')
    t.write('empty', '')
    assert(sha256 { path = 'empty' } == 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')
    t.assert_error('sha256:', function() sha256 { path = 'missing' } end)
    t.assert_error('sha256:', function() sha256 { path = 'bad\0path' } end)
end)

test('sha256 requires an explicit and unambiguous source', function()
    t.assert_error('table expected', function() sha256('abc') end)
    t.assert_error("specify exactly one of 'bytes' or 'path'", function() sha256 {} end)
    t.assert_error("specify exactly one of 'bytes' or 'path'", function()
        sha256 { bytes = '', path = 'missing' }
    end)
    t.write('literal', 'file contents')
    assert(sha256 { bytes = 'literal' } ~= sha256 { path = 'literal' })
end)
