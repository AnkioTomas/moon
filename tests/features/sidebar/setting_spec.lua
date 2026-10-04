--[[--
侧栏 feature 设置：缺省左边缘右滑，选中后写入 sidebar.sidebar_gesture。

@module tests.features.sidebar_setting_spec
--]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end

local sidebar = { sidebar_gesture = "edge" }
local saved
package.preload["utils.settings"] = function()
    return {
        feature = function(name) assert(name == "sidebar"); return sidebar end,
        saveSection = function(name, values) saved = { name = name, values = values } end,
    }
end
package.preload["ui.themes.widgets.row"] = function()
    return { widget = function(opts) return opts end }
end
require("support.theme_stubs").install()

local Setting = require("features.sidebar.setting")
local updates = 0
local desktop = { updateView = function() updates = updates + 1 end }
local entry = Setting.entries(desktop)[1]
Assert.eq(entry.group, "reader")
Assert.eq(entry.title, "侧栏手势")
Assert.eq(entry.status, "左边缘右滑")

local function row()
    return entry.page.sections()[1].rows[1](600)
end

Assert.eq(row().status, "左边缘右滑")
row().callback()
local picker = require("support.theme_stubs").last("list")
Assert.len(picker.items, 3)
Assert.eq(picker.current, "edge")
picker.on_select("full")
Assert.eq(sidebar.sidebar_gesture, "full")
Assert.eq(saved.name, "sidebar")
Assert.eq(updates, 1)
Assert.eq(row().status, "任意位置右滑")
