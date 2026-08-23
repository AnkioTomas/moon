--[[-- 原生 Tab 栏底部分割线同步的离线用例。 --]]

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

local bar_sep = { empty_segments = { { s = 999, e = 1000 } } }
local icon_synced
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
TouchMenu.bar = {
    menu = TouchMenu,
    icon_widgets = {
        {
            callback = function()
                icon_synced = 1
                bar_sep.empty_segments = { { s = 0, e = 80 } }
            end,
        },
        {
            callback = function()
                icon_synced = 2
                bar_sep.empty_segments = { { s = 120, e = 200 } }
            end,
        },
    },
    bar_sep = bar_sep,
}

function TouchMenu:updateItems() end
function TouchMenu:switchMenuTab() end
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

TouchMenu.cur_tab = 1
TouchMenu:updateItems()
Assert.eq(icon_synced, 1)
Assert.eq(bar_sep.empty_segments[1].s, 0)
Assert.eq(bar_sep.empty_segments[1].e, 80)

TouchMenu.cur_tab = 2
TouchMenu:updateItems()
Assert.eq(icon_synced, 2)
Assert.eq(bar_sep.empty_segments[1].s, 120)
Assert.eq(bar_sep.empty_segments[1].e, 200)
