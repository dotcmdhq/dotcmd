assert(type(host) == 'table') -- Available while loading the project, not just in commands.
assert(select('#', ...) == 0)
local function hex(value)
    return (value:gsub('.', function(c) return ('%02x'):format(c:byte()) end))
end
return {
    args = {description = 'Print arguments as hex', run = function(...)
        print(select('#', ...))
        for i = 1, select('#', ...) do print(hex(select(i, ...))) end
    end},
    context = function() print(host.cwd); print(host.project_dir); print(host.os); print(host.arch) end,
    status = function(code) return tonumber(code) end,
    nothing = function() end,
    invalid = function() return false end,
    crash = function() error('intentional project error') end,
}
