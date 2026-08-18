--[[-- ui.reader：上下边缘接管与控制台生命周期。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

local active = false
local shown = {}
local dirty = 0

package.preload["ui.reader.session"] = function()
    return { isActive = function() return active end }
end
package.preload["ui.reader.bars"] = function()
    return { startClock = function() end }
end
package.preload["lockscreen.init"] = function()
    return { refreshInBackground = function() end }
end
package.preload["ui.reader.panel"] = function()
    return {
        new = function(_, opts)
            return { close_callback = opts.close_callback }
        end,
    }
end

local UIManager = require("ui/uimanager")
UIManager.show = function(_, widget)
    shown[#shown + 1] = widget
end
UIManager.close = function(_, widget)
    if widget.close_callback then
        widget.close_callback()
    end
end
UIManager.setDirty = function()
    dirty = dirty + 1
end

local Reader = require("ui.reader")
local zones
local view_modules = {}
local plugin = {
    ui = {
        dialog = {},
        registerTouchZones = function(_, registered) zones = registered end,
        view = {
            registerViewModule = function(_, name, module) view_modules[name] = module end,
        },
    },
}

Reader.attach(plugin)
Assert.eq(#zones, 2)
Assert.eq(zones[1].id, "book_reader_top_tap")
Assert.eq(zones[1].screen_zone.ratio_y, 0)
Assert.eq(zones[2].id, "book_reader_bottom_tap")
Assert.eq(zones[2].screen_zone.ratio_y, 0.85)
Assert.is_nil(plugin.ui._zones, "不应注册正文中间点按区")
Assert.is_true(view_modules.book_bars ~= nil)

Assert.is_false(zones[1].handler(), "非 Book 会话放行原生手势")
Assert.eq(#shown, 0)

active = true
Assert.is_true(zones[1].handler())
Assert.is_true(Reader.isToolbarOpen())
Assert.eq(#shown, 1)

Assert.is_true(zones[2].handler())
Assert.eq(#shown, 1, "已打开时不重复创建控制台")

Reader.closeToolbar()
Assert.is_false(Reader.isToolbarOpen())
Assert.is_true(dirty > 0)

