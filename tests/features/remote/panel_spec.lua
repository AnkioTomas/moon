--[[-- features.remote.panel：桌面快捷面板开关。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function()
    return function(value) return value end
end
package.preload["ffi/util"] = function()
    return {
        template = function(str, ...)
            local args = { ... }
            return (str:gsub("%%1", tostring(args[1])))
        end,
    }
end

local running = false
local started, stopped, access_shown = 0, 0, 0
local start_err = nil
local connected = true
local wifi_starts = 0
local wifi_callback
package.preload["ui/network/manager"] = function()
    return {
        isConnected = function() return connected end,
        toggleWifiOn = function(_self, cb, long_press, interactive)
            Assert.is_nil(long_press)
            Assert.is_true(interactive)
            wifi_starts = wifi_starts + 1
            wifi_callback = cb
        end,
    }
end
package.preload["features.remote"] = function()
    return {
        isRunning = function() return running end,
        start = function()
            if start_err then return false, start_err end
            started = started + 1
            running = true
            return true
        end,
        stop = function()
            stopped = stopped + 1
            running = false
        end,
        status = function()
            return running and "http://192.168.1.2:9528" or "未运行"
        end,
        showAccess = function()
            access_shown = access_shown + 1
            return true
        end,
    }
end

local shown = {}
package.preload["ui/uimanager"] = function()
    return { show = function(_, widget) shown[#shown + 1] = widget.text end }
end
local Themed = require("support.theme_stubs")
Themed.install()
Themed.on_show = function(o) require("ui/uimanager"):show(o) end

package.preload["l10n"] = function() return { apply = function() end } end

local Action = require("features.remote.panel").actions()[1]
Assert.eq(Action.id, "remote")
Assert.eq(Action.title, "远程管理")
Assert.eq(Action.scope, "desktop")
Assert.is_true(Action.keep_open)

-- 未运行：启动并弹二维码（含底部明文 URL），不再只闪一句 toast。
Assert.is_false(Action.active())
Action.run({})
Assert.eq(started, 1)
Assert.is_true(Action.active())
Assert.eq(access_shown, 1)
Assert.len(shown, 0)

-- 运行中：关闭。
Action.run({})
Assert.eq(stopped, 1)
Assert.is_false(Action.active())
Assert.eq(shown[1], "远程管理已关闭")

-- 启动失败：透出失败原因，不改变运行态。
start_err = "port in use"
Action.run({})
Assert.is_false(Action.active())
Assert.eq(shown[2], "启动失败：port in use")
Assert.eq(wifi_starts, 0, "局域网已连时不重开 Wi-Fi、不检测外网")

-- 离线：先开 Wi-Fi，连接回调之前不能声称服务已启动。
start_err = nil
connected = false
Action.run({})
Assert.eq(wifi_starts, 1)
Assert.eq(started, 1)
Assert.is_false(Action.active())
Assert.len(shown, 2, "未连上或取消选网时不弹成功")
Assert.eq(access_shown, 1, "未连上或取消选网时不弹二维码")
connected = true
wifi_callback()
Assert.eq(started, 2)
Assert.is_true(Action.active())
Assert.eq(access_shown, 2)

-- 关闭服务不顺带关闭或重开 Wi-Fi。
Action.run({})
Assert.eq(stopped, 2)
Assert.eq(wifi_starts, 1)

-- 设置页采用相同的主动联网行为，而不是受全局联网策略控制。
local redraws = 0
package.loaded["ui.themes.widgets.row"] = { widget = function(opts) return opts end }
local Remote = require("features.remote")
Remote.port = function() return 9528 end
Remote.autostartOn = function() return false end
Remote.idleStopOn = function() return true end
Remote.deleteAfterShareOn = function() return false end
local desktop = {
    updateView = function() redraws = redraws + 1 end,
}
---@cast desktop BookDesktop
local page = require("features.remote.setting").entries(desktop)[1].page
local service_row = page.sections()[1].rows[1]
connected = false
service_row(600).callback()
Assert.eq(wifi_starts, 2)
Assert.is_false(running)
Assert.eq(started, 2)
connected = true
wifi_callback()
Assert.is_true(running)
Assert.eq(started, 3)
Assert.eq(access_shown, 3, "设置页启动成功同样弹二维码")
Assert.eq(redraws, 2)
service_row(600).callback()
Assert.is_false(running)
Assert.eq(wifi_starts, 2)
service_row(600).callback()
Assert.is_true(running, "设置页已联网直接启动")
Assert.eq(access_shown, 4)
Assert.eq(wifi_starts, 2)
