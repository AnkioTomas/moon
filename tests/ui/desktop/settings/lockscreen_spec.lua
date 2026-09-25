--[[-- 锁屏设置：改配置先让出重绘再合成，完成后刷新预览叠层。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["l10n"] = function() return { apply = function() end } end
package.preload["ffi/util"] = function()
    return { template = function(text, value) return (text:gsub("%%1", tostring(value))) end }
end

local log = {}
local ticks = {}
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, widget) log[#log + 1] = "show:" .. widget.text end,
        tickAfterNext = function(_, fn) ticks[#ticks + 1] = fn end,
    }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ui/widget/inputdialog"] = function() return {} end
package.preload["ui/network/manager"] = function() return {} end

local popup
package.preload["ui.views.popup"] = function()
    return { list = function(opts) popup = opts end }
end
package.preload["ui.components.settingrow"] = function()
    return { build = function(_, opts) return opts end }
end

local refresh_cb
local running = false
package.preload["lockscreen.init"] = function()
    return {
        refresh = function(cb) log[#log + 1] = "refresh"; refresh_cb = cb; running = true end,
        running = function() return running end,
    }
end
package.preload["lockscreen.settings"] = function()
    return {
        isCompose = function() return true end,
        setBackgroundMode = function(value) log[#log + 1] = "set:" .. value end,
    }
end
package.preload["lockscreen.compose"] = function()
    return { plan = function()
        return {
            component = { id = "current" }, background_mode = "bing",
            position = "center-center", wide = true, offline = true,
        }
    end }
end
package.preload["lockscreen.background"] = function()
    return {
        label = function(v) return v end,
        hint = function() return nil end,
        options = function() return {} end,
    }
end
package.preload["lockscreen.components.base"] = function()
    return { options = function() return {} end }
end
package.preload["lockscreen.layout"] = function()
    return { label = function(v) return v end, options = function() return {} end }
end
package.preload["lockscreen.components.bill"] = function() return {} end
package.preload["utils.text"] = function() return {} end

local Lockscreen = require("ui.desktop.settings.lockscreen")

local overlay_updates = 0
local desktop = {
    updateView = function() log[#log + 1] = "desktop.updateView" end,
    settings_overlay = { updateView = function() overlay_updates = overlay_updates + 1 end },
}

local rows = Lockscreen:rows(desktop)
rows[2]({}).callback()
Assert.is_true(popup ~= nil)
popup.on_select("folder")

-- 点击回调内只改配置、刷视图、弹提示；合成推到下一帧重绘之后。
Assert.eq(table.concat(log, ","), "set:folder,desktop.updateView,show:正在生成锁屏图…")
Assert.len(ticks, 1)

ticks[1]()
Assert.eq(log[#log], "refresh")
Assert.eq(overlay_updates, 1, "在飞时预览切到「生成中」")

running = false
refresh_cb(true)
Assert.eq(overlay_updates, 2, "完成后刷新预览")
Assert.eq(log[#log], "show:锁屏图已更新")

-- 叠层已关闭：完成回调不再碰叠层。
desktop.settings_overlay = nil
refresh_cb(false, "boom")
Assert.eq(log[#log], "show:生成失败: boom")

return true
