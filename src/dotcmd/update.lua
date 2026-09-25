---@type dotcmd.Env|_G
local _ENV = _ENV

return function(launcher, version)
    local target = fs.realpath(launcher)
    local info = assert(fs.stat(target))
    local base = 'https://github.com/dotcmdhq/dotcmd/releases/'
    if version == 'latest' then
        local response = http { url = base .. 'latest', method = 'HEAD' }
        local tag = assert(response.url:match('^https://github%.com/dotcmdhq/dotcmd/releases/tag/([^?#]+)$'),
            'could not resolve latest release tag')
        version = tag:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
    end
    if version == host.version then
        print(launcher .. ' is already up to date (' .. version .. ')')
        return
    end
    local tag = version:gsub('[^%w._~-]', function(byte) return ('%%%02X'):format(byte:byte()) end)
    local temp = target .. '.tmp-' .. ('%016x%016x'):format(math.random(0), math.random(0))
    local cleanup <close> = setmetatable({}, { __close = function() fs.remove(temp) end })
    http { url = base .. 'download/' .. tag .. '/dotcmd.cmd', to = temp }
    fs.chmod(temp, info.mode)
    fs.rename(temp, target, { if_exists = 'replace' })
    print('Updated ' .. launcher .. ' to ' .. version)
end
