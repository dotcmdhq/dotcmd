-- Projects return {name = function(...) ... end} or
-- {name = {description = "...", run = function(...) ... end}} from .cmd.lua.
-- The project chunk receives host as its argument; commands receive CLI strings.
function main(args, host)
    local launcher
    if args[1] == "--launcher" then
        table.remove(args, 1)
        launcher = table.remove(args, 1)
    end

    if args[1] == "--version" then
        print("dotcmd " .. host.version)
        return 0
    end
    if args[1] == "--licenses" then
        io.write(host.licenses)
        return 0
    end

    launcher = launcher or (host.cwd .. "/.cmd")
    if host.os == "windows" then launcher = launcher:gsub("\\", "/") end
    if launcher:sub(1, 1) ~= "/" and not (host.os == "windows" and launcher:match("^%a:/")) then
        launcher = host.cwd .. "/" .. launcher
    end
    host.project_dir = launcher:match("^(.*)/")
    if host.project_dir == "" then host.project_dir = "/" end
    local project = assert(loadfile(host.project_dir .. "/.cmd.lua", "t"))
    local commands = project(host)
    if type(commands) ~= "table" then error(".cmd.lua must return a command table") end

    local names = {}
    for name, command in pairs(commands) do
        if type(name) ~= "string" or name == "" then error("command names must be nonempty strings") end
        if type(command) ~= "function" then
            if type(command) ~= "table" or type(command.run) ~= "function" then
                error("command " .. name .. " must be a function or a table with a run function")
            end
            if command.description ~= nil and type(command.description) ~= "string" then
                error("description for command " .. name .. " must be a string")
            end
        end
        names[#names + 1] = name
    end

    local name = args[1]
    if name == nil or name == "--help" or name == "-h" then
        print("Usage: .cmd <command> [args...]")
        print("\nCommands:")
        table.sort(names)
        for _, key in ipairs(names) do
            local command = commands[key]
            local description = type(command) == "table" and command.description
            print("  " .. key .. (description and ("  " .. description) or ""))
        end
        print("\nOptions:\n  -h, --help  Show help\n  --version  Show dotcmd version\n  --licenses  Show dependency licenses")
        return 0
    end

    local command = commands[name]
    if command == nil then
        io.stderr:write("dotcmd: unknown command: " .. name .. "\n")
        return 1
    end
    local run = type(command) == "function" and command or command.run
    local code = run(table.unpack(args, 2))
    if code == nil then return 0 end
    if math.type(code) ~= "integer" or code < 0 or code > 255 then
        error("command " .. name .. " must return nil or an integer exit code between 0 and 255")
    end
    return code
end
