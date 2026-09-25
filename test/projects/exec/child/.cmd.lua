---@type dotcmd.Env|_G
local _ENV = _ENV

return {
    ordered = function()
        local t = assert(loadfile(host.project_dir .. '/../../support.lua'))()
        io.stdout:setvbuf('full', 4096); io.stderr:setvbuf('full', 4096)
        io.write('before:'); io.stderr:write('before:')
        exec(t.command(host.project_dir, 'emit'))
        io.write(':after'); io.stderr:write(':after')
    end,
    inherit = function()
        local t = assert(loadfile(host.project_dir .. '/../../support.lua'))()
        exec(t.command(host.project_dir, 'emit'))
    end,
    emit = function()
        io.write('OUT\0\255'); io.stderr:write('ERR\0\254')
    end,
    large = function()
        io.stdout:setvbuf('no'); io.stderr:setvbuf('no')
        for i = 1, 64 do
            io.write(string.rep('o', 65536)); io.stderr:write(string.rep('e', 65536))
        end
    end,
    env = function(...)
        for i = 1, select('#', ...) do print(os.getenv(select(i, ...)) or '<missing>') end
    end,
    cwd = function() print(host.cwd) end,
    status = function(code)
        io.stderr:write('child failure'); error({ exit_code = tonumber(code) })
    end,
}
