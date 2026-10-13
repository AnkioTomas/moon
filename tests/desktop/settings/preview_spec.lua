--[[-- 设置预览：示意条 / 空态走同一条框。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["ffi/util"] = function()
    return { template = function(text, value) return text:gsub("%%1", tostring(value)) end }
end

local home = { home_topbar_items = { memory = false } }
local lockscreen = {}
package.preload["utils.settings"] = function()
    return {
        get = function(name)
            if name == "features.lockscreen" then return lockscreen end
            return home
        end,
        save = function() end,
    }
end
package.preload["ui.themes.widgets.row"] = function()
    return { widget = function(opts) return opts end }
end

local status_text
local preview_h
package.preload["desktop.pages.setting.overlay"] = function()
    return {
        previewBox = function(_, child, h)
            preview_h = h
            return { kind = "box", dimen = { w = 600, h = h }, child = child }
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
package.preload["ui.themes"] = function()
    return {
        px = function(n) return n end,
        current = function()
            return {
                color = { page = 255, ink = 0, muted = 1 },
                space = { sm = 8, md = 12, lg = 16 },
                row = { height = 48 },
                progress = { height = 4 },
                font = { caption = 11 },
            }
        end,
        face = function() return {} end,
    }
end
package.preload["features.lockscreen.settings"] = function()
    return { isCompose = function() return false end }
end
package.preload["features.lockscreen.compose"] = function()
    return { plan = function() return { output_path = "/tmp/missing.png" } end }
end
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function() return nil end }
end
package.preload["ui/widget/imagewidget"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ui.themes.widgets.icon"] = function()
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
package.preload["features.panel.desktop"] = function()
    return {
        options = function()
            return {
                { id = "night", icon = "dark_mode", enabled = true, available = true },
                { id = "suspend", icon = "mode_standby", enabled = false, available = true },
            }
        end,
    }
end
package.preload["features.panel.reader"] = function()
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
package.preload["ui.widgets.book"] = function()
    return { tappable = function(w, h, on_tap)
        return { kind = "tap", dimen = { w = w, h = h }, tap = on_tap }
    end }
end
package.preload["device"] = function()
    return {
        screen = {
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
            getSize = function() return { w = 600, h = 800 } end,
        },
        hasKeys = function() return true end,
        input = { group = { Back = { "Back" } } },
    }
end
package.preload["ui.themes.widgets.box"] = function()
    return { new = function(_, opts) opts.kind = "theme_box"; return opts end }
end
require("support.modal_stub").install()
package.preload["l10n"] = function() return { apply = function() end } end

local lock_running = false
package.preload["features.lockscreen"] = function()
    return { running = function() return lock_running end }
end
package.preload["features.lockscreen.background"] = function() return {} end
package.preload["features.lockscreen.components.base"] = function() return {} end
package.preload["features.lockscreen.layout"] = function()
    return { portraitSize = function() return 600, 800 end }
end
package.preload["features.lockscreen.components.bill"] = function() return {} end
package.preload["utils.text"] = function() return {} end
package.preload["ui/widget/infomessage"] = function() return {} end
package.preload["ui/widget/inputdialog"] = function() return {} end
package.preload["ui/network/manager"] = function() return {} end
require("support.theme_stubs").install()

package.preload["desktop.topbar"] = function()
    return {
        height = function() return 40 end,
        visible = function(id)
            local items = home.home_topbar_items
            return type(items) ~= "table" or items[id] ~= false
        end,
        metric = function(text, icon) return { sample = text, icon = icon } end,
        row = function(_, _, left, right) return { kind = "row", left = left, right = right } end,
        items = function()
            return {
                { id = "clock", align = "left", sample = "12:34" },
                { id = "source", align = "left", sample = "本地", bar_icon = "source" },
                { id = "memory", sample = "128M", bar_icon = "memory" },
                { id = "cache", sample = "1/3", bar_icon = "download" },
                { id = "storage", sample = "2.1G", bar_icon = "hard_drive" },
                { id = "wifi", bar_icon = "wifi" },
                { id = "brightness", sample = "40%", bar_icon = "brightness_6" },
                { id = "battery", sample = "85%", bar_icon = "battery_android_full" },
            }
        end,
    }
end
local Topbar = require("desktop.pages.setting.topbar")
local top = Topbar.preview(600)
Assert.eq(top.kind, "box")
Assert.eq(preview_h, 40)
Assert.eq(top.child.kind, "row")
Assert.eq(top.child.left[1].sample, "12:34")
Assert.is_nil(top.child.left[1].icon, "时钟不画图标")
Assert.eq(#top.child.right, 5, "内存已关")

local Lockscreen = require("features.lockscreen.page")
local off = Lockscreen.preview(600)
Assert.eq(off.kind, "placeholder")
Assert.eq(status_text, "关")
Assert.eq(preview_h, 144)

package.loaded["features.lockscreen.settings"] = nil
package.preload["features.lockscreen.settings"] = function()
    return { isCompose = function() return true end }
end
package.loaded["features.lockscreen.page"] = nil
local LockscreenOn = require("features.lockscreen.page")
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
    attributes = function(_, name)
        local attr = { mode = "file", size = 1024 }
        return name and attr[name] or attr
    end,
}
package.loaded["features.lockscreen.page"] = nil
LockscreenOn = require("features.lockscreen.page")
Assert.eq(LockscreenOn.preview(600).kind, "placeholder")
Assert.eq(status_text, "未生成")

-- 当前配置已生成：出缩略图，且不走 ImageCache（compose.png 原地覆写）。
lockscreen.lock_screen_day = "2026-09-25:bing"
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
-- 控件只有图片大小（不拿整框），夜间模式整框反色才不会把两侧留白变白。
Assert.is_nil(captured.width)
Assert.is_nil(captured.height)
Assert.eq(captured.scale_factor, 142 / 800)

-- 点缩略图：全屏 Modal 显示同一张图；点任意处（或返回键）关闭，关后整屏刷新。
thumb.tap()
Assert.len(shown, 1)
local viewer = shown[1].widget
Assert.is_true(viewer.covers_fullscreen)
Assert.is_true(viewer.close_on_tap)
Assert.is_false(viewer.mask)
Assert.eq(viewer[1].kind, "theme_box")
Assert.eq(viewer.dimen.w, 600)
Assert.eq(viewer.dimen.h, 800)
Assert.eq(captured.file, "/tmp/missing.png")
Assert.is_nil(captured.width)
Assert.is_nil(captured.height)
Assert.eq(captured.scale_factor, 1)
Assert.eq(captured.file_do_cache, false)
Assert.is_true(viewer:onClose())
Assert.len(closed, 1)
Assert.eq(closed[1].widget, viewer)
Assert.not_nil(viewer.close_callback)
home.lock_screen_day = nil

local QuickPanel = require("features.panel.settings")
local strip = QuickPanel.preview("desktop", 600)
Assert.eq(strip.kind, "box")
Assert.eq(preview_h, 48)

local empty = QuickPanel.preview("reader", 600)
Assert.eq(empty.kind, "placeholder")
Assert.eq(status_text, "无")
Assert.eq(preview_h, 48)

return true
