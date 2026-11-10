--[[-- 九宫格：数字串展开拼音码、键位行宽。
@module tests.features.ime.t9_spec
--]]

local Assert = require("support.assert")

package.preload["features.ime.pinyin.dictionary"] = function()
    return { SYLLABLES = { "ni", "mi", "hao", "gao", "ha", "n", "xi", "an", "xian" } }
end

local T9 = require("features.ime.t9")

Assert.eq(T9.mapKey("6"), "6")
Assert.is_nil(T9.mapKey("1"))
Assert.is_nil(T9.mapKey("a"))

-- 64426：ni+hao / mi+gao 等；完整切分排在半截前
local codes = T9.codes("64426")
Assert.contains(codes, "nihao")
Assert.contains(codes, "migao")

-- 单键给字母；多键合并去重并按码顺序
Assert.eq(table.concat(T9.lookup({}, "6"), ""), "mno")
local dict = { lookup = function(_, code) return { code .. "1", "dup" } end }
local words = T9.lookup(dict, "64")
Assert.contains(words, "dup")
local n = 0
for _, w in ipairs(words) do if w == "dup" then n = n + 1 end end
Assert.eq(n, 1)

-- 同键位的读音按名次交错：第一个码的词再多也不能挤掉 ni
local many = {}
for i = 1, 30 do many[i] = "m" .. i end
local ranked = T9.lookup({ lookup = function(_, code)
    return code == "mi" and many or { "你" }
end }, "64")
local pos
for i, w in ipairs(ranked) do if w == "你" then pos = i end end
Assert.is_true(pos ~= nil and pos <= 3, "你 必须排在前几位")

-- 每行宽度合计 10，对齐候选行的 10 个占位键
local base = {
    [4] = { [9] = { label = "⌫", width = 1.5 } },
    [5] = { [2] = { label = "G" }, [4] = { label = "空格" }, [7] = { label = "⮠" } },
}
local rows = T9.rows(base)
for _, row in ipairs(rows) do
    local sum = 0
    for _, key in ipairs(row) do sum = sum + key.width end
    Assert.eq(sum, 10)
end

local function cap(row, col)
    local item = rows[row][col]
    -- 从基线拷来的退格/地球/空格/回车是扁平键（label 在自身上），其余是四层包装。
    if type(item.label) == "string" and item.label ~= "" then return item.label end
    local entry = item[1]
    return type(entry) == "table" and entry.label or entry
end

-- 左侧独立标点列：，。？！（底行左侧也是标点）
Assert.eq(cap(1, 1), "，")
Assert.eq(cap(2, 1), "。")
Assert.eq(cap(3, 1), "？")
Assert.eq(cap(4, 1), "！")
Assert.eq(rows[1][1].width, 1.5)
Assert.eq(rows[2][1].width, 1.5)
Assert.eq(rows[3][1].width, 1.5)
Assert.eq(rows[4][1].width, 1.5)

-- 字母 1–9 与手机拨号盘对齐：1 ABC DEF / GHI JKL MNO / PQRS TUV WXYZ
Assert.eq(cap(1, 2), "@.")
Assert.eq(rows[1][2][1].alt_label, "1")
Assert.eq(cap(1, 3), "ABC")
Assert.eq(cap(1, 4), "DEF")
Assert.eq(cap(2, 2), "GHI")
Assert.eq(cap(2, 3), "JKL")
Assert.eq(cap(2, 4), "MNO")
Assert.eq(cap(3, 2), "PQRS")
Assert.eq(cap(3, 3), "TUV")
Assert.eq(cap(3, 4), "WXYZ")
for _, pos in ipairs({ {1, 2}, {1, 3}, {1, 4}, {2, 2}, {2, 3}, {2, 4}, {3, 2}, {3, 3}, {3, 4} }) do
    Assert.eq(rows[pos[1]][pos[2]].width, 2.25)
end

-- 右列：退格在 3 旁、0 在 9 旁；6 旁是顿号占位（无现成重输键）
Assert.eq(cap(1, 5), "⌫")
Assert.eq(cap(2, 5), "、")
Assert.eq(cap(3, 5), "0")
Assert.eq(rows[1][5].width, 1.75)
Assert.eq(rows[2][5].width, 1.75)
Assert.eq(rows[3][5].width, 1.75)

-- 每行 5 键（底行：！、地球、空格、回车）
Assert.eq(#rows[1], 5)
Assert.eq(#rows[2], 5)
Assert.eq(#rows[3], 5)
Assert.eq(#rows[4], 4)
Assert.eq(cap(4, 2), "G")
Assert.eq(cap(4, 3), "空格")
Assert.eq(rows[4][2].width, 1.75)
Assert.eq(rows[4][3].width, 5)
Assert.eq(rows[4][4].width, 1.75)
