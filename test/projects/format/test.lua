local format = require("dotcmd.format")
local pretty = require("dotcmd.pretty")

test("plain strips styles and preserves nested text", function()
    local style = { fg = "red", bold = true }
    assert(format.plain({ style = style, "error: ", { bold = false, underline = true, "details" },
        " ", true, " ", false, " ", 42, "\n" }) == "error: details true false 42\n")
end)

test("ansi scopes nested styles and restores their parents", function()
    local markup = { fg = "red", bold = true, "red ",
        { bold = false, underline = true, "under" }, " red" }
    assert(format.ansi(markup) == "\27[1;31mred \27[22;4munder\27[1;24m red\27[22;39m")
    assert(format.ansi({ fg = "red", "a", { fg = false, "b" }, "c" })
        == "\27[31ma\27[39mb\27[31mc\27[39m")
end)

test("style tables support colors and direct keys take precedence", function()
    local style = { fg = "red", bg = 17, bold = true, dim = true, underline = true }
    local markup = { style = style, fg = "#010203", bold = false, underline = false, "x" }
    assert(format.ansi(markup) == "\27[2;38;2;1;2;3;48;5;17mx\27[22;39;49m")
    assert(format.ansi({ fg = "bright_blue", bg = "bright_white", "x" })
        == "\27[94;107mx\27[39;49m")
end)

test("pretty markup styles values, literal keys, and separators without styling braces", function()
    local markup = pretty {
        name = "dotcmd",
        version = 1.13,
        enabled = true,
        metadata = { stable = false, count = 42 },
    }
    local plain = [[{
    enabled = true,
    name = "dotcmd",
    version = 1.13,
    metadata = {
        count = 42,
        stable = false
    }
}]]
    assert(format.plain(markup) == plain)

    local ansi = format.ansi(markup)
    assert(ansi:sub(1, 2) == "{\n", ansi)
    assert(ansi:sub(-1) == "}", ansi)
    assert(ansi:find("enabled \27[2m= \27[22m\27[36mtrue\27[39m\27[2m,\27[22m", 1, true), ansi)
    assert(ansi:find("name \27[2m= \27[22m\27[32m\"dotcmd\"\27[39m\27[2m,\27[22m", 1, true), ansi)
    assert(ansi:find("version \27[2m= \27[22m\27[36m1.13\27[39m\27[2m,\27[22m", 1, true), ansi)
    assert(ansi:find("metadata \27[2m= \27[22m{\n", 1, true), ansi)
    assert(ansi:find("count \27[2m= \27[22m\27[36m42\27[39m\27[2m,\27[22m", 1, true), ansi)
    assert(ansi:find("stable \27[2m= \27[22m\27[36mfalse\27[39m", 1, true), ansi)

    local keyed = pretty { ["do"] = 1, [4] = 2, [false] = 3 }
    assert(format.plain(keyed) == [[{
    ["do"] = 1,
    [4] = 2,
    [false] = 3
}]])
    local keyed_ansi = format.ansi(keyed)
    assert(keyed_ansi:find("[\27[32m\"do\"\27[39m] \27[2m= \27[22m", 1, true), keyed_ansi)
    assert(keyed_ansi:find("[\27[36m4\27[39m] \27[2m= \27[22m", 1, true), keyed_ansi)
    assert(keyed_ansi:find("[\27[36mfalse\27[39m] \27[2m= \27[22m", 1, true), keyed_ansi)

    local runtime = pretty { assert = assert }
    assert(format.plain(runtime):find("assert = <function: ", 1, true))
    assert(format.ansi(runtime):find(
        "assert \27[2m= \27[22m\27[36m<function: ", 1, true))

    assert(format.ansi(pretty(nil)) == "\27[36mnil\27[39m")
    assert(format.ansi(pretty("text")) == "text")
end)

test("writer detects a regular file once and writes plain text", function()
    local file <close> = assert(io.tmpfile())
    local output = format.writer(file)
    assert(output:write({ fg = "red", bold = true, "plain" }) == output)
    assert(output:flush() == output)
    assert(file:seek("set") == 0)
    assert(file:read("a") == "plain")
end)
