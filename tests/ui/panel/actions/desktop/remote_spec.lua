--[[-- ui.panel.actions.desktop.remote 离线用例。 --]]

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
local started, stopped = 0, 0
local start_err = nil
package.preload["remote.init"] = function()
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
    }
end

local shown = {}
package.preload["ui/uimanager"] = function()
    return { show = function(_, widget) shown[#shown + 1] = widget.text end }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, opts) return opts end }
end

local Action = require("ui.panel.actions.desktop.remote")
Assert.eq(Action.id, "remote")
Assert.eq(Action.title, "远程管理")
Assert.eq(Action.scope, "desktop")
Assert.is_true(Action.keep_open)

-- 未运行：启动并显示地址。
Assert.is_false(Action.active())
Action.run({})
Assert.eq(started, 1)
Assert.is_true(Action.active())
Assert.eq(shown[1], "服务已启动：http://192.168.1.2:9528")

-- 运行中：关闭。
Action.run({})
Assert.eq(stopped, 1)
Assert.is_false(Action.active())
Assert.eq(shown[2], "远程管理已关闭")

-- 启动失败：透出失败原因，不改变运行态。
start_err = "port in use"
Action.run({})
Assert.is_false(Action.active())
Assert.eq(shown[3], "启动失败：port in use")
