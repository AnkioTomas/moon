--[[--
侧栏 feature 设置：缺省左边缘右滑，选中后写入 sidebar.sidebar_gesture；
页面多选写入 sidebar_hidden_tabs，最后一页不让取消。

@module tests.features.sidebar_setting_spec
--]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end

local sidebar = { sidebar_gesture = "edge", sidebar_hidden_tabs = {} }
local saved
package.preload["utils.settings"] = function()
    return {
        get = function(name) assert(name == "features.sidebar"); return sidebar end,
        save = function(name, values) saved = { name = name, values = values } end,
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
Assert.eq(entry.title, "阅读侧栏")
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
Assert.eq(saved.name, "features.sidebar")
Assert.eq(updates, 1)
Assert.eq(row().status, "任意位置右滑")

-- 页面：全部缺省显示；取消即落盘隐藏列表；最后一页不让取消。
local function tabsRow()
    return entry.page.sections()[1].rows[2](600)
end
Assert.eq(tabsRow().status, "6 / 6")
tabsRow().callback()
local tabs = require("support.theme_stubs").last("list")
Assert.is_true(tabs.multi)
Assert.len(tabs.items, 6)
Assert.eq(tabs.items[3].mandatory, "文档支持时显示")
local function toggle(index)
    local item = tabs.items[index]
    item.checked = not item.checked
    tabs.on_toggle(item.value, item.checked, item)
end
toggle(2)
Assert.eq(table.concat(sidebar.sidebar_hidden_tabs, ","), "toc")
Assert.eq(saved.values, sidebar)
Assert.eq(tabsRow().status, "5 / 6")
for _idx, index in ipairs({ 1, 3, 4, 5 }) do toggle(index) end
Assert.eq(table.concat(sidebar.sidebar_hidden_tabs, ","), "info,toc,font,notes,xray")
toggle(6)
Assert.is_true(tabs.items[6].checked, "最后一页勾回去")
Assert.eq(table.concat(sidebar.sidebar_hidden_tabs, ","), "info,toc,font,notes,xray", "不落盘全隐藏")
Assert.not_nil(require("support.theme_stubs").last("toast"))
toggle(2)
Assert.eq(table.concat(sidebar.sidebar_hidden_tabs, ","), "info,font,notes,xray")
updates = 0
tabs.close_callback()
Assert.eq(updates, 1, "关窗刷新设置页")
