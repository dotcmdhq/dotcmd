local pretty = require("dotcmd.pretty")
local format = require("dotcmd.format")
local eval = {}

local function incomplete(message)
    return message:match("<eof>['\"]?$") ~= nil
end

function eval.compile(source, name, env)
    local expression, expression_error = load("return " .. source, name, "t", env)
    if expression then return expression end
    local chunk, message = load(source, name, "t", env)
    if chunk then return chunk end
    if incomplete(expression_error) then message = expression_error end
    return nil, message
end

local function report(message)
    if type(message) == "table" then message = message.message end
    if message ~= nil then io.stderr:write("dotcmd: ", message, "\n") end
end

function eval.repl(env, format_error)
    local output = format.writer(io.stdout)
    local is_terminal = require("dotcmd._terminal")
    local interactive = is_terminal(io.stdin) and is_terminal(io.stdout)
    local source, message = "", nil
    while true do
        if interactive then
            io.stdout:write(source == "" and "> " or ">> ")
            io.stdout:flush()
        end
        local line = io.stdin:read("l")
        if line == nil then
            if source ~= "" then report(message) end
            return
        end
        source = source == "" and line or source .. "\n" .. line
        local chunk
        chunk, message = eval.compile(source, "=repl", env)
        if chunk then
            local ok, failure = xpcall(function()
                local results = table.pack(chunk())
                for i = 1, results.n do output:write({ pretty(results[i]), "\n" }) end
                output:flush()
            end, format_error)
            if not ok then report(failure) end
            source = ""
        elseif not incomplete(message) then
            report(message)
            source = ""
        end
    end
end

return eval
