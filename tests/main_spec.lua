--[[--
插件入口只挂桌面：Host、打开桌面、休眠/唤醒生命周期。

@module tests.main_spec
--]]

local Assert = require("support.assert")

local WidgetContainer = {}
function WidgetContainer:extend(def)
    def.__index = def
    return setmetatable(def, { __index = self })
end

local calls = {}
local version_current = 202607000000
local function stub(name, value)
    package.preload[name] = function() return value end
end

stub("ui/widget/container/widgetcontainer", WidgetContainer)
stub("ui/uimanager", {
    nextTick = function(_, fn) fn() end,
    show = function(_, widget)
        calls.version_dialog = widget
    end,
    setDirty = function() end,
})
stub("ui/widget/infomessage", {})
stub("ui/widget/confirmbox", {
    new = function(_, fields) calls.version_dialog = fields return fields end,
})
stub("version", {
    getNormalizedCurrentVersion = function() return version_current end,
    getShortVersion = function() return version_current >= 202607000000 and "2026.07" or "2026.06" end,
})
stub("utils.log", {
    start = function() end,
    info = function() end,
    dbg = function() end,
    error = function() end,
    flush = function() end,
})
stub("l10n", {})
stub("gettext", setmetatable({}, { __call = function(_, text) return text end }))
local current_source
stub("source.registry", {
    current = function() return current_source end,
})
local desk_life = {}
stub("ui.desktop", {
    new = function()
        return {
            lifecycle = { state = "new" },
            onStart = function() desk_life[#desk_life + 1] = "Start" end,
            onResume = function() desk_life[#desk_life + 1] = "Resume" end,
        }
    end,
})
stub("utils.paths", { ensureLayout = function() end })
stub("host", {
    attach = function() calls.host = (calls.host or 0) + 1 end,
    onShow = function() calls.host_show = (calls.host_show or 0) + 1 end,
})

local Main = require("main")
local plugin = setmetatable({ path = "book.koplugin" }, Main)
plugin:init()
Assert.eq(calls.host, 1)

local resumed_desktop = {
    lifecycle = { state = "Resume" },
    tab = "library",
    onPause = function()
        calls.desktop_pause = (calls.desktop_pause or 0) + 1
    end,
    onStart = function()
        calls.desktop_start = (calls.desktop_start or 0) + 1
    end,
    onResume = function(self)
        if self.tab == "home" then
            calls.home_enter = self
        else
            calls.library_resume = self
        end
    end,
    onStop = function()
        calls.desktop_stop = (calls.desktop_stop or 0) + 1
    end,
    onDestroy = function(self)
        calls.desktop_destroy = (calls.desktop_destroy or 0) + 1
        self.lifecycle.state = "Destroy"
    end,
    onEvent = function(_, event, payload)
        calls.desktop_event = event
        calls.desktop_event_payload = payload
    end,
}
plugin.desktop = resumed_desktop
plugin:onResume()
Assert.is_nil(calls.library_resume, "唤醒不经插件再转 Desktop:onResume")

resumed_desktop.tab = "home"
plugin:onResume()
Assert.is_nil(calls.home_enter, "唤醒不经插件再转 Desktop:onResume")

current_source = { id = "local" }
plugin.desktop = nil
plugin:openDesktop()
Assert.eq(table.concat(desk_life, ","), "Start,Resume")
plugin.desktop = resumed_desktop

plugin:onSourceChanged()
Assert.eq(calls.desktop_event, "source_changed")
Assert.eq(calls.desktop_event_payload, current_source)

plugin:onSuspend()
Assert.eq(calls.desktop_pause, 1)
Assert.eq(calls.desktop_stop, 1, "Pause 之后仍要能进 onStop，不能用 Alive() 当门槛")

plugin:onExit()
Assert.eq(calls.desktop_destroy, 1)
Assert.eq(resumed_desktop.lifecycle.state, "Destroy")

calls.desktop_event = nil
plugin:onSourceChanged()
Assert.is_nil(calls.desktop_event, "已销毁的桌面不再收 onEvent")

version_current = 202606000000
local attach_count = calls.host
setmetatable({ path = "book.koplugin" }, Main):init()
Assert.eq(calls.host, attach_count, "不支持的 KOReader 版本不得进入插件")
Assert.eq(calls.version_dialog.text, "月读需要 KOReader 2026.07 或更高版本。\n\n当前版本：2026.06 (202606000000)")
