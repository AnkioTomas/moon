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
    [4] = { [9] = { label = "", width = 1.5 } },
    [5] = { [2] = { label = "G" }, [4] = { label = "空格" }, [7] = { label = "⮠" } },
}
for _, row in ipairs(T9.rows(base)) do
    local sum = 0
    for _, key in ipairs(row) do sum = sum + key.width end
    Assert.eq(sum, 10)
end
