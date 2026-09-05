--[[-- 新增输入法词库产物与 Lua 只读查询集成。
@module tests.ime.table_dictionary_spec
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

local Dictionary = require("ime.table_dictionary")

selected = "wubi"
local wubi = Dictionary:new("wubi")
Assert.is_true(wubi:isAvailable())
Assert.contains(wubi:lookup("wq"), "你")
Assert.is_true(tonumber(wubi:entries()) > 90000)
wubi:reset()

selected = "cangjie"
local cangjie = Dictionary:new("cangjie")
Assert.is_true(cangjie:isAvailable())
Assert.contains(cangjie:lookup("a"), "日")
Assert.is_true(tonumber(cangjie:entries()) > 130000)
cangjie:reset()

selected = "zhuyin"
local zhuyin = Dictionary:new("zhuyin")
Assert.is_true(zhuyin:isAvailable())
Assert.eq(zhuyin:lookup("ㄋㄧˇ")[1], "你")
Assert.is_true(tonumber(zhuyin:entries()) > 170000)
zhuyin:reset()
