local is_terminal = require("dotcmd._terminal")

local format = {}

local properties = { "fg", "bg", "bold", "dim", "underline" }
local named_colors = {
    black = 0,
    red = 1,
    green = 2,
    yellow = 3,
    blue = 4,
    magenta = 5,
    cyan = 6,
    white = 7,
    bright_black = 8,
    bright_red = 9,
    bright_green = 10,
    bright_yellow = 11,
    bright_blue = 12,
    bright_magenta = 13,
    bright_cyan = 14,
    bright_white = 15,
}
local default = { fg = false, bg = false, bold = false, dim = false, underline = false }
local no_color = os.getenv("NO_COLOR")
local decorations_enabled = not (no_color and no_color ~= "") and os.getenv("TERM") ~= "dumb"

local function apply_style(state, style)
    for _, key in ipairs(properties) do
        local value = rawget(style, key)
        if value ~= nil then state[key] = value end
    end
end

local function node_state(parent, node)
    local state = {}
    for _, key in ipairs(properties) do state[key] = parent[key] end
    local style = rawget(node, "style")
    if style ~= nil then apply_style(state, style) end
    for _, key in ipairs(properties) do
        local value = rawget(node, key)
        if value ~= nil then state[key] = value end
    end
    return state
end

local function color_code(value, foreground)
    if value == false then return foreground and "39" or "49" end
    if type(value) == "number" then return (foreground and "38;5;" or "48;5;") .. value end
    local named = named_colors[value]
    if named ~= nil then
        if named < 8 then return tostring((foreground and 30 or 40) + named) end
        return tostring((foreground and 90 or 100) + named - 8)
    end
    local red, green, blue = value:match("^#(%x%x)(%x%x)(%x%x)$")
    return (foreground and "38;2;" or "48;2;")
        .. tonumber(red, 16) .. ";" .. tonumber(green, 16) .. ";" .. tonumber(blue, 16)
end

local function transition(output, from, to)
    local codes = {}
    if from.bold ~= to.bold or from.dim ~= to.dim then
        if from.bold and not to.bold or from.dim and not to.dim then
            codes[#codes + 1] = "22"
            if to.bold then codes[#codes + 1] = "1" end
            if to.dim then codes[#codes + 1] = "2" end
        else
            if not from.bold and to.bold then codes[#codes + 1] = "1" end
            if not from.dim and to.dim then codes[#codes + 1] = "2" end
        end
    end
    if from.underline ~= to.underline then codes[#codes + 1] = to.underline and "4" or "24" end
    if from.fg ~= to.fg then codes[#codes + 1] = color_code(to.fg, true) end
    if from.bg ~= to.bg then codes[#codes + 1] = color_code(to.bg, false) end
    if #codes > 0 then output[#output + 1] = "\27[" .. table.concat(codes, ";") .. "m" end
end

local function render(markup, decorated)
    local output = {}
    local function visit(value, parent)
        if type(value) ~= "table" then
            output[#output + 1] = tostring(value); return
        end
        local state = node_state(parent, value)
        if decorated then transition(output, parent, state) end
        for _, child in ipairs(value) do visit(child, state) end
        if decorated then transition(output, state, parent) end
    end
    visit(markup, default)
    return table.concat(output)
end

function format.plain(markup)
    return render(markup, false)
end

function format.ansi(markup)
    return render(markup, true)
end

local writer = {}
writer.__index = writer

function writer:write(markup)
    assert(self.file:write(self.render(markup)))
    return self
end

function writer:flush()
    assert(self.file:flush())
    return self
end

function format.writer(file)
    local renderer = decorations_enabled and is_terminal(file) and format.ansi or format.plain
    return setmetatable({ file = file, render = renderer }, writer)
end

return format
