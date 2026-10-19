--[[-- features.manage：标记 / 取消标记，启动时只删 ITEMS 里的已标记目录并从 list 去掉。 --]]
local Assert = require("support.assert")
local removed = {}
local purged = {}
package.loaded["utils.settings"] = {
    get = function() return { removed = removed } end,
    save = function() end,
}
package.loaded["ffi/util"] = { purgeDir = function(path) purged[#purged + 1] = path end }
package.loaded["libs/libkoreader-lfs"] = { attributes = function() return "directory" end }

local Manage = require("features.manage")

Assert.is_false(Manage.isMarked("ocr"))
Assert.is_true(Manage.toggle("ocr"))
Assert.is_true(Manage.isMarked("ocr"))

removed[#removed + 1] = "panel" -- 不在 ITEMS 里：篡改配置也不能删核心目录
local list = { "panel", "ocr", "ai" }
Manage.purge("/p/features", list)
Assert.eq(table.concat(purged, ","), "/p/features/ocr")
Assert.eq(table.concat(list, ","), "panel,ai")

Assert.is_false(Manage.toggle("ocr"), "再点一次取消标记")
Assert.is_false(Manage.isMarked("ocr"))
