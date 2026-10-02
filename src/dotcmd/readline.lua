-- Editing and history belong to one REPL session; nothing is persisted.
local readline = {}
local ESC = "\27["
local opening_brackets = {[")"] = "(", ["]"] = "[", ["}"] = "{"}
local keywords = {"and", "break", "do", "else", "elseif", "end", "false", "for", "function",
    "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while"}

local function previous(text, cursor)
    return cursor == 0 and 0 or utf8.offset(text, -1, cursor + 1) - 1
end

local function following(text, cursor)
    return cursor == #text and cursor or (utf8.offset(text, 2, cursor + 1) or (#text + 1)) - 1
end

local function cell_width(code)
    if code >= 0x300 and code <= 0x36f or code >= 0x1ab0 and code <= 0x1aff
        or code >= 0x1dc0 and code <= 0x1dff or code >= 0x20d0 and code <= 0x20ff
        or code >= 0xfe00 and code <= 0xfe0f or code >= 0xfe20 and code <= 0xfe2f
        or code >= 0xe0100 and code <= 0xe01ef or code == 0x200d then return 0 end
    if code >= 0x1100 and (code <= 0x115f or code == 0x2329 or code == 0x232a
        or code >= 0x2e80 and code <= 0xa4cf and code ~= 0x303f
        or code >= 0xac00 and code <= 0xd7a3 or code >= 0xf900 and code <= 0xfaff
        or code >= 0xfe10 and code <= 0xfe19 or code >= 0xfe30 and code <= 0xfe6f
        or code >= 0xff00 and code <= 0xff60 or code >= 0xffe0 and code <= 0xffe6
        or code >= 0x1f300 and code <= 0x1faff or code >= 0x20000 and code <= 0x3fffd) then return 2 end
    return 1
end

-- Skip Lua strings and comments so quoted/commented brackets do not match.
local function syntax(text)
    local pairs_by_position, code, stack = {}, {}, {}
    local index = 1
    while index <= #text do
        local char = text:sub(index, index)
        local comment = text:sub(index, index + 1) == "--"
        local start = comment and index + 2 or index
        local _, finish, equals = text:find("^%[(=*)%[", start)
        if finish then
            local _, ending = text:find("]" .. equals .. "]", finish + 1, true)
            index = ending and ending + 1 or #text + 1
        elseif comment then
            index = text:find("\n", index + 2, true) or #text + 1
        elseif char == '"' or char == "'" then
            local quote = char
            index = index + 1
            while index <= #text do
                char = text:sub(index, index)
                index = index + (char == "\\" and 2 or 1)
                if char == quote then break end
            end
        else
            code[index] = true
            if char == "(" or char == "[" or char == "{" then
                stack[#stack + 1] = index
            elseif char == ")" or char == "]" or char == "}" then
                local open = stack[#stack]
                local expected = opening_brackets[char]
                if open and text:sub(open, open) == expected then
                    stack[#stack] = nil
                    pairs_by_position[open], pairs_by_position[index] = index, open
                else
                    stack = {}
                end
            end
            index = index + 1
        end
    end
    return pairs_by_position, code
end

local function completions(text, cursor, env)
    local before = text:sub(1, cursor)
    local token = before:match("([%a_][%w_%.:]*)$")
    if not token then return {} end
    local start = cursor - #token + 1
    local _, code = syntax(text)
    if not code[start] then return {} end
    local path, prefix = token:match("^(.*[%.:])([%w_]*)$")
    local scope = env
    if path then
        for part in path:gmatch("[%a_][%w_]*") do
            if type(scope) ~= "table" then return {} end
            scope = rawget(scope, part)
        end
        if type(scope) ~= "table" then return {} end
    else
        prefix = token
    end
    local candidates = {}
    for key in next, scope do
        if type(key) == "string" and key:match("^[%a_][%w_]*$") and key:sub(1, #prefix) == prefix then
            candidates[#candidates + 1] = key
        end
    end
    if not path then
        for _, key in ipairs(keywords) do
            if key:sub(1, #prefix) == prefix and rawget(scope, key) == nil then candidates[#candidates + 1] = key end
        end
    end
    table.sort(candidates)
    return candidates, prefix
end

local key_sequences = {
    ["\27[A"] = "up", ["\27[B"] = "down", ["\27[C"] = "right", ["\27[D"] = "left",
    ["\27[H"] = "home", ["\27[F"] = "end", ["\27OH"] = "home", ["\27OF"] = "end",
    ["\27OA"] = "up", ["\27OB"] = "down", ["\27OC"] = "right", ["\27OD"] = "left",
    ["\27[1~"] = "home", ["\27[7~"] = "home", ["\27[4~"] = "end", ["\27[8~"] = "end",
    ["\27[3~"] = "delete", ["\27[1;5D"] = "word_left", ["\27[1;5C"] = "word_right",
    ["\27[1;3D"] = "word_left", ["\27[1;3C"] = "word_right",
    ["\27b"] = "word_left", ["\27f"] = "word_right", ["\27d"] = "kill_word",
    ["\27\127"] = "back_word",
    ["\1"] = "home", ["\5"] = "end", ["\2"] = "left", ["\6"] = "right",
    ["\16"] = "history_up", ["\14"] = "history_down", ["\18"] = "search",
    ["\21"] = "kill_start", ["\11"] = "kill_end", ["\23"] = "back_word", ["\25"] = "yank",
    ["\12"] = "clear", ["\3"] = "cancel", ["\4"] = "eof", ["\7"] = "escape",
    ["\127"] = "backspace", ["\8"] = "backspace", ["\9"] = "complete",
    ["\13"] = "enter", ["\10"] = "enter", ["\27"] = "escape",
}

local function read_key(console)
    local bytes = console:read(100)
    if bytes == nil then return "closed" end
    if bytes == "" then return "resize" end
    if bytes:sub(1, 1) == "\27" then
        while #bytes == 1 or bytes == "\27[" or bytes == "\27O"
            or bytes:match("^\27%[[%d;]+$") do
            local more = console:read(40)
            if more == nil then return "closed" end
            if more == "" then break end
            bytes = bytes .. more
        end
        if bytes == "\27[200~" then
            local chunks, tail = {}, ""
            while tail ~= "\27[201~" do
                local more = console:read()
                if more == nil then return "closed" end
                chunks[#chunks + 1] = more
                tail = (tail .. more):sub(-6)
            end
            local paste = table.concat(chunks):sub(1, -7):gsub("\r\n", "\n"):gsub("\r", "\n")
            return "text", (paste:gsub("[%z\1-\8\11-\31\127]", ""))
        end
    elseif bytes:byte() >= 0xc2 then
        local length = bytes:byte() < 0xe0 and 2 or bytes:byte() < 0xf0 and 3 or 4
        while #bytes < length do
            local more = console:read()
            if not more then return "closed" end
            bytes = bytes .. more
        end
    end
    local key = key_sequences[bytes]
    if key then return key end
    if bytes:byte() >= 32 and bytes:byte() ~= 127 and bytes:byte() ~= 27 then return "text", bytes end
    return "ignore"
end

local function line_start(text, cursor)
    return text:sub(1, cursor):match(".*()\n") or 0
end

local function line_end(text, cursor)
    return (text:find("\n", cursor + 1, true) or #text + 1) - 1
end

local function word_left(text, cursor)
    while cursor > 0 and text:sub(previous(text, cursor) + 1, cursor):match("%s") do cursor = previous(text, cursor) end
    while cursor > 0 and not text:sub(previous(text, cursor) + 1, cursor):match("%s") do cursor = previous(text, cursor) end
    return cursor
end

local function word_right(text, cursor)
    while cursor < #text and text:sub(cursor + 1, following(text, cursor)):match("%s") do cursor = following(text, cursor) end
    while cursor < #text and not text:sub(cursor + 1, following(text, cursor)):match("%s") do cursor = following(text, cursor) end
    return cursor
end

function readline.new()
    return setmetatable({history = {}}, {__index = readline})
end

function readline:add(source)
    if source:match("%S") and self.history[#self.history] ~= source then
        self.history[#self.history + 1] = source
        if #self.history > 200 then table.remove(self.history, 1) end
    end
end

function readline:read(env, compile)
    local console <close> = require("dotcmd._console").open(io.stdin, io.stdout)
    io.stdout:write(ESC .. "?2004h"):flush()
    local text, cursor, killed = "", 0, ""
    local history_index, draft = #self.history + 1, ""
    local rendered_row, search, tabbed = 0, nil, false
    local columns, height = console:size()
    local colored = os.getenv("NO_COLOR") == nil
    local highlight_until = 0

    local function insert(value)
        text = text:sub(1, cursor) .. value .. text:sub(cursor + 1)
        cursor = cursor + #value
    end

    local function remove(first, last, kill)
        if kill and first < last then killed = text:sub(first + 1, last) end
        text = text:sub(1, first) .. text:sub(last + 1)
        cursor = first
    end

    local function draw(at_end)
        local rows = {"> "}
        local row, column = 1, 2
        local caret_row, caret_column = 1, 2
        local focus, mate
        if colored and not at_end and highlight_until > 0 then
            local pairs_by_position = syntax(text)
            focus = pairs_by_position[cursor] and cursor or cursor + 1
            mate = pairs_by_position[focus]
        end
        local limit = math.max(4, columns - 1)
        for position, code in utf8.codes(text) do
            if cursor == position - 1 then caret_row, caret_column = row, column end
            if code == 10 then
                row, column = row + 1, 3
                rows[row] = ">> "
            else
                local width = code == 9 and (4 - column % 4) or cell_width(code)
                if column + width > limit then
                    row, column = row + 1, 2
                    rows[row] = "  "
                    if cursor == position - 1 then caret_row, caret_column = row, column end
                end
                local char = code == 9 and string.rep(" ", width) or utf8.char(code)
                if mate and (position == focus or position == mate) then
                    char = ESC .. "7m" .. char .. ESC .. "0m"
                end
                rows[row] = rows[row] .. char
                column = column + width
            end
        end
        if cursor == #text or at_end then caret_row, caret_column = row, column end
        if search then
            local prefix = ("(reverse-search: "):sub(1, limit - 1)
            local query = search.query:gsub("%s", " ")
            local start, width = #query, 0
            while start > 0 do
                local preceding = previous(query, start)
                local cells = cell_width(utf8.codepoint(query, preceding + 1))
                if #prefix + width + cells + 1 > limit then break end
                start, width = preceding, width + cells
            end
            table.insert(rows, 1, prefix .. query:sub(start + 1) .. ")")
            caret_row, caret_column = 1, #prefix + width
        end
        local visible = math.max(1, height - 1)
        local first = math.max(1, caret_row - visible + 1)
        local last = math.min(#rows, first + visible - 1)
        io.stdout:write("\r", rendered_row > 0 and (ESC .. rendered_row .. "A") or "", ESC .. "J")
        for index = first, last do
            if index > first then io.stdout:write("\r\n") end
            io.stdout:write(rows[index])
        end
        local up = last - caret_row
        io.stdout:write("\r", up > 0 and (ESC .. up .. "A") or "",
            caret_column > 0 and (ESC .. caret_column .. "C") or "")
        io.stdout:flush()
        rendered_row = caret_row - first
    end

    local function history(direction)
        if history_index == #self.history + 1 then draft = text end
        history_index = math.max(1, math.min(#self.history + 1, history_index + direction))
        text = self.history[history_index] or draft
        cursor = #text
    end

    local function find_history(before)
        for index = before, 1, -1 do
            if self.history[index]:find(search.query, 1, true) then
                search.index, text = index, self.history[index]
                cursor = #text
                return
            end
        end
        io.stdout:write("\7"):flush()
    end

    local function accept_search()
        if history_index == #self.history + 1 then draft = search.draft end
        history_index = search.index
        search = nil
    end

    draw()
    while true do
        local key, value = read_key(console)
        if key == "closed" then return nil end
        if key ~= "resize" and key ~= "ignore" then highlight_until = console:milliseconds() + 500 end
        if search then
            if key == "escape" or key == "cancel" then
                text, cursor = search.draft, search.cursor
                search = nil
                key = "ignore"
            elseif key == "enter" then
                accept_search()
                key = "ignore"
            elseif key == "search" then
                find_history(search.index - 1)
                key = "ignore"
            elseif key == "text" or key == "backspace" then
                if key == "text" then search.query = search.query .. value
                elseif #search.query > 0 then search.query = search.query:sub(1, previous(search.query, #search.query)) end
                find_history(#self.history)
                key = "ignore"
            elseif key ~= "resize" and key ~= "ignore" then
                accept_search()
            end
        end
        if key ~= "complete" and key ~= "resize" then tabbed = false end
        if key == "text" then insert(value)
        elseif key == "enter" then
            local chunk, message, partial = compile(text, "=repl", env)
            if partial then insert("\n")
            else draw(true); io.stdout:write("\n"):flush(); return text, chunk, message end
        elseif key == "cancel" then
            draw(true)
            if text == "" then io.stdout:write("\n"):flush(); return nil end
            io.stdout:write("^C\n"):flush(); return false
        elseif key == "eof" then
            if text == "" then io.stdout:write("\n"):flush(); return nil end
            remove(cursor, following(text, cursor))
        elseif key == "left" then cursor = previous(text, cursor)
        elseif key == "right" then cursor = following(text, cursor)
        elseif key == "home" then cursor = line_start(text, cursor)
        elseif key == "end" then cursor = line_end(text, cursor)
        elseif key == "word_left" then cursor = word_left(text, cursor)
        elseif key == "word_right" then cursor = word_right(text, cursor)
        elseif key == "backspace" then remove(previous(text, cursor), cursor)
        elseif key == "delete" then remove(cursor, following(text, cursor))
        elseif key == "kill_start" then remove(line_start(text, cursor), cursor, true)
        elseif key == "kill_end" then
            local ending = line_end(text, cursor)
            remove(cursor, ending == cursor and following(text, cursor) or ending, true)
        elseif key == "back_word" then remove(word_left(text, cursor), cursor, true)
        elseif key == "kill_word" then remove(cursor, word_right(text, cursor), true)
        elseif key == "yank" then insert(killed)
        elseif key == "history_up" then history(-1)
        elseif key == "history_down" then history(1)
        elseif key == "up" or key == "down" then
            local start, ending = line_start(text, cursor), line_end(text, cursor)
            local offset = utf8.len(text:sub(start + 1, cursor))
            if key == "up" and start > 0 then
                local new_start = line_start(text, start - 1)
                local length = utf8.len(text:sub(new_start + 1, start - 1))
                cursor = (utf8.offset(text, math.min(offset, length) + 1, new_start + 1) or #text + 1) - 1
            elseif key == "down" and ending < #text then
                local new_end = line_end(text, ending + 1)
                local length = utf8.len(text:sub(ending + 2, new_end))
                cursor = (utf8.offset(text, math.min(offset, length) + 1, ending + 2) or #text + 1) - 1
            else history(key == "up" and -1 or 1) end
        elseif key == "search" then
            search = {query = "", index = #self.history + 1, draft = text, cursor = cursor}
            find_history(#self.history)
        elseif key == "complete" then
            local candidates, prefix = completions(text, cursor, env)
            if #candidates == 0 then
                if text:sub(line_start(text, cursor) + 1, cursor):match("^%s*$") then insert("    ")
                else io.stdout:write("\7"):flush() end
            else
                local common = candidates[1]
                for index = 2, #candidates do
                    while candidates[index]:sub(1, #common) ~= common do common = common:sub(1, -2) end
                end
                if #common > #prefix then insert(common:sub(#prefix + 1)) end
                if tabbed and #candidates > 1 then
                    draw(true)
                    io.stdout:write("\n", table.concat(candidates, "  "), "\n"):flush()
                    rendered_row = 0
                end
                tabbed = true
            end
        elseif key == "clear" then
            io.stdout:write(ESC .. "H" .. ESC .. "2J")
            rendered_row = 0
        end
        local next_columns, next_height = console:size()
        local resized = next_columns ~= columns or next_height ~= height
        columns, height = next_columns, next_height
        local expired = highlight_until > 0 and console:milliseconds() >= highlight_until
        if expired then highlight_until = 0 end
        if key ~= "resize" or resized or expired then draw() end
    end
end

return readline
