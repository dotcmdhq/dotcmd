local url = assert(os.getenv("DOTCMD_TEST_URL"))
local values_source = [[dotcmd_plugin_test_calls = (dotcmd_plugin_test_calls or 0) + 1
return "value", nil, false, dotcmd_plugin_test_calls, type(fetch) .. ":" .. host.os]]
local syntax_source = [[return function(]]
local runtime_source = [[error("plugin runtime failure")]]

local function cache_path(hash, name)
    return host.cache_dir .. "/downloads/" .. hash .. "/" .. name
end

test("plugin executes a source SHA-256 once and caches all of its values", function()
    dotcmd_plugin_test_calls = nil
    local hash = sha256 { bytes = values_source }
    local values = table.pack(plugin(url .. "/plugin/values", hash))
    assert(values.n == 5)
    assert(values[1] == "value" and values[2] == nil and values[3] == false)
    assert(values[4] == 1 and values[5] == "function:" .. host.os)

    values = table.pack(plugin(url .. "/plugin/values", hash))
    assert(values.n == 5 and values[4] == 1)
end)

test("plugin identifies cached plugins by SHA-256 rather than URL", function()
    local source = "return {}"
    local hash = sha256 { bytes = source }
    local first = plugin(url .. "/plugin/table", hash)
    local second = plugin(url .. "/another/location.lua", hash)
    assert(first == second)
end)

test("plugin rejects source tables and missing hashes", function()
    local hash = sha256 { bytes = values_source }
    assert(not pcall(plugin, { url = url .. "/plugin/values", sha256 = hash }))
    assert(not pcall(plugin, url .. "/plugin/values"))
end)

test("plugin rejects wrong hashes without executing source", function()
    dotcmd_plugin_test_calls = nil
    t.assert_error("SHA-256 mismatch for " .. url .. "/plugin/values", function()
        plugin(url .. "/plugin/values", string.rep("0", 64))
    end)
    assert(dotcmd_plugin_test_calls == nil)
end)

test("plugin does not reread cached source", function()
    dotcmd_plugin_test_calls = nil
    local source = values_source .. "\n-- independently cached"
    local hash = sha256 { bytes = source }
    fs.mkdir(host.cache_dir .. "/downloads/" .. hash)
    t.write(cache_path(hash, "500"), source)
    assert(select(4, plugin(url .. "/status/500", hash)) == 1)
    t.write(cache_path(hash, "500"), "return \"corrupted\"")
    assert(select(4, plugin(url .. "/status/500", hash)) == 1)
    assert(dotcmd_plugin_test_calls == 1)
end)

test("plugin only accepts text chunks", function()
    local bytecode = string.dump(function() return "bytecode" end)
    local hash = sha256 { bytes = bytecode }
    fs.mkdir(host.cache_dir .. "/downloads/" .. hash)
    t.write(cache_path(hash, "500"), bytecode)
    t.assert_error("binary chunk", function()
        plugin(url .. "/status/500", hash)
    end)
end)

test("plugin source names identify their URL in compile and runtime errors", function()
    local syntax_url = url .. "/plugin/syntax"
    t.assert_error(syntax_url, function() plugin(syntax_url, sha256 { bytes = syntax_source }) end)
    local runtime_url = url .. "/plugin/runtime"
    t.assert_error(runtime_url, function() plugin(runtime_url, sha256 { bytes = runtime_source }) end)
    t.assert_error("plugin runtime failure", function() plugin(runtime_url, sha256 { bytes = runtime_source }) end)
end)
