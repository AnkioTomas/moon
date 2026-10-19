--[[-- features.manage：停用 / 再启用，启动时只把 ITEMS 里已停用的 feature 从 list 去掉（不删文件）。 --]]
local Assert = require("support.assert")
local store = { disabled = {} }
package.loaded["utils.settings"] = {
    get = function() return store end,
    save = function() end,
}
package.loaded["libs/libkoreader-lfs"] = { attributes = function() return "directory" end }

local Manage = require("features.manage")

Assert.is_false(Manage.isMarked("ocr"))
Assert.is_true(Manage.toggle("ocr"))
Assert.is_true(Manage.isMarked("ocr"))

store.disabled[#store.disabled + 1] = "manage" -- 不在 ITEMS 里：篡改配置也不能停用核心
local list = { "manage", "ocr", "ai" }
local off = Manage.apply(list)
Assert.is_true(off.ocr)
Assert.is_nil(off.manage)
Assert.eq(table.concat(list, ","), "manage,ai")

Assert.is_false(Manage.toggle("ocr"), "再点一次取消标记")
Assert.is_false(Manage.isMarked("ocr"))

-- 不连带：停一个只动它自己
Manage.toggle("lockscreen")
Assert.is_true(Manage.isMarked("lockscreen"))
Assert.is_false(Manage.isMarked("panel"))
