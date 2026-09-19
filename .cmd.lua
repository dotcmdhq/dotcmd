---@type dotcmd.Env|_G
local _ENV = _ENV

local windows = host.os == "windows"
local binary = host.project_dir .. "/target/release/dotcmd" .. (windows and ".exe" or "")

local function build()
    local command = windows
        and { "powershell.exe", "-NoProfile", "-File", host.project_dir .. "/build.ps1", "--release" }
        or { host.project_dir .. "/build", "--release" }
    command.cwd = host.project_dir
    if windows then command.env = { PSModulePath = false } end
    return exec(command)
end

return {
    ["local"] = {
        description = "Build and run the local dotcmd executable",
        run = function(...)
            local code = build()
            if code ~= 0 then return code end

            return exec(binary, "--launcher", host.project_dir .. "/.cmd", ...)
        end,
    },
    test = {
        description = "Build once and test .cmd in fixture projects",
        run = function()
            local code = build()
            if code ~= 0 then return code end
            -- Run the Lua harness with the new executable. The published
            -- bootstrap version need not contain the APIs being tested.
            local output = host.project_dir .. "/target/release/"
            local source <close> = assert(io.open(host.project_dir .. "/.cmd", "rb"))
            local launcher <close> = assert(io.open(output .. ".cmd", "wb"))
            assert(launcher:write(source:read("a"))); assert(launcher:close())
            local project <close> = assert(io.open(output .. ".cmd.lua", "wb"))
            assert(project:write(("return {test = assert(loadfile(%q))()}\n"):format(host.project_dir .. "/test/run.lua")))
            assert(project:close())
            return exec(binary, "--launcher", output .. ".cmd", "test", host.project_dir)
        end,
    },
}
