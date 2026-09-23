--[[--
锁屏标题单行布局测试。
--]]

local Assert = require("support.assert")
local Title = require("lockscreen.title")

local function measure(text, width, size)
    return math.ceil(#text * size / 2 / width) * size
end

local text, size = Title.fitSingleLine("short title", 200, 30, 18, measure)
Assert.eq(text, "short title")
Assert.eq(size, 30)

text, size = Title.fitSingleLine("这是一个很长的中文书名，包含 English 混合字符", 80, 30, 18, measure)
Assert.is_true(size < 30)
Assert.matches(text, "…$")

text, size = Title.fitSingleLine(string.rep("x", 200), 40, 30, 18, measure)
Assert.eq(size, 18)
Assert.matches(text, "^x+…$")

text = Title.fitSingleLine("", 100, 30, 18, measure)
Assert.eq(text, "")
