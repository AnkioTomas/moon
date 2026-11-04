--[[--
source.kindle.setting：没装 kindle.koplugin 也有设置页，状态随安装版本变。

@module tests.source.kindle.setting_spec
--]]
---@diagnostic disable: undefined-field, missing-fields

local Assert = require("support.assert")

local version
package.loaded["source.kindle.plugin_update"] = { target = { installed = function() return version end } }
package.loaded["source.kindle.setting"] = nil
local Setting = require("source.kindle.setting")

local status, on = Setting.rowStatus()
Assert.eq(status, "未安装")
Assert.is_false(on)

version = "0.0.11"
status, on = Setting.rowStatus()
Assert.eq(status, "v0.0.11")
Assert.is_true(on)

Assert.len(Setting.rows(nil), 2, "插件行 + 安装说明")
