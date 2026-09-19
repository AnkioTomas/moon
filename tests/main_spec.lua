--[[--
插件入口：Host、源事件分发、阅读会话转发、脏同步重试、桌面生命周期。

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
    close = function() end,
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
    warn = function() end,
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
            onResume = function() desk_life[#desk_life + 1] = "Resume" end,
        }
    end,
})
stub("utils.paths", { ensureLayout = function() end })
stub("host", {
    onCreate = function() calls.host = (calls.host or 0) + 1 end,
    onShow = function() calls.host_show = (calls.host_show or 0) + 1 end,
})
stub("book.open", {
    book = function(_, book) calls.open_book = book end,
})
stub("book.reader_prefs", {
    inject = function() calls.prefs_inject = (calls.prefs_inject or 0) + 1 end,
})
stub("ui.reader.session", {
    onReaderReady = function() calls.session = (calls.session or {}) ; calls.session.ready = true end,
    onCloseDocument = function() calls.session = calls.session or {} ; calls.session.close = true end,
    onPageChanged = function(_, page) calls.session = calls.session or {} ; calls.session.page = page end,
    onAnnotationsModified = function() calls.session = calls.session or {} ; calls.session.notes = true end,
    onPause = function() calls.session = calls.session or {} ; calls.session.suspend = true end,
    onResume = function() calls.session = calls.session or {} ; calls.session.resume = true end,
    onChapterBoundary = function(delta)
        calls.session = calls.session or {}
        calls.session.boundary = delta
        return true
    end,
})
stub("book.sync", {
    retryDirtyAsync = function() calls.retry_dirty = (calls.retry_dirty or 0) + 1 end,
})

local function noop_mod(extra)
    local mod = {
        onCreate = function() calls.boot = (calls.boot or 0) + 1 end,
        onPause = function() calls.feat_suspend = (calls.feat_suspend or 0) + 1 end,
        onResume = function() calls.feat_resume = (calls.feat_resume or 0) + 1 end,
        onDestroy = function() calls.feat_exit = (calls.feat_exit or 0) + 1 end,
        refresh = function() calls.lock_refresh = (calls.lock_refresh or 0) + 1 end,
        autoCheck = function() calls.update_check = (calls.update_check or 0) + 1 end,
        checkStartup = function() calls.animation_check = (calls.animation_check or 0) + 1 end,
    }
    for k, v in pairs(extra or {}) do mod[k] = v end
    return mod
end
stub("translate.init", noop_mod())
stub("baike.init", noop_mod())
stub("dictionary.init", noop_mod())
stub("ui.panel.native", noop_mod())
stub("lockscreen.init", noop_mod({
    onPause = function() calls.lock_refresh = (calls.lock_refresh or 0) + 1 end,
}))
stub("remote.init", noop_mod())
stub("ime.init", noop_mod())
stub("patch.manager", noop_mod({
    onCreate = function()
        calls.boot = (calls.boot or 0) + 1
        require("ui/uimanager"):nextTick(function()
            require("patch.page_turn_animation").checkStartup()
        end)
    end,
}))
stub("patch.page_turn_animation", noop_mod())
stub("update.init", noop_mod())

_G.G_reader_settings = {
    isTrue = function() return true end,
    saveSetting = function() end,
    readSetting = function(_, _, default) return default end,
}

package.loaded["main"] = nil
local Main = require("main")
local plugin = setmetatable({ path = "book.koplugin", ui = {} }, Main)
plugin:init()
Assert.eq(calls.host, 1)
Assert.is_true((calls.boot or 0) >= 8, "init 应挂上翻译/百科/词典/面板/锁屏/远程/IME/补丁等")
Assert.eq(calls.animation_check, 1)

-- emitToSource：缺省用当前源；指定源优先；抛错不打断
do
    local events = {}
    current_source = {
        id = "moon",
        onEvent = function(_, event, payload)
            events[#events + 1] = { event, payload and payload.id }
        end,
    }
    plugin:emitToSource("fm_open")
    Assert.eq(events[1][1], "fm_open")

    local other = {
        id = "wechat",
        onEvent = function(_, event)
            events[#events + 1] = { event, "other" }
        end,
    }
    plugin:emitToSource("page_changed", { id = 1 }, other)
    Assert.eq(events[2][1], "page_changed")
    Assert.eq(events[2][2], "other")

    current_source = {
        id = "bad",
        onEvent = function() error("boom") end,
    }
    plugin:emitToSource("network_connected") -- 不得抛出
end

-- 网络恢复：脏重试 + 源事件 + 锁屏刷新；更新检查不在这里（桌面 onResume）
do
    local seen = {}
    current_source = {
        id = "moon",
        onEvent = function(_, event) seen[#seen + 1] = event end,
    }
    calls.retry_dirty = 0
    calls.lock_refresh = 0
    calls.update_check = 0
    local net_desk = {
        lifecycle = { state = "Resume" },
        onNetworkConnected = function() seen[#seen + 1] = "desktop_net" end,
    }
    plugin.desktop = net_desk
    plugin.ui = {} -- FM
    plugin:onNetworkConnected()
    Assert.eq(calls.retry_dirty, 1)
    Assert.eq(calls.lock_refresh, 1)
    Assert.eq(calls.update_check, 0, "自动更新检查只在 Desktop:onResume")
    Assert.eq(table.concat(seen, ","), "network_connected,desktop_net")
end

-- 阅读生命周期一行转发
do
    calls.session = nil
    plugin:onReaderReady()
    Assert.is_true(calls.session.ready)
    plugin:onPageUpdate(3)
    Assert.eq(calls.session.page, 3)
    plugin:onPosUpdate(nil, 4)
    Assert.eq(calls.session.page, 4)
    Assert.is_true(plugin:onEndOfBook())
    Assert.eq(calls.session.boundary, 1)
end

local resumed_desktop = {
    lifecycle = { state = "Resume" },
    tab = "library",
    onPause = function()
        calls.desktop_pause = (calls.desktop_pause or 0) + 1
    end,
    onResume = function(self)
        if self.tab == "home" then
            calls.home_enter = self
        else
            calls.library_resume = self
        end
    end,
    onDestroy = function(self)
        calls.desktop_destroy = (calls.desktop_destroy or 0) + 1
        self.lifecycle.state = "Destroy"
    end,
    onEvent = function(_, event, payload)
        calls.desktop_event = event
        calls.desktop_event_payload = payload
    end,
    onNetworkConnected = function() end,
}
plugin.desktop = resumed_desktop
calls.session = nil
plugin:onResume()
Assert.is_true(calls.session.resume)
Assert.is_nil(calls.library_resume, "唤醒不经插件再转 Desktop:onResume")

current_source = {
    id = "local",
    onEvent = function(_, event)
        calls.source_open = event
    end,
}
plugin.desktop = nil
desk_life = {}
plugin:openDesktop()
Assert.eq(table.concat(desk_life, ","), "Resume")
Assert.eq(calls.source_open, "desktop_open")
plugin.desktop = resumed_desktop

plugin:onSourceChanged()
Assert.eq(calls.desktop_event, "source_changed")
Assert.eq(calls.desktop_event_payload.id, "local")

calls.session = nil
calls.feat_suspend = 0
calls.lock_refresh = 0
plugin:onSuspend()
Assert.is_true(calls.session.suspend)
Assert.eq(calls.desktop_pause, 1)
Assert.is_true(calls.feat_suspend >= 1, "休眠应通知远程")
Assert.eq(calls.lock_refresh, 1)

calls.session = nil
calls.feat_resume = 0
plugin:onResume()
Assert.is_true(calls.session.resume)
Assert.is_true(calls.feat_resume >= 2, "唤醒应通知锁屏/远程")

calls.feat_exit = 0
plugin:onExit()
Assert.eq(calls.desktop_destroy, 1)
Assert.eq(resumed_desktop.lifecycle.state, "Destroy")
Assert.is_true(calls.feat_exit >= 2, "退出应停更新/远程")

calls.desktop_event = nil
plugin:onSourceChanged()
Assert.is_nil(calls.desktop_event, "已销毁的桌面不再收 onEvent")

version_current = 202606000000
local attach_count = calls.host
package.loaded["ko_version"] = nil
setmetatable({ path = "book.koplugin", ui = {} }, Main):init()
Assert.eq(calls.host, attach_count, "不支持的 KOReader 版本不得进入插件")
Assert.eq(calls.version_dialog.text, "月读需要 KOReader 2026.07 或更高版本。\n\n当前版本：2026.06 (202606000000)")
