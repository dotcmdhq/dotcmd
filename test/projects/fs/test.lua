test("fs read and write binary files and create parents by default", function()
    local path = "write ü/nested/file"
    local bytes = ("a\0\255\r\n"):rep(20000)
    assert(fs.read(path) == nil)
    assert(fs.write(path, bytes) == true)
    assert(fs.read(path) == bytes)
    assert(fs.write(path, bytes) == true) -- replace never compares old contents
    assert(fs.write(path, "") == true)
    assert(fs.read(path) == "")
    t.assert_error("fs.write:", function() fs.write("no-parents/file", "x", { parents = false }) end)
    assert(not fs.stat("no-parents"))
    fs.mkdir("no-parents")
    assert(fs.write("no-parents/file", "x", { parents = false }))
    t.assert_error("fs.read:", function() fs.read("write ü") end)
    t.assert_error("fs.write:", function() fs.write("write ü", "x") end)
    t.assert_error("fs.write:", function() fs.write("trailing/", "x") end)
    assert(not fs.stat("trailing"))
end)

test("fs write existence policies and invalid arguments", function()
    for _, policy in ipairs({ "error", "skip", "replace" }) do
        local path = "policy-" .. policy
        assert(fs.write(path, "first", { if_exists = policy }))
        if policy == "error" then
            t.assert_error("already exists", function() fs.write(path, "second", { if_exists = policy }) end)
        else
            assert(fs.write(path, "second", { if_exists = policy }) == (policy == "replace"))
        end
        assert(fs.read(path) == (policy == "replace" and "second" or "first"))
    end
    fs.mkdir("skip-directory")
    assert(fs.write("skip-directory", "x", { if_exists = "skip" }) == false)
    t.assert_error("already exists", function() fs.write("skip-directory", "x", { if_exists = "error" }) end)
    for _, path in ipairs({ "", "bad\0path" }) do
        t.assert_error("fs:", function() fs.read(path) end)
        t.assert_error("fs:", function() fs.write(path, "x") end)
    end
    t.assert_error("bad argument #2", function() fs.write("invalid-write", 123) end)
    t.assert_error("invalid option", function() fs.write("invalid-write", "x", { if_exists = "append" }) end)
    t.assert_error("boolean expected", function() fs.write("invalid-write", "x", { parents = "yes" }) end)
    assert(not fs.stat("invalid-write"))
end)

test("fs write follows symlinks and preserves Unix permissions", function()
    fs.write("write-links/target", "before")
    fs.chmod("write-links/target", 0x1e8) -- 0750
    local mode = fs.stat("write-links/target").mode
    if not t.symlink("target", "write-links/link") then return end
    assert(t.symlink("link", "write-links/chain"))
    assert(fs.write("write-links/chain", "after"))
    assert(fs.read("write-links/target") == "after")
    assert(fs.stat("write-links/target").mode == mode)
    for _, path in ipairs({ "write-links/link", "write-links/chain" }) do
        assert(fs.stat(path, { follow = false }).type == "symlink")
        assert(fs.write(path, "skipped", { if_exists = "skip" }) == false)
        t.assert_error("already exists", function() fs.write(path, "error", { if_exists = "error" }) end)
    end
    assert(t.symlink("missing", "write-links/broken"))
    assert(fs.read("write-links/broken") == nil)
    assert(fs.write("write-links/broken", "x", { if_exists = "skip" }) == false)
    t.assert_error("already exists", function() fs.write("write-links/broken", "x", { if_exists = "error" }) end)
    t.assert_error("fs.realpath:", function() fs.write("write-links/broken", "x") end)
    assert(fs.stat("write-links/broken", { follow = false }).type == "symlink")
    assert(not fs.stat("write-links/missing"))
end)

test("fs write create-only publication has one winner across processes", function()
    local project = t.project("write-race", [[return {write = function(id)
    return fs.write(host.project_dir .. "/winner", id:rep(65536), { if_exists = "skip" })
end}]])
    local processes, wins = {}, 0
    for i = 1, 8 do
        local command = t.command(project, "write", tostring(i))
        command.stdout, command.stderr = "capture", "capture"
        processes[i] = spawn(command)
    end
    for i, process in ipairs(processes) do
        local output = t.success(process:wait())
        if output == "true\n" then
            wins = wins + 1
            assert(fs.read(project .. "/winner") == tostring(i):rep(65536))
        else assert(output == "false\n", output) end
    end
    assert(wins == 1)
    for name in fs.list(project) do assert(not name:find(".tmp-", 1, true), name) end
end)

if host.os ~= "windows" then
    test("fs write does not need read access to the existing contents", function()
        fs.write("unreadable-old", "old")
        fs.chmod("unreadable-old", 0)
        assert(fs.write("unreadable-old", "new"))
        assert(fs.stat("unreadable-old").mode == 0)
        fs.chmod("unreadable-old", 0x180)
        assert(fs.read("unreadable-old") == "new")
    end)

    test("fs write detects buffered output failure and leaves the old file intact", function()
        local project = t.project("write-failure", [[return {check = function()
    local path = host.project_dir .. "/target"
    local ok, message = pcall(fs.write, path, "replacement")
    assert(not ok and message:find("fs.write:", 1, true), tostring(message))
    assert(fs.read(path) == "before")
    for name in fs.list(host.project_dir) do assert(not name:find(".tmp-", 1, true), name) end
end}]])
        fs.write(project .. "/target", "before")
        t.success(exec { "/bin/sh", "-c", 'trap "" XFSZ; ulimit -f 0; exec "$@"', "write-test",
            host.executable, "--launcher", project .. "/.cmd", "check", stdout = "capture", stderr = "capture" })
    end)
end

test("fs metadata and missing paths", function()
    t.write("data-ü", "abc")
    local info = fs.stat("data-ü")
    assert(info.type == "file" and info.size == 3)
    assert(math.type(info.mode) == "integer")
    if host.os == "windows" then assert(info.mode == 0) end
    t.write("mode-copy", "contents")
    fs.chmod("mode-copy", info.mode)
    assert(fs.stat("mode-copy").mode == info.mode)
    assert(fs.stat("missing") == nil)
    assert(fs.stat(".", { follow = false }).type == "directory")
end)

test("fs realpath returns usable absolute paths for files and directories", function()
    fs.mkdir("realpath ü/child")
    t.write("realpath ü/file", "contents")
    local path = fs.realpath("realpath ü/child/../file")
    assert(path == fs.realpath(host.cwd .. "/realpath ü/file"))
    assert(t.read(path) == "contents")
    assert(fs.realpath(path) == path)
    assert(fs.realpath("realpath ü/child/..") == fs.realpath("realpath ü"))
    assert(fs.realpath(".") == fs.realpath(host.cwd))
    t.assert_error("fs.realpath:", function() fs.realpath("does-not-exist") end)
    t.assert_error("fs:", function() fs.realpath("") end)
    t.assert_error("fs:", function() fs.realpath("file\0ignored") end)
end)

test("fs realpath resolves relative links, link chains, and directory links", function()
    fs.mkdir("realpath-links/dir")
    t.write("realpath-links/dir/file", "target")
    if not t.symlink("dir/file", "realpath-links/link") then return end
    assert(t.symlink("link", "realpath-links/chain"))
    assert(t.symlink("dir", "realpath-links/alias", true))
    assert(t.symlink(fs.realpath("realpath-links/dir/file"), "realpath-links/absolute"))
    local target = fs.realpath("realpath-links/dir/file")
    for _, path in ipairs({ "link", "chain", "alias/file", "absolute" }) do
        assert(fs.realpath("realpath-links/" .. path) == target)
    end
    assert(fs.stat("realpath-links/link", { follow = false }).type == "symlink")
    assert(t.symlink("missing", "realpath-links/broken"))
    t.assert_error("fs.realpath:", function() fs.realpath("realpath-links/broken") end)
    assert(t.symlink("cycle", "realpath-links/cycle"))
    t.assert_error("fs.realpath:", function() fs.realpath("realpath-links/cycle") end)
end)

if host.os == "windows" then
    test("fs realpath resolves Windows directory junctions", function()
        fs.mkdir("junction-target")
        t.write("junction-target/file", "contents")
        exec { "cmd.exe", "/d", "/c", "mklink", "/J", "junction", host.cwd .. "/junction-target",
            stdout = "discard" }
        assert(fs.realpath("junction") == fs.realpath("junction-target"))
        assert(fs.realpath("junction/file") == fs.realpath("junction-target/file"))
    end)
end

test("fs mkdir creates parents and tolerates existing directories", function()
    fs.mkdir("nested/ü/child")
    fs.mkdir("nested/ü/child")
    assert(fs.stat("nested/ü/child").type == "directory")
    t.write("parent-file", "")
    t.assert_error("fs.mkdir:", function() fs.mkdir("parent-file/child") end)
end)

test("fs iterator contents and cleanup on break/error", function()
    fs.mkdir("entries")
    t.write("entries/z", ""); t.write("entries/a", "")
    local names = {}
    for name in fs.list("entries") do names[#names + 1] = name end
    table.sort(names)
    assert(table.concat(names, ",") == "a,z")
    t.assert_error("fs.list:", function() for _ in fs.list("missing") do end end)

    collectgarbage("collect"); collectgarbage("stop")
    for i = 1, 100 do
        for _ in fs.list("entries") do break end
        t.assert_error("stop iteration", function()
            for _ in fs.list("entries") do error("stop iteration") end
        end)
        fs.rename("entries", "moved"); fs.rename("moved", "entries")
    end
    collectgarbage("restart")
end)

test("fs file, empty-directory, and recursive removal", function()
    fs.mkdir("tree/child"); t.write("tree/child/file", "data")
    t.assert_error("fs.remove:", function() fs.remove("tree") end)
    fs.remove("tree", { recursive = true })
    assert(fs.stat("tree") == nil)
    fs.remove("missing", { recursive = true })
    fs.mkdir("empty-dir"); fs.remove("empty-dir")
    assert(fs.stat("empty-dir") == nil)
    t.write("remove-file", "data"); fs.remove("remove-file")
    assert(fs.stat("remove-file") == nil)
end)

test("fs rename replacement and marking a file executable", function()
    t.write("from", "new"); t.write("to", "old")
    fs.rename("from", "to", { if_exists = "replace" })
    assert(t.read("to") == "new" and fs.stat("from") == nil)
    fs.chmod("to", "+x")
    assert(t.read("to") == "new")
    t.assert_error("fs.rename:", function() fs.rename("missing", "new") end)
end)

test("fs chmod accepts numeric modes and only the supported symbolic mode", function()
    t.write("chmod-file", "contents")
    fs.chmod("chmod-file", 0x180) -- 0600
    fs.chmod("chmod-file", "+x")
    assert(t.read("chmod-file") == "contents")
    if host.os == "windows" then assert(fs.stat("chmod-file").mode == 0) end
    for _, mode in ipairs({ -1, 0x200, 0.5, "", "755", "a+x", "u+x", "+w", "+x\0" }) do
        t.assert_error("bad argument #2", function() fs.chmod("chmod-file", mode) end)
    end
end)

if host.os ~= "windows" then
    test("fs chmod +x respects and preserves umask and existing permissions", function()
        local project = t.project("chmod", [[return {check = function(mode, expected, mask)
    fs.write(host.project_dir .. "/file", "")
    fs.chmod(host.project_dir .. "/file", tonumber(mode, 8))
    fs.chmod(host.project_dir .. "/file", "+x")
    assert(fs.stat(host.project_dir .. "/file").mode == tonumber(expected, 8))
    local after = host.project_dir .. "/after"
    fs.remove(after)
    fs.write(after, "")
    assert(fs.stat(after).mode == (0x1b6 & ~tonumber(mask, 8))) -- 0666 minus umask
end}]])
        for _, case in ipairs({
            { "640", "022", "751" }, { "640", "077", "740" },
            { "640", "111", "640" }, { "651", "077", "751" },
        }) do
            t.success(exec { "/bin/sh", "-c", "umask \"$1\"; shift; exec \"$@\"", "chmod-test", case[2],
                host.executable, "--launcher", project .. "/.cmd", "check", case[1], case[3], case[2],
                stdout = "capture", stderr = "capture" })
        end
    end)
end
