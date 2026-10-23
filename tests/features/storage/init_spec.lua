--[[--
storage：可用空间低于 500MB 才弹窗，每个进程只弹一次，取不到空间不弹。
@module tests.features.storage.init_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Themed = require("support.theme_stubs")

Stubs.install()
Themed.install()

local available = 100 * 1024 * 1024
-- df 返回 total, free[, available]；旧 KOReader 没有第三个值
local free
local base = require("ffi/util")
package.loaded["ffi/util"] = { template = base.template,
    df = function() return available and 1e10 or nil, free or available, free and available or nil end }
package.loaded["datastorage"] = { getDataDir = function() return "/tmp" end }

local Storage = require("features.storage")

available = 600 * 1024 * 1024
Assert.eq(Storage.check(), false, "空间充足不弹")
Assert.eq(#Themed.made, 0)

available = nil
Assert.eq(Storage.check(), false, "df 失败不弹")

available = 100 * 1024 * 1024
Assert.eq(Storage.check(), true)
Assert.eq(Themed.last("confirm").shown, true)
Assert.matches(Themed.last("confirm").text, "100 MB")

Assert.eq(Storage.check(), false, "同一进程只弹一次")

Assert.eq(Storage.disk().available, 100 * 1024 * 1024, "没有 available 时取 free")
free = 7
Assert.eq(Storage.disk().available, 100 * 1024 * 1024)
Assert.eq(Storage.disk().used, 1e10 - 7)
