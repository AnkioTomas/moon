--[[--
Kavita 设置页：测试连接 / 书库两个入口在「Kavita 不是当前活跃源、源实例尚未创建」时
也要能正常建客户端。

回归：`Client.new(cfg)` 少写冒号 → `self` 被当成配置表，返回的对象只有一层指向
配置表的 metatable，`testVersionAsync` / `listLibrariesAsync` 全为 nil，点击即
`attempt to call method 'testVersionAsync' (a nil value)` 崩溃。活跃源是 kavita 时
`Kavita.new()` 已经 `Client:new(cfg)` 给配置表挂了 Client metatable，所以崩不出来。
--]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["ffi/util"] = function()
    return { template = function(fmt, a) return (tostring(fmt):gsub("%%1", tostring(a))) end }
end
package.preload["ui/uimanager"] = function()
    return {
        show = function() end,
        close = function() end,
        nextTick = function(_, fn) if fn then fn() end end,
        scheduleIn = function() end,
        unschedule = function() end,
    }
end
package.preload["ui/widget/infomessage"] = function() return { new = function(_, o) return o end } end
package.preload["ui/widget/textviewer"] = function() return { new = function(_, o) return o end } end
package.preload["ui/widget/inputdialog"] = function()
    return { new = function(_, o) o.onShowKeyboard = function() end; o.getInputText = function() return "" end; return o end }
end
package.preload["ui.views.popup"] = function() return { list = function() end, sheet = function() end } end
package.preload["ui.components.settingrow"] = function()
    return { build = function(_, o) return o end }
end

-- 配置用一张普通表模拟：不带 Client metatable（源未创建）。
local cfg = { base_url = "https://kavita.test/kavita", api_key = "secret" }
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end, saveSource = function() end }
end

-- 捕获发往 Kavita 的请求；不回调，避免走到后续 UI。
local requests = 0
package.preload["http.request"] = function()
    return {
        request = function()
            requests = requests + 1
            return { cancel = function() end }
        end,
    }
end

local Setting = require("source.kavita.setting")
local rows = Setting.rows(nil)
Assert.eq(#rows, 5)

-- 测试连接：配置表不带 Client metatable 也不能崩。
rows[4](600).callback()
Assert.eq(requests, 1)
Assert.is_nil(rawget(cfg, "__index"), "客户端构造不得污染配置表")

-- 书库：同理。
rows[3](600).callback()
Assert.eq(requests, 2)
Assert.is_nil(rawget(cfg, "__index"))

return true
