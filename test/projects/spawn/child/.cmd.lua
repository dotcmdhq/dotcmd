return {
    ordered = function()
        local t = assert(loadfile(host.project_dir .. "/../../support.lua"))()
        io.stdout:setvbuf("full", 4096); io.stderr:setvbuf("full", 4096)
        io.write("before:"); io.stderr:write("before:")
        local process <close> = spawn(t.command(host.project_dir, "emit"))
        process:wait()
        io.write(":after"); io.stderr:write(":after")
    end,
    noop = function() end,
    emit = function()
        io.write("OUT\0\255"); io.stderr:write("ERR\0\254")
    end,
    echo = function()
        io.write(io.read("a"))
    end,
    hold = function()
        io.write("ready\n"); io.flush()
        io.read("l")
    end,
    capture_then_signal = function()
        io.write(string.rep("o", 4194304)); io.flush()
        io.stderr:write("ready\n"); io.stderr:flush()
        io.read("l")
    end,
    large = function()
        for _ = 1, 64 do
            io.write(string.rep("o", 65536)); io.stderr:write(string.rep("e", 65536))
        end
    end,
    context = function(...)
        print(host.cwd)
        print(os.getenv("DOTCMD_SPAWN_SET"))
        print(os.getenv("USERPROFILE") or "<missing>")
        for i = 1, select("#", ...) do io.write(select(i, ...), "\0") end
    end,
    status = function()
        io.stderr:write("child failure"); error({ exit_code = 17 })
    end,
}
