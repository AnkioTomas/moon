--[[--
syncBarSeparator 的离线用例。

分割线段本身由 KOReader 原生 icon callback 计算，测试无法也不该复刻；这里只钉住
自绘渲染必须保证的三件事：调当前 tab 的 callback、回调期间 switchMenuTab 是 noop、
回调结束（含抛异常）必须还原 switchMenuTab。
--]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["logger"] = function() return { err = function() end } end
package.preload["device"] = function()
    return { isTouchDevice = function() return true end }
end
package.preload["ui/uimanager"] = function()
    return { show = function() end, setDirty = function() end }
end

-- buildPanel 依赖的轻量桩，只验证分割线同步，不渲染真实面板。
package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE = 1 } end
package.preload["ui/widget/container/framecontainer"] = function()
    return { new = function(o) return o end }
end
package.preload["ui/geometry"] = function()
    return { new = function(o) return o end }
end
package.preload["ui.components.bookui"] = function()
    return { sz = function(value) return value end }
end
package.preload["ui.panel.widget.body"] = function()
    return { new = function(o) return setmetatable(o, { __index = { getSize = function() return { h = 100 } end } }) end }
end
package.preload["ui.panel.widget.header"] = function()
    return { new = function(o) return o end }
end
package.preload["ui.panel.desktop"] = function()
    return {
        menuActions = function() return {} end,
        sliders = function() return {} end,
        executeAction = function() return true end,
    }
end
package.preload["ui.panel.reader"] = function()
    return {
        actions = function() return {} end,
        executeAction = function() return true end,
    }
end

local icon_synced
-- 回调里看到的 switchMenuTab 必须是被临时换掉的 noop，不能是原生实现
local switch_seen
local raise
local TouchMenu = {
    cur_tab = 1,
    item_table = { _book_quick_panel = true },
    item_table_stack = {},
    layout = {},
    bordersize = 0,
    padding = 0,
    width = 800,
    item_width = 760,
    is_fresh = false,
    show_parent = "all",
    footer_top_margin = {},
    footer = {},
    page_info_text = { setText = function() end },
    page_info_left_chev = { showHide = function() end },
    page_info_right_chev = { showHide = function() end },
    item_group = {
        clear = function() end,
        getSize = function() return { h = 100 } end,
    },
    dimen = {
        w = 0,
        h = 0,
        copy = function() return { combine = function() return {} end, w = 0, h = 0 } end,
    },
}
---@param tab integer
local function iconWidget(tab)
    return {
        callback = function()
            icon_synced = tab
            switch_seen = TouchMenu.switchMenuTab
            -- 原生 callback 会切 tab；若 switchMenuTab 没被 noop 掉，这里就会递归重入
            TouchMenu:switchMenuTab(tab)
            if raise then error("icon callback boom", 0) end
        end,
    }
end

TouchMenu.bar = {
    menu = TouchMenu,
    icon_widgets = { iconWidget(1), iconWidget(2) },
    bar_sep = { empty_segments = {} },
}

function TouchMenu:updateItems() end

local switch_calls = 0
local native_switch = function() switch_calls = switch_calls + 1 end
TouchMenu.switchMenuTab = native_switch
package.preload["ui/widget/touchmenu"] = function() return TouchMenu end

package.preload["apps/filemanager/filemanagermenu"] = function()
    return { setUpdateItemTable = function() end }
end
package.preload["apps/reader/modules/readermenu"] = function()
    return { setUpdateItemTable = function() end }
end
package.preload["apps/filemanager/filemanager"] = function()
    return { instance = nil }
end
package.preload["apps/reader/readerui"] = function()
    return { instance = nil }
end

local Native = require("ui.panel.native")
Native.install()

-- 渲染当前 tab：调对应 icon callback，回调里 switchMenuTab 被 noop 掉，事后还原
TouchMenu.cur_tab = 1
TouchMenu:updateItems()
Assert.eq(icon_synced, 1)
Assert.is_false(switch_seen == native_switch, "回调期间 switchMenuTab 必须是 noop")
Assert.eq(switch_calls, 0, "noop 期间的切 tab 不得真的执行")
Assert.eq(TouchMenu.switchMenuTab, native_switch, "回调结束必须还原 switchMenuTab")

-- 换 tab：跟着 cur_tab 走，不是永远调第一个
TouchMenu.cur_tab = 2
TouchMenu:updateItems()
Assert.eq(icon_synced, 2)
Assert.eq(TouchMenu.switchMenuTab, native_switch)

-- 回调抛异常：异常必须原样冒出去，但 switchMenuTab 不能留在 noop 状态
raise = true
icon_synced = nil
local ok, err = pcall(function() TouchMenu:updateItems() end)
raise = false
Assert.is_false(ok, "icon callback 的异常不得被吞掉")
Assert.matches(tostring(err), "icon callback boom")
Assert.eq(TouchMenu.switchMenuTab, native_switch, "异常路径同样必须还原 switchMenuTab")
Assert.eq(icon_synced, 2, "抛错前的副作用照旧生效")

-- 没有 icon_widgets 时安全跳过，不炸
TouchMenu.bar.icon_widgets = nil
TouchMenu.cur_tab = 1
TouchMenu:updateItems()
Assert.eq(TouchMenu.switchMenuTab, native_switch)
