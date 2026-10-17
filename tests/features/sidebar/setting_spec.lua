--[[--
侧栏 feature 设置：缺省左边缘右滑，选中后写入 sidebar.sidebar_gesture；
页面多选写入 sidebar_hidden_tabs，最后一页不让取消。

@module tests.features.sidebar_setting_spec
--]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end

local sidebar = { sidebar_gesture = "edge", sidebar_hidden_tabs = {}, sidebar_tab_order = {} }
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
Assert.eq(entry.parent, "reader_behavior")

local function row()
    return entry.sections()[1].rows[1](600)
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
    return entry.sections()[1].rows[2](600)
end
Assert.eq(tabsRow().status, "7 / 7")
tabsRow().callback()
local tabs = require("support.theme_stubs").last("list")
Assert.is_true(tabs.multi)
Assert.len(tabs.items, 7)
Assert.eq(tabs.items[3].mandatory, "文档支持时显示")
local function toggle(index)
    local item = tabs.items[index]
    item.checked = not item.checked
    tabs.on_toggle(item.value, item.checked, item)
end
toggle(2)
Assert.eq(table.concat(sidebar.sidebar_hidden_tabs, ","), "toc")
Assert.eq(saved.values, sidebar)
Assert.eq(tabsRow().status, "6 / 7")
for _idx, index in ipairs({ 1, 3, 4, 5, 6 }) do toggle(index) end
Assert.eq(table.concat(sidebar.sidebar_hidden_tabs, ","), "info,toc,font,notes,xray,ticket")
toggle(7)
Assert.is_true(tabs.items[7].checked, "最后一页勾回去")
Assert.eq(table.concat(sidebar.sidebar_hidden_tabs, ","), "info,toc,font,notes,xray,ticket", "不落盘全隐藏")
Assert.not_nil(require("support.theme_stubs").last("toast"))
toggle(2)
Assert.eq(table.concat(sidebar.sidebar_hidden_tabs, ","), "info,font,notes,xray,ticket")
updates = 0
tabs.close_callback()
Assert.eq(updates, 1, "关窗刷新设置页")

-- 页面顺序：每行右侧上移 / 下移按钮，顺序落盘；排序后的列表用同一份顺序。
local Themed = require("support.theme_stubs")
package.preload["ui.themes.widgets.button"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ui/widget/horizontalgroup"] = function()
    return { new = function(_, group) return group end }
end
package.preload["ui/widget/horizontalspan"] = function()
    return { new = function(_, span) return span end }
end
package.preload["ui.themes"] = function() return { px = function(n) return n end } end
entry.sections()[1].rows[3](600).callback()
local order = Themed.last("list")
Assert.eq(order.items[1].text, "书籍")
local first = order.items[1].widget()
Assert.is_false(first[1].enabled, "第一页不能上移")
first[3].callback()
Assert.eq(table.concat(sidebar.sidebar_tab_order, ",", 1, 2), "toc,info")
Assert.eq(order.items[1].text, "目录")
Assert.eq(Setting.orderedTabs(sidebar)[2].id, "info")
sidebar.sidebar_tab_order = { "stats", "bogus" }
local ordered = Setting.orderedTabs(sidebar)
Assert.eq(#ordered, 7)
Assert.eq(ordered[1].id, "stats")
Assert.eq(ordered[2].id, "info")
