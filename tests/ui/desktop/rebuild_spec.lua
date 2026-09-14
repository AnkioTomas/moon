--[[--
桌面首帧 build：OverlapGroup:init 会对每个孩子 getSize。
内容与顶栏同路，直接嵌当前页 widget。
updateView 换底栏选中态时必须 dirty（根 widget 身份不变）。
--]]

local Assert = require("support.assert")

local function emptyModule() return {} end
for _, name in ipairs({
    "ui/bidi",
    "ui/gesturerange",
    "ui.desktop.library",
    "ui.desktop.store",
    "ui.desktop.insight",
    "ui.desktop.settings",
    "ui.desktop.home",
    "ui.lifecycle",
}) do
    package.preload[name] = emptyModule
end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = 255 }
end
local screen_w, screen_h = 600, 800
package.preload["device"] = function()
    return {
        screen = {
            getWidth = function() return screen_w end,
            getHeight = function() return screen_h end,
        },
    }
end
package.preload["ui/geometry"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["utils.log"] = function()
    return { dbg = function() end, err = function() end, info = function() end }
end
local dirty = {}
package.preload["ui/uimanager"] = function()
    return {
        show = function() end,
        setDirty = function(_, host, mode, rect)
            dirty[#dirty + 1] = { host = host, mode = mode, rect = rect }
        end,
    }
end
package.preload["gettext"] = function()
    return function(text) return text end
end
package.preload["ui/widget/container/inputcontainer"] = function()
    return { extend = function(_, value) return value end }
end
package.preload["ui.components.bookui"] = function()
    return { barH = function() return 48 end, topBarH = function() return 36 end }
end
package.preload["ui.views.topbar"] = emptyModule
package.preload["ui.views.bottombar"] = emptyModule

package.preload["ui/widget/widget"] = function()
    return {
        new = function(_, o)
            o.getSize = function(self) return self.dimen end
            return o
        end,
    }
end
package.preload["ui/widget/container/framecontainer"] = function()
    return {
        new = function(_, o)
            function o:getSize()
                return self[1]:getSize()
            end
            return o
        end,
    }
end
package.preload["ui/widget/overlapgroup"] = function()
    return {
        new = function(_, o)
            for _, child in ipairs(o) do
                child:getSize()
            end
            return o
        end,
    }
end

package.loaded["ui.desktop"] = nil
local Desktop = require("ui.desktop")

local sized = function(h)
    return {
        dimen = { w = 600, h = h or 48 },
        getSize = function(self) return self.dimen end,
    }
end
local home_widget = sized(716)
local bottom_widget = sized(48)
local desktop = {
    tab = "home",
    source = nil,
    home = {
        widget = home_widget,
        build = function() return home_widget end,
        updateView = function(self) return self.widget end,
    },
    bottombar = {
        updateView = function() return bottom_widget end,
    },
    topbar = { build = function() return sized(36) end, widget = sized(36) },
    contentHeight = function() return screen_h - 84 end,
}
desktop.lifecycle = { uiReady = function() return true end }
desktop.view = require("ui.view").attach(desktop)
Desktop.build(desktop)
Assert.not_nil(desktop[1])
Assert.not_nil(desktop[1][1])
Assert.eq(desktop[1][1][1].dimen.h, 716)

-- 已有壳时 updateView 只换槽；底栏 widget 身份不变也要 dirty 选中态。
local next_home = sized(716)
desktop.home.widget = next_home
desktop.tab = "home"
dirty = {}
Desktop.updateView(desktop)
Assert.eq(desktop[1][1][1], next_home)
Assert.eq(desktop[1][1][3], bottom_widget)
local bar_dirty = false
for _, entry in ipairs(dirty) do
    local rect = entry.rect
    if rect and rect.y == screen_h - 48 and rect.h == 48 then
        bar_dirty = true
        break
    end
end
Assert.is_true(bar_dirty, "stable bottombar widget still needs a paint")

-- Rotation keeps the Desktop skeleton but rebuilds affected layouts at the new size.
local desktop_root = desktop[1]
local home_relayouts, top_relayouts = 0, 0
function desktop.home:updateView()
    home_relayouts = home_relayouts + 1
    self.widget = sized(screen_h - 84)
    return self.widget
end
function desktop.topbar:updateView() top_relayouts = top_relayouts + 1 end
screen_w, screen_h = 800, 600
Desktop.updateView(desktop)
Assert.eq(desktop[1], desktop_root)
Assert.eq(desktop[1][1].dimen.w, 800)
Assert.eq(desktop[1][1].dimen.h, 600)
Assert.eq(home_relayouts, 1)
Assert.eq(top_relayouts, 1)
