--[[-- features.manage：停用 / 再启用，启动时只把可停用（_meta.lua）里已停用的 feature 从 list 去掉（不删文件）。 --]]
local Assert = require("support.assert")
local store = { disabled = {} }
package.loaded["utils.settings"] = {
    get = function() return store end,
    save = function() end,
}

local Manage = require("features.manage")

Assert.is_false(Manage.isMarked("ocr"))
Assert.is_true(Manage.toggle("ocr"))
Assert.is_true(Manage.isMarked("ocr"))
Assert.is_false(Manage.isSkipped("ocr")) -- 这次才点停用，本进程还加载着

store.disabled[#store.disabled + 1] = "manage" -- removable = false：篡改配置也不能停用核心
local list = { "manage", "ocr", "ai" }
local off = Manage.apply(list)
Assert.is_true(off.ocr)
Assert.is_nil(off.manage)
Assert.eq(table.concat(list, ","), "manage,ai")
Assert.is_true(Manage.isSkipped("ocr"))
Assert.is_false(Manage.isSkipped("manage"))

Assert.is_false(Manage.toggle("ocr"), "再点一次取消标记")
Assert.is_false(Manage.isMarked("ocr"))
Assert.is_true(Manage.isSkipped("ocr")) -- 启动快照不随取消标记变

-- 输入后端不是用户可开关的功能：system_text 惰性 require，system_ime 启动时
-- 要捕获插件路径；把它们停掉只会得到「开关无效」。
local ids = {}
for _idx, item in ipairs(Manage.items()) do ids[item.id] = true end
Assert.is_nil(ids.system_ime, "system_ime 不开放停用")
Assert.is_nil(ids.system_text, "system_text 不开放停用")
store.disabled[#store.disabled + 1] = "system_ime"
local backends = { "ime", "system_ime", "system_text" }
local off_backends = Manage.apply(backends)
Assert.is_nil(off_backends.system_ime, "篡改配置也不能停用输入后端")
Assert.eq(table.concat(backends, ","), "ime,system_ime,system_text")

-- 不连带：停一个只动它自己；这次才停的不算已跳过
Manage.toggle("lockscreen")
Assert.is_true(Manage.isMarked("lockscreen"))
Assert.is_false(Manage.isSkipped("lockscreen"))
Assert.is_false(Manage.isMarked("panel"))
