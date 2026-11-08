--[[--
番茄设置页：扫码入口与段评开关，不含 Cookie / 浏览器登录。

@module tests.source.fanqie.setting_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
package.loaded["ui.themes.widgets.row"] = { widget = function(spec) return spec end }

local cfg = {}
package.loaded["utils.settings"] = {
    getSource = function() return cfg end,
    saveSource = function(_id, value) if value then cfg = value end end,
}
package.loaded["source.category_setting"] = {
    row = function() return function(iw) return { title = "分类", width = iw } end end,
}

package.loaded["source.fanqie.setting"] = nil
local Setting = require("source.fanqie.setting")

Assert.is_nil(Setting.browser)
local rows = Setting.rows()
Assert.eq(rows[1](400).title, "番茄账号与登录")
Assert.eq(rows[2](400).title, "显示段评")
for _idx, factory in ipairs(rows) do
    local row = factory(400)
    Assert.is_true(row.title ~= "浏览器登录" and row.title ~= "粘贴 Cookie")
end
