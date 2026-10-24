--[[-- features.xray.init：手势登记与事件处理。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(value) return value end end
local actions = {}
package.preload["dispatcher"] = function()
    return { registerAction = function(_, id, def) actions[id] = def end }
end
local refreshed
package.preload["features.xray.ui"] = function()
    return { refresh = function(ui) refreshed = ui end }
end

local session_current
package.preload["reader.session"] = function()
    return { current = function() return session_current end }
end

local Xray = require("features.xray")

Xray.onCreate()
Assert.eq(actions.book_xray_refresh.event, "BookXrayRefresh")
Assert.is_true(actions.book_xray_refresh.reader)

local refresh = Xray.events[actions.book_xray_refresh.event]
Assert.is_false(refresh({ ui = {} }), "桌面侧不处理")
Assert.is_nil(refreshed)

local reader = { ui = { document = {} } }
Assert.is_true(refresh(reader))
Assert.eq(refreshed, reader.ui)

session_current = { identity = { source_id = "subscribe", ephemeral = true } }
Assert.is_false(Xray.available(), "订阅文章不支持 X-Ray")
refreshed = nil
Assert.is_false(refresh(reader))
Assert.is_nil(refreshed)

session_current = { identity = { source_id = "wechat" } }
Assert.is_true(Xray.available())
