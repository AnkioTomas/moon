--[[-- 字体映射默认关闭，设置开关持久化但保留已有映射。
@module tests.features.fontmap.setting_spec
--]]
---@diagnostic disable: missing-fields
local Assert = require("support.assert")
local Setting = require("features.fontmap.setting")
Assert.eq(Setting.defaults.enabled, false)
local mappings = { Kai = { id = "kai", name = "Kai" } }
local settings = { enabled = false, mappings = mappings }
local saved, updated = 0, 0
package.loaded["utils.settings"] = {
    get = function(owner) Assert.eq(owner, "features.fontmap"); return settings end,
    save = function(owner) Assert.eq(owner, "features.fontmap"); saved = saved + 1 end,
}
package.loaded["ui.themes.widgets.row"] = { widget = function(opts) return opts end }
local entries = Setting.entries({ updateView = function() updated = updated + 1 end })
Assert.eq(entries[1].group, "reader")
local row = entries[1].row(500)
Assert.eq(row.status_on, false)
row.callback()
Assert.eq(settings.enabled, true)
Assert.eq(saved, 1)
Assert.eq(updated, 1)
row = entries[1].row(500)
Assert.eq(row.status_on, true)
row.callback()
Assert.eq(settings.enabled, false)
Assert.eq(saved, 2)
Assert.eq(updated, 2)
Assert.eq(settings.mappings, mappings, "关闭不清空用户映射")
