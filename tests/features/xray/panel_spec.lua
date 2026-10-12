--[[-- X-Ray 快捷开关：按 book_xray_enabled 决定可用性；打开 / 刷新交给 xray.ui。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end

-- 必须打桩：available 读的是真实配置文件，否则开发者在模拟器里关掉 X-Ray 就会让本用例变红。
local settings = {}
package.preload["utils.settings"] = function()
    return { get = function(name) assert(name == "features.xray"); return settings end }
end

local opened_ui, refreshed_ui
package.preload["features.xray.ui"] = function()
    return {
        openMain = function(ui) opened_ui = ui end,
        refresh = function(ui) refreshed_ui = ui end,
    }
end

local actions = require("features.xray.panel").actions()
Assert.len(actions, 2)
local xray, refresh = actions[1], actions[2]
Assert.eq(xray.id, "xray")
Assert.eq(xray.scope, "reader")
Assert.eq(refresh.id, "xray_refresh")
Assert.eq(refresh.title, "刷新 X-Ray")
Assert.eq(refresh.icon, "sync")

settings.book_xray_enabled = true
Assert.is_true(xray.available())
Assert.is_true(refresh.available())
settings.book_xray_enabled = false
Assert.is_false(xray.available())
Assert.is_false(refresh.available())

local reader_ui = {}
xray.run({ ui = reader_ui })
Assert.eq(opened_ui, reader_ui)
refresh.run({ ui = reader_ui })
Assert.eq(refreshed_ui, reader_ui)
