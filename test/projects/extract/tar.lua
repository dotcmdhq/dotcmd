-- Small uncompressed USTAR fixtures let tests express malformed paths and
-- link graphs directly, without needing an archive tool at test runtime.
return function(entries)
    local blocks = {}
    local function field(value, size) return value .. string.rep("\0", size - #value) end
    for _, entry in ipairs(entries) do
        local data = entry.data or ""
        local header = field(entry.name, 100)
            .. ("%07o\0"):format(entry.mode or 0x1a4)
            .. string.rep("0000000\0", 2) .. ("%011o\0"):format(#data)
            .. "00000000000\0" .. string.rep(" ", 8) .. (entry.type or "0")
            .. field(entry.link or "", 100) .. "ustar\00000"
            .. string.rep("\0", 247)
        assert(#header == 512)
        local sum = 0
        for i = 1, #header do sum = sum + header:byte(i) end
        header = header:sub(1, 148) .. ("%06o\0 "):format(sum) .. header:sub(157)
        blocks[#blocks+1] = header .. data .. string.rep("\0", (-#data) % 512)
    end
    return table.concat(blocks) .. string.rep("\0", 1024)
end
