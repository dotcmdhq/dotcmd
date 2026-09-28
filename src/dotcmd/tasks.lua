local args = require("dotcmd.args")
local tasks = {}

local function spellings(opts)
    local result = {}
    for key, spec in pairs(opts or {}) do
        result["--" .. key:gsub("_", "-")] = key
        for short in (spec.short or ""):gmatch(".") do result["-" .. short] = key end
    end
    return result
end

local function merge_opts(parent, own, path)
    if own == nil then return parent end
    local merged, used = {}, spellings(parent)
    for key, spec in pairs(parent or {}) do merged[key] = spec end
    for key, spec in pairs(own) do
        local names = { "--" .. key:gsub("_", "-") }
        for short in (spec.short or ""):gmatch(".") do names[#names + 1] = "-" .. short end
        for _, name in ipairs(names) do
            assert(not used[name], "duplicate option " .. name .. " in " .. path)
            used[name] = key
        end
        assert(merged[key] == nil, "duplicate option --" .. key:gsub("_", "-") .. " in " .. path)
        merged[key] = spec
    end
    return merged
end

local function normalize(definitions, parent_opts, parent_path)
    local result = {}
    for key, definition in pairs(definitions) do
        local source = type(definition) == "function" and { run = definition } or definition
        local task = {}
        for field, value in pairs(source) do task[field] = value end
        local spelling = key:gsub("_", "-")
        local path = parent_path == "" and spelling or parent_path .. " " .. spelling
        assert(not (task.tasks ~= nil and task.args ~= nil),
            "task " .. path .. " cannot define both args and tasks")
        local merged = merge_opts(parent_opts, task.opts, path)
        if task.tasks ~= nil then
            assert(type(task.tasks) == "table", "tasks must be a table in " .. path)
            task.tasks = normalize(task.tasks, merged, path)
        else
            assert(type(task.run) == "function", "task " .. path .. " must define run")
        end
        assert(result[spelling] == nil, "duplicate task " .. path)
        result[spelling] = task
    end
    for key, definition in pairs(definitions) do
        local spelling = key:gsub("_", "-")
        local task = result[spelling]
        for _, alias in ipairs(task.aliases or {}) do
            assert(result[alias] == nil,
                "duplicate task " .. (parent_path == "" and alias or parent_path .. " " .. alias))
            result[alias] = spelling
        end
    end
    return result
end

function tasks.normalize(definitions)
    return normalize(definitions, nil, "")
end

local function lookup(tasks_by_spelling, name)
    local task = tasks_by_spelling[name]
    if type(task) == "string" then task = tasks_by_spelling[task] end
    return task
end

---@class dotcmd.Resolution
---@field task dotcmd.Task
---@field arguments string[]
---@field path string[]
---@field opts? table<string, dotcmd.Option>

-- Remove only dispatch names. Keep all options and separators in their original
-- order so the leaf parser applies defaults, repetition, and end_opts once.
---@return dotcmd.Resolution? resolution
---@return string? message
---@return integer? error_code
function tasks.resolve(tasks_by_spelling, words)
    local task = lookup(tasks_by_spelling, words[1])
    if not task then return nil, "unknown task: " .. tostring(words[1]) end
    local path, argv, index, ended = { words[1] }, {}, 2, false
    local opts = merge_opts(nil, task.opts, words[1])
    while task.tasks do
        local tail = {}
        for i = index, #words do tail[#tail + 1] = words[i] end
        local state, message = args.scan({ opts = opts or {}, args = { end_opts = true } }, tail, not ended)
        if not state then return nil, message, 2 end
        local position = state.first_positional
        if not position or state.pending then
            ended = ended or state.separator
            break
        end
        local name = tail[position]
        local child = lookup(task.tasks, name)
        if not child then
            if not ended and not state.separator and name:sub(1, 1) == "-"
                and #name > 1 and tonumber(name) == nil then
                return nil, "unknown option: " .. name, 2
            end
            return nil, "unknown subtask: " .. name
        end
        for i = 1, position - 1 do argv[#argv + 1] = tail[i] end
        ended = ended or state.separator
        task = child
        path[#path + 1] = name
        opts = merge_opts(opts, task.opts, table.concat(path, " "))
        index = index + position
    end
    for i = index, #words do argv[#argv + 1] = words[i] end
    if ended and opts == nil then
        for i, word in ipairs(argv) do
            if word == "--" then table.remove(argv, i); break end
        end
    end
    return { task = task, arguments = argv, path = path, opts = opts }
end

function tasks.find(tasks_by_spelling, path)
    if type(path) == "string" then
        local task = lookup(tasks_by_spelling, path)
        return task, task and merge_opts(nil, task.opts, path)
    end
    local task, opts
    for index, name in ipairs(path) do
        task = lookup(tasks_by_spelling, name)
        if not task then return nil end
        opts = merge_opts(opts, task.opts, table.concat(path, " ", 1, index))
        tasks_by_spelling = task.tasks
        if not tasks_by_spelling and index < #path then return nil end
    end
    return task, opts
end

return tasks
