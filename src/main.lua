-- Embedded entry point. Arguments exclude the executable / launcher name.
function main(args, host)
    if args[1] == "--licenses" then
        io.write(host.licenses)
        return 0
    end

    print("dotcmd", host.version)
    print("Lua", host.lua_version)
    print("platform", host.os, host.arch)
    print("build", host.build)
    print("compiler", host.compiler)
    print("executable", host.executable)
    print("cwd", host.cwd)
    print("argc", #args)
    for i, value in ipairs(args) do
        print(("arg[%d] = %q"):format(i, value))
    end
    return 0
end
