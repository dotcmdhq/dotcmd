local format = require('dotcmd.format')

test('plain strips styles and preserves nested text', function()
    local style = { fg = 'red', bold = true }
    assert(format.plain({ style = style, 'error: ', { bold = false, underline = true, 'details' },
        ' ', true, ' ', false, ' ', 42, '\n' }) == 'error: details true false 42\n')
end)

test('ansi scopes nested styles and restores their parents', function()
    local markup = { fg = 'red', bold = true, 'red ',
        { bold = false, underline = true, 'under' }, ' red' }
    assert(format.ansi(markup) == '\27[1;31mred \27[22;4munder\27[1;24m red\27[22;39m')
    assert(format.ansi({ fg = 'red', 'a', { fg = false, 'b' }, 'c' })
        == '\27[31ma\27[39mb\27[31mc\27[39m')
end)

test('style tables support colors and direct keys take precedence', function()
    local style = { fg = 'red', bg = 17, bold = true, dim = true, underline = true }
    local markup = { style = style, fg = '#010203', bold = false, underline = false, 'x' }
    assert(format.ansi(markup) == '\27[2;38;2;1;2;3;48;5;17mx\27[22;39;49m')
    assert(format.ansi({ fg = 'bright_blue', bg = 'bright_white', 'x' })
        == '\27[94;107mx\27[39;49m')
end)

test('writer detects a regular file once and writes plain text', function()
    local file <close> = assert(io.tmpfile())
    local output = format.writer(file)
    assert(output:write({ fg = 'red', bold = true, 'plain' }) == output)
    assert(output:flush() == output)
    assert(file:seek('set') == 0)
    assert(file:read('a') == 'plain')
end)
