--[[-- 设置预览：示意条 / 空态走同一条框。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["ffi/util"] = function()
    return { template = function(text, value) return text:gsub("%%1", tostring(value)) end }
end

local home = { home_topbar_items = { memory = false } }
package.preload["utils.settings"] = function()
    return { get = function() return home end, saveSection = function() end }
end
package.preload["ui.components.settingrow"] = function()
    return { build = function(_, opts) return opts end }
end

local status_text
local preview_h
package.preload["ui.desktop.settings.overlay"] = function()
    return {
        previewBox = function(_, _, h)
            preview_h = h
            return { kind = "box", dimen = { w = 600, h = h } }
        end,
        previewPlaceholder = function(_, h, text)
            preview_h = h
            status_text = text
            return { kind = "placeholder", text = text, dimen = { w = 600, h = h } }
        end,
    }
end
package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE = 1, COLOR_BLACK = 2 } end
package.preload["ui/geometry"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ui/widget/textwidget"] = function()
    return { new = function(_, opts)
        opts.getSize = function() return { w = 80, h = 12 } end
        opts.paintTo = function() end
        return opts
    end }
end
package.preload["ui/widget/widget"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ui.components.bookui"] = function()
    return {
        sz = function(value) return value end,
        face = function() return {} end,
    }
end
package.preload["lockscreen.settings"] = function()
    return { isCompose = function() return false end }
end
package.preload["lockscreen.compose"] = function()
    return { plan = function() return { output_path = "/tmp/missing.png" } end }
end
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function() return nil end }
end
package.preload["ui/widget/imagewidget"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ui.components.icon"] = function()
    return {
        widget = function(opts) return { icon = opts.name } end,
        label = function(opts) return { icon = opts.name, text = opts.text } end,
    }
end
for _, name in ipairs({
    "ui/widget/horizontalgroup",
    "ui/widget/horizontalspan",
    "ui/widget/container/centercontainer",
    "ui/widget/container/leftcontainer",
    "ui/widget/container/rightcontainer",
    "ui/widget/overlapgroup",
}) do
    package.preload[name] = function()
        return { new = function(_, opts) return opts end }
    end
end
package.preload["ui.panel.desktop"] = function()
    return {
        options = function()
            return {
                { id = "night", icon = "dark_mode", enabled = true, available = true },
                { id = "suspend", icon = "mode_standby", enabled = false, available = true },
            }
        end,
    }
end
package.preload["ui.panel.reader"] = function()
    return { options = function() return {} end }
end
package.preload["ui/widget/buttondialog"] = function() return {} end
local shown, closed = {}, {}
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, widget, refresh) shown[#shown + 1] = { widget = widget, refresh = refresh } end,
        close = function(_, widget, refresh) closed[#closed + 1] = { widget = widget, refresh = refresh } end,
    }
end
package.preload["ui.components.bookinfo"] = function()
    return { tappable = function(w, h, on_tap)
        return { kind = "tap", dimen = { w = w, h = h }, tap = on_tap }
    end }
end
package.preload["device"] = function()
    return {
        screen = { getWidth = function() return 600 end, getHeight = function() return 800 end },
        hasKeys = function() return true end,
        input = { group = { Back = { "Back" } } },
    }
end
package.preload["ui/widget/container/framecontainer"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["l10n"] = function() return { apply = function() end } end

local lock_running = false
package.preload["lockscreen.init"] = function()
    return { running = function() return lock_running end }
end
package.preload["lockscreen.background"] = function() return {} end
package.preload["lockscreen.components.base"] = function() return {} end
package.preload["lockscreen.layout"] = function() return {} end
package.preload["lockscreen.components.bill"] = function() return {} end
package.preload["utils.text"] = function() return {} end
package.preload["ui/widget/infomessage"] = function() return {} end
package.preload["ui/widget/inputdialog"] = function() return {} end
package.preload["ui/network/manager"] = function() return {} end
package.preload["ui.views.popup"] = function() return {} end

local Topbar = require("ui.desktop.settings.topbar")
local top = Topbar.preview(600)
Assert.eq(top.kind, "box")
Assert.eq(preview_h, 40)

local Lockscreen = require("ui.desktop.settings.lockscreen")
local off = Lockscreen.preview(600)
Assert.eq(off.kind, "placeholder")
Assert.eq(status_text, "关")
Assert.eq(preview_h, 144)

package.loaded["lockscreen.settings"] = nil
package.preload["lockscreen.settings"] = function()
    return { isCompose = function() return true end }
end
package.loaded["ui.desktop.settings.lockscreen"] = nil
local LockscreenOn = require("ui.desktop.settings.lockscreen")
local missing = LockscreenOn.preview(600)
Assert.eq(missing.kind, "placeholder")
Assert.eq(status_text, "未生成")
Assert.eq(preview_h, 144)

lock_running = true
Assert.eq(LockscreenOn.preview(600).kind, "placeholder")
Assert.eq(status_text, "生成中…")
lock_running = false

-- 盘上有图但配置已改（lock_screen_day 被清空）：旧图不能当预览。
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function() return { mode = "file", size = 1024 } end,
}
Assert.eq(LockscreenOn.preview(600).kind, "placeholder")
Assert.eq(status_text, "未生成")

-- 当前配置已生成：出缩略图，且不走 ImageCache（compose.png 原地覆写）。
home.lock_screen_day = "2026-09-25:bing"
local captured
package.loaded["ui/widget/imagewidget"] = {
    new = function(_, opts) captured = opts; return opts end,
}
local thumb = LockscreenOn.preview(600)
Assert.eq(thumb.kind, "tap")
Assert.eq(thumb.dimen.h, 144)
Assert.eq(thumb[1].kind, "box")
Assert.eq(captured.file, "/tmp/missing.png")
Assert.eq(captured.file_do_cache, false)

-- 点缩略图：全屏显示同一张图；再点（或返回键）关闭。
thumb.tap()
Assert.len(shown, 1)
local viewer = shown[1].widget
Assert.eq(shown[1].refresh, "full")
Assert.is_true(viewer.covers_fullscreen)
Assert.eq(viewer.dimen.w, 600)
Assert.eq(viewer.dimen.h, 800)
Assert.eq(captured.file, "/tmp/missing.png")
Assert.eq(captured.width, 600)
Assert.eq(captured.height, 800)
Assert.eq(captured.scale_factor, 0)
Assert.is_true(viewer.key_events.Close ~= nil)
Assert.is_true(viewer.tap())
Assert.len(closed, 1)
Assert.eq(closed[1].widget, viewer)
Assert.is_true(viewer.onClose())
Assert.eq(closed[2].widget, viewer)
home.lock_screen_day = nil

local QuickPanel = require("ui.panel.settings")
local strip = QuickPanel.preview("desktop", 600)
Assert.eq(strip.kind, "box")
Assert.eq(preview_h, 48)

local empty = QuickPanel.preview("reader", 600)
Assert.eq(empty.kind, "placeholder")
Assert.eq(status_text, "无")
Assert.eq(preview_h, 48)

return true
