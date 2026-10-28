--[[-- 新增输入法词库产物与 Lua 只读查询集成。
@module tests.features.ime.table_dictionary_spec
--]]

local Assert = require("support.assert")

local selected
local paths = {
    wubi = "assets/ime/wubi/dictionary.sqlite3.part.001",
    cangjie = "assets/ime/cangjie/dictionary.sqlite3.part.001",
    zhuyin = "assets/ime/zhuyin/dictionary.sqlite3.part.001",
}
package.loaded["utils.paths"] = nil
package.preload["utils.paths"] = function()
    return { imeDictPath = function() return paths[selected] end }
end

local sqlite_ok = pcall(require, "lua-ljsqlite3/init")
if not sqlite_ok then
    Assert.skip("当前离线环境没有 ljsqlite3 Lua 模块")
end

local Dictionary = require("features.ime.table_dictionary")

selected = "wubi"
local wubi = Dictionary:new("wubi")
local wubi_path = paths.wubi
paths.wubi = "test/.missing-wubi-dictionary.sqlite3"
Assert.is_false(wubi:isAvailable())
paths.wubi = wubi_path
Assert.is_true(wubi:isAvailable(), "手动落盘后不得要求重启或显式 reset")
Assert.contains(wubi:lookup("wq"), "你")
Assert.is_true(tonumber(wubi:entries()) > 90000)
wubi:reset()

selected = "cangjie"
local cangjie = Dictionary:new("cangjie")
Assert.is_true(cangjie:isAvailable())
Assert.contains(cangjie:lookup("a"), "日")
Assert.is_true(tonumber(cangjie:entries()) > 130000)
-- 速成首尾码：按字频排，常用字在前、多码同字只出一次
local quick = cangjie:glob("a*b")
Assert.eq(quick[1], "明")
Assert.contains(quick, "晴")
local seen = {}
for _idx, word in ipairs(cangjie:glob("o*o")) do
    Assert.is_nil(seen[word], "重复候选: " .. word)
    seen[word] = true
end
Assert.eq(cangjie:glob("o*o")[1], "像")
Assert.is_nil(seen["人"], "单码字「人」(o) 不是两键速成码 oo 的候选")
cangjie:reset()

selected = "zhuyin"
local zhuyin = Dictionary:new("zhuyin")
Assert.is_true(zhuyin:isAvailable())
Assert.eq(zhuyin:lookup("ㄋㄧˇ")[1], "你")
Assert.is_true(tonumber(zhuyin:entries()) > 170000)
zhuyin:reset()
