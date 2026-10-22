--[[-- 电源快捷动作：菜单项随设备能力出现，退出月读不退出 KOReader。 --]]
---@diagnostic disable: undefined-field, missing-fields

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(value) return value end end

local caps = { restart = true, suspend = true, reboot = true }
package.preload["device"] = function()
    return {
        canRestart = function() return caps.restart end,
        canSuspend = function() return caps.suspend end,
        canReboot = function() return caps.reboot end,
    }
end

local events, suspended, reboots, ticks = {}, 0, 0, {}
package.preload["ui/uimanager"] = function()
    return {
        broadcastEvent = function(_self, ev) events[#events + 1] = ev.name end,
        suspend = function() suspended = suspended + 1 end,
        askForReboot = function() reboots = reboots + 1 end,
        nextTick = function(_self, fn) ticks[#ticks + 1] = fn end,
    }
end
package.preload["ui/event"] = function()
    return { new = function(_self, name) return { name = name } end }
end

local shown
package.preload["ui.themes.widgets.sheet"] = function()
    return { new = function(_self, spec) return { show = function() shown = spec end } end }
end

local fm = { instance = nil }
package.preload["apps/filemanager/filemanager"] = function() return fm end

local ensured = 0
package.preload["desktop"] = function()
    return { ensureFileManager = function() ensured = ensured + 1 end }
end

local Action = require("features.panel.actions.desktop.power")

local function item(text)
    for _idx, row in ipairs(shown.items) do
        if row.text == text then return row end
    end
end

local function texts()
    local out = {}
    for _idx, row in ipairs(shown.items) do out[#out + 1] = row.text end
    return table.concat(out, ",")
end

Assert.eq(Action.id, "power")
Assert.eq(Action.scope, "desktop")
Assert.eq(Action.icon, "power")

local closed, doc_closed = 0, 0
local ctx = {
    ui = {
        book = { desktop = { onClose = function() closed = closed + 1 end } },
        onClose = function() doc_closed = doc_closed + 1 end,
    },
}
Action.run(ctx)
Assert.eq(shown.title, "电源")
Assert.eq(texts(), "退出月读,退出 KOReader,重启 KOReader,休眠,重启设备")

item("退出月读").callback()
Assert.eq(#ticks, 1)
ticks[1]()
Assert.eq(closed, 1)
Assert.eq(doc_closed, 0, "桌面还开着时只关桌面")
Assert.eq(ensured, 0)

ctx.ui.book.desktop.closed = true
ctx.ui.document = {}
item("退出月读").callback()
ticks[2]()
Assert.eq(ensured, 1, "阅读中退出月读先保住文件管理器")
Assert.eq(doc_closed, 1)
Assert.eq(closed, 1)

local desk_closed = 0
fm.instance = { book = { desktop = { onClose = function() desk_closed = desk_closed + 1 end } } }
item("退出 KOReader").callback()
Assert.eq(desk_closed, 1, "桌面留在栈上时 Exit 退不出 KOReader")
Assert.eq(events[1], "Exit")

item("重启 KOReader").callback()
Assert.eq(events[2], "Restart")
item("休眠").callback()
Assert.eq(suspended, 1)
item("重启设备").callback()
Assert.eq(reboots, 1)

caps.restart, caps.suspend, caps.reboot = false, false, false
Action.run(ctx)
Assert.eq(texts(), "退出月读,退出 KOReader")
