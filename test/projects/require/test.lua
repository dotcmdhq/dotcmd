test("require loads project files from another working directory and caches modules", function()
    local project = t.project("file modules", [[
local build = require("tasks.build")
return { check = function()
    assert(require("tasks.build") == build)
    assert(build.value == 42 and module_calls == 1)
end }
]])
    fs.mkdir(project .. "/tasks")
    t.write(project .. "/tasks/build.lua", [[
module_calls = (module_calls or 0) + 1
return { value = require("helper") }
]])
    t.write(project .. "/helper.lua", "return 42")
    fs.mkdir(project .. "/helper")
    t.write(project .. "/helper/init.lua", "return 99")
    local output = t.success(t.run_project(project, { cwd = host.project_dir }, "check"))
    assert(output == "", output)
end)

test("require loads directory modules by default and caches them", function()
    local project = t.project("directory modules", [[
local directory = require("tasks.directory")
return { check = function()
    assert(require("tasks.directory") == directory)
    assert(directory.value == 42 and directory_calls == 1)
end }
]])
    fs.mkdir(project .. "/tasks/directory")
    t.write(project .. "/tasks/directory/init.lua", [[
directory_calls = (directory_calls or 0) + 1
return { value = require("helper") }
]])
    t.write(project .. "/helper.lua", "return 42")
    t.success(t.run_project(project, { cwd = host.project_dir }, "check"))
end)

test("require works when the project path contains search-template characters", function()
    local name = host.os == "windows" and "module path ; ü" or "module path ?; ü"
    local project = t.project(name, [[
local value = require("value")
local directory = require("directory")
return { check = function()
    assert(value == 42 and directory == 99)
end }
]])
    t.write(project .. "/value.lua", "return 42")
    t.write(project .. "/directory/init.lua", "return 99")
    t.success(t.run_project(project, { cwd = host.project_dir }, "check"))
end)

test("require paths are configured in Lua", function()
    local project = t.project("configured modules", [[
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local value = require("value")
local directory = require("directory")
return { check = function()
    assert(value == "custom path" and directory == "directory module")
end }
]])
    fs.mkdir(project .. "/lua")
    fs.mkdir(project .. "/lua/directory")
    t.write(project .. "/lua/value.lua", 'return "custom path"')
    t.write(project .. "/lua/directory/init.lua", 'return "directory module"')
    t.success(t.run_project(project, "check"))
end)

test("require excludes invocation-directory and environment paths by default", function()
    local project = t.project("isolated modules", [[
assert(package.path == "./?.lua;./?/init.lua")
assert(package.cpath == "")
assert(not pcall(require, "ambient"))
return { check = function() end }
]])
    local ambient = t.project("ambient modules")
    t.write(ambient .. "/ambient.lua", 'return "ambient module"')
    t.success(t.run_project(project, {
        cwd = ambient,
        env = { LUA_PATH = ambient .. "/?.lua", LUA_PATH_5_5 = ambient .. "/?.lua",
            LUA_CPATH = ambient .. "/?.so", LUA_CPATH_5_5 = ambient .. "/?.so" },
    }, "check"))
end)

test("require preserves embedded modules and the dotcmd namespace", function()
    local project = t.project("embedded modules", [[
assert(type(require("dotcmd.pretty")) == "function")
local ok, message = pcall(require, "dotcmd.project")
assert(not ok and message:find("no embedded module 'dotcmd.project'", 1, true))
package.preload.custom = function() return "preloaded" end
assert(require("custom") == "preloaded")
table.insert(package.searchers, 3, function(name)
    if name == "virtual" then return function() return "custom searcher" end end
end)
assert(require("virtual") == "custom searcher")
return { check = function() end }
]])
    fs.mkdir(project .. "/dotcmd")
    t.write(project .. "/dotcmd/pretty.lua", 'error("embedded module shadowed")')
    t.write(project .. "/dotcmd/project.lua", 'error("reserved module executed")')
    t.success(t.run_project(project, "check"))
end)

test("require reports module filenames for syntax and runtime errors", function()
    for _, case in ipairs({
        { "syntax", "return function(" },
        { "runtime", 'error("module runtime failure")', "module runtime failure" },
    }) do
        local project = t.project(case[1] .. " module error", [[
require("broken")
return { check = function() end }
]])
        t.write(project .. "/broken.lua", case[2])
        local message = t.failure(t.run_project(project, "check"), "broken.lua:")
        if case[3] then assert(message:find(case[3], 1, true), message) end
    end
end)
