--[[--
syncBarSeparator 的离线用例。

分割线段本身由 KOReader 原生 icon callback 计算，测试无法也不该复刻；这里只钉住
自绘渲染必须保证的三件事：调当前 tab 的 callback、回调期间 switchMenuTab 是 noop、
回调结束（含抛异常）必须还原 switchMenuTab。
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["logger"] = function() return { err = function() end } end
package.preload["device"] = function()
    return { isTouchDevice = function() return true end, hasBattery = function() return false end }
end
package.preload["datetime"] = function() return { secondsToHour = function() return "12:34" end } end
package.preload["ui/bidi"] = function() return { wrap = function(t) return t end } end
_G.G_reader_settings = { isTrue = function() return false end }
local full_repaints = 0
package.preload["ui/uimanager"] = function()
    return {
        show = function() end,
        setDirty = function(_, widget, refresh)
            if widget == "all" and refresh == "full" then full_repaints = full_repaints + 1 end
        end,
    }
end
local ui_conf = { mesh_mask = true }
package.preload["utils.settings"] = function()
    return { get = function(name) assert(name == "ui"); return ui_conf end }
end
local guarded = {}
package.preload["ui.guard"] = function()
    return {
        call = function(label, fn, ...)
            local ok, err = pcall(fn, ...)
            if not ok then guarded[#guarded + 1] = { label = label, err = err } end
        end,
        paint = function(_label, fn, ...) fn(...) end,
    }
end
local mesh_calls = {}
package.preload["ui.themes.widgets.mask"] = function()
    return {
        new = function(_, opts)
            local dimen = opts.dimen
            return { paintTo = function(_, _, x, y)
                mesh_calls[#mesh_calls + 1] = { x = x, y = y, w = dimen.w, h = dimen.h }
            end }
        end,
    }
end

-- buildPanel 依赖的轻量桩，只验证分割线同步，不渲染真实面板。
package.preload["ui.themes.widgets.box"] = function()
    return { new = function(_, o) return o end }
end
package.preload["ui/geometry"] = function()
    return { new = function(_, o) return o end }
end
package.preload["ui.themes"] = function()
    return {
        px = function(n) return n end,
        current = function()
            return { space = { sm = 8, lg = 16 }, color = { page = 255 } }
        end,
    }
end
local body_show_parent
package.preload["features.panel.widget.body"] = function()
    return {
        new = function(_, o)
            body_show_parent = o.show_parent
            return setmetatable(o, { __index = { getSize = function() return { h = 100 } end } })
        end,
    }
end
package.preload["features.panel.widget.header"] = function()
    return { new = function(o) return o end }
end
package.preload["features.panel.desktop"] = function()
    return {
        menuActions = function() return {} end,
        sliders = function() return {} end,
        executeAction = function() return true end,
    }
end
package.preload["features.panel.reader"] = function()
    return {
        actions = function() return {} end,
        executeAction = function() return true end,
    }
end

local icon_synced
-- 回调里看到的 switchMenuTab 必须是被临时换掉的 noop，不能是原生实现
local switch_seen
local time_text
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
    time_info = { setText = function(_, text) time_text = text end },
    page_info_text = { setText = function() end },
    page_info_left_chev = { showHide = function() end },
    page_info_right_chev = { showHide = function() end },
    item_group = {
        clear = function() end,
        getSize = function() return { h = 100 } end,
    },
    screen_size = { w = 800, h = 1200 },
    dimen = {
        y = 0,
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

-- 原生 updateItems 只模拟它改菜单高度
local native_items_h
function TouchMenu:updateItems()
    if native_items_h then self.dimen.h = native_items_h end
end
local native_painted
function TouchMenu:paintTo() native_painted = true end

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

local Native = require("features.panel.native")
Native.onCreate()

-- 渲染当前 tab：调对应 icon callback，回调里 switchMenuTab 被 noop 掉，事后还原
TouchMenu.cur_tab = 1
TouchMenu:updateItems()
Assert.eq(icon_synced, 1)
Assert.eq(body_show_parent, TouchMenu.show_parent, "动态子控件必须把窗口级 show_parent 用于重绘")
Assert.is_false(switch_seen == native_switch, "回调期间 switchMenuTab 必须是 noop")
Assert.eq(switch_calls, 0, "noop 期间的切 tab 不得真的执行")
Assert.eq(TouchMenu.switchMenuTab, native_switch, "回调结束必须还原 switchMenuTab")

-- 面板分支不走原生 updateItems：页脚时间要自己写（首次直接落在面板 Tab 时曾一直为空）
Assert.eq(time_text, "12:34")

-- 换 tab：跟着 cur_tab 走，不是永远调第一个
TouchMenu.cur_tab = 2
TouchMenu:updateItems()
Assert.eq(icon_synced, 2)
Assert.eq(TouchMenu.switchMenuTab, native_switch)

-- 回调抛异常：异常交给入口 guard 报告（不静默吞），且 switchMenuTab 不能留在 noop 状态
raise = true
icon_synced = nil
TouchMenu:updateItems()
raise = false
Assert.len(guarded, 1, "icon callback 的异常必须经 guard 报告")
Assert.matches(tostring(guarded[1].err), "icon callback boom")
Assert.eq(TouchMenu.switchMenuTab, native_switch, "异常路径同样必须还原 switchMenuTab")
Assert.eq(icon_synced, 2, "抛错前的副作用照旧生效")

-- 没有 icon_widgets 时安全跳过，不炸
TouchMenu.bar.icon_widgets = nil
TouchMenu.cur_tab = 1
TouchMenu:updateItems()
Assert.eq(TouchMenu.switchMenuTab, native_switch)

-- 菜单下方铺网状遮罩：从菜单下沿画到屏底
TouchMenu.screen_size = { w = 800, h = 1200 }
TouchMenu.dimen.y, TouchMenu.dimen.h = 0, 300
TouchMenu:paintTo({}, 0, 0)
Assert.is_true(native_painted, "原生菜单必须照常绘制")
Assert.eq(mesh_calls[1].y, 300)
Assert.eq(mesh_calls[1].h, 900)
Assert.eq(mesh_calls[1].w, 800)

-- 菜单占满屏：不画遮罩
TouchMenu.dimen.h = 1200
TouchMenu:paintTo({}, 0, 0)
Assert.len(mesh_calls, 1)

-- 遮罩开着、菜单高度变了（切 tab）：整屏重画 + 全刷，否则新旧网点错位叠黑
TouchMenu.item_table = {}
native_items_h = 400
full_repaints = 0
TouchMenu.dimen.h = 300
TouchMenu:updateItems()
Assert.eq(full_repaints, 1, "高度变化必须整屏重画并全刷")

-- 高度不变（菜单内勾选、刷新）：网点落在同一批像素上，不闪屏
TouchMenu:updateItems()
Assert.eq(full_repaints, 1)

-- 刚打开：下方还没有遮罩像素，同样全刷一次
TouchMenu.is_fresh = true
TouchMenu:updateItems()
TouchMenu.is_fresh = false
Assert.eq(full_repaints, 2)

-- 关了遮罩：不画也不额外刷新
ui_conf.mesh_mask = false
native_items_h = 500
TouchMenu:updateItems()
Assert.eq(full_repaints, 2)
ui_conf.mesh_mask = true

-- 菜单占满屏：没有遮罩区，不全刷
native_items_h = 1200
TouchMenu:updateItems()
Assert.eq(full_repaints, 2)
