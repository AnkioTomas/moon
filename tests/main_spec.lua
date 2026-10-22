--[[--
插件入口：宿主接线（启动项 / 菜单 / 手势）、启用源推脏行、阅读会话转发、桌面生命周期。

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
    scheduleIn = function(_, _delay, fn) fn() end,
    show = function(_, widget)
        calls.version_dialog = widget
    end,
    setDirty = function() end,
    close = function() end,
})
stub("utils.wake", {
    GRACE = 0, boot = function() end, suspend = function() end, resume = function() end, exit = function() end,
    timed = function(_label, fn, ...) return fn(...) end,
})
stub("ui/widget/infomessage", {
    new = function(_, fields) calls.version_dialog = fields return fields end,
})
stub("version", {
    getNormalizedCurrentVersion = function() return version_current end,
    getShortVersion = function() return version_current >= 202607000000 and "2026.07" or "2026.06" end,
})
stub("utils.log", {
    boot = function() end,
    info = function() end,
    dbg = function() end,
    error = function() end,
    warn = function() end,
    flush = function() end,
})
stub("l10n", {})
stub("gettext", setmetatable({}, { __call = function(_, text) return text end }))
local current_source
local source_hooks = {}
--- 源桩：记录 pushDirty 调用。
---@param fields table
---@return table
local function mkSource(fields)
    fields.pushDirty = function(self) source_hooks[#source_hooks + 1] = "pushDirty:" .. self.id end
    fields.configured = function(self) return self.unconfigured ~= true end
    return fields
end
--- 有脏行的源 id；没登记的源不该被建实例。
local dirty = { moon = true, ["local"] = true, wechat = true, jdread = true }
local connected = true
stub("desktop.reader_exit", { install = function() end })
stub("source.base", { hasDirty = function(id) return dirty[id] == true end })
stub("ui/network/manager", { isConnected = function() return connected end })
--- 除当前源外的其他启用源（混合模式）；值为 false 表示已启用但加载失败。
local other_sources = {}
local mixed_mode = false
stub("source.registry", {
    registerHidden = function() end,
    current = function() return current_source end,
    listEnabled = function()
        local out = current_source and { { id = current_source.id } } or {}
        for _idx, id in ipairs(other_sources) do out[#out + 1] = { id = id } end
        return out
    end,
    syncScope = function()
        if mixed_mode then return require("source.registry").listEnabled() end
        return { { id = current_source.id } }
    end,
    resolve = function(id)
        if current_source and current_source.id == id then return current_source end
        return other_sources[id] or nil
    end,
})
stub("desktop", {
    open = function(p)
        calls.desktop_opened = p
    end,
    autoOpen = function(p) calls.auto_open[#calls.auto_open + 1] = p end,
    startInDataDir = function() end,
})
calls.auto_open = {}
stub("utils.paths", { ensureLayout = function() end })
local dispatcher_actions = {}
stub("dispatcher", {
    registerAction = function(_, id) dispatcher_actions[#dispatcher_actions + 1] = id end,
})
stub("ui.fonts", { onCreate = function() calls.attach = (calls.attach or 0) + 1 end })
stub("ui.themes.widgets.icon", { ensure = function() end })
local fm_order = { setting = { "filebrowser", "book_library" } }
stub("ui/elements/filemanager_menu_order", fm_order)
stub("ui/elements/reader_menu_order", { setting = {} })
local FMMenu = {
    getStartWithMenuTable = function()
        return { sub_item_table = {}, text_func = function() return "Start with: file browser" end }
    end,
}
stub("apps/filemanager/filemanagermenu", FMMenu)
stub("ffi/util", { template = function(fmt, a) return (fmt:gsub("%%1", a)) end })
local reader_settings = {}
local moon_cfg = { start_with_seeded = true }
stub("utils.settings", {
    get = function() return moon_cfg end,
    save = function() end,
})
stub("desktop.open", {
    book = function(_, book) calls.open_book = book end,
})
local READING_EVENTS = {
    "onDocSettingsLoad", "onReaderReady", "onPageUpdate", "onPosUpdate",
    "onAnnotationsModified", "onCloseDocument",
}
local session_stub = {
    onSuspend = function() calls.session = calls.session or {} ; calls.session.suspend = true end,
    onResume = function() calls.session = calls.session or {} ; calls.session.resume = true end,
}
local reading = {}
for _, name in ipairs(READING_EVENTS) do
    session_stub[name] = function(host, arg)
        reading[name] = { host, arg }
        return name
    end
end
stub("reader.session", session_stub)
local function noop_mod(extra)
    local mod = {
        onCreate = function() calls.boot = (calls.boot or 0) + 1 end,
        onSuspend = function() calls.feat_suspend = (calls.feat_suspend or 0) + 1 end,
        onResume = function() calls.feat_resume = (calls.feat_resume or 0) + 1 end,
        onExit = function() calls.feat_exit = (calls.feat_exit or 0) + 1 end,
        refresh = function() calls.lock_refresh = (calls.lock_refresh or 0) + 1 end,
        autoCheck = function() calls.update_check = (calls.update_check or 0) + 1 end,
    }
    for k, v in pairs(extra or {}) do mod[k] = v end
    return mod
end
stub("features.baike", noop_mod())
stub("features.dictionary", noop_mod())
stub("features.lockscreen", noop_mod({
    onSuspend = function() calls.lock_refresh = (calls.lock_refresh or 0) + 1 end,
}))
stub("features.remote", noop_mod())
stub("features.nightmode", noop_mod())
stub("features.ime", noop_mod())
-- guard 本身在 tests/ui/guard_spec.lua；这里透传并记下经它挂上的入口。
local guard_labels = {}
stub("ui.guard", {
    call = function(label, fn, ...)
        guard_labels[label] = true
        return fn(...)
    end,
    wrap = function(label, fn)
        return function(...)
            guard_labels[label] = true
            return fn(...)
        end
    end,
})
local feature_hooks, feature_loads = {}, 0
stub("features", {
    load = function() feature_loads = feature_loads + 1 end,
    emit = function(hook, host) feature_hooks[#feature_hooks + 1] = hook .. ":" .. host.path end,
    scan = function() return {} end,
    listeners = function() return {} end,
})

_G.G_reader_settings = {
    isTrue = function() return true end,
    saveSetting = function(_, key, value) reader_settings[key] = value end,
    readSetting = function(_, key, default)
        if reader_settings[key] == nil then return default end
        return reader_settings[key]
    end,
}

package.loaded["main"] = nil
local Main = require("main")
local menu = { registerToMainMenu = function() end }
local plugin = setmetatable({ path = "book.koplugin", ui = { menu = menu } }, Main)
current_source = mkSource({ id = "moon", onEvent = function() end })
plugin:init()
Assert.eq(table.concat(fm_order.setting, ","), "book_library,filebrowser", "设置菜单把月读置顶且不重复")
local start_item = FMMenu.getStartWithMenuTable()
Assert.eq(#start_item.sub_item_table, 1)
Assert.eq(start_item.sub_item_table[1].text, "月读")
start_item.sub_item_table[1].callback()
Assert.eq(start_item.text_func(), "Start with: 月读", "选中月读后标题不为 nil")
Assert.eq(table.concat(source_hooks, ","), "pushDirty:moon", "启动有网就推遗留脏行")
Assert.eq(calls.attach, 1)
Assert.eq(table.concat(dispatcher_actions, ","), "book_open_shelf", "feature 的手势由各自 onCreate 登记")
Assert.is_nil(calls.boot, "init 不直接挂功能，全部进 features")
Assert.eq(feature_loads, 1, "加载器在 main 顶层调一次")
Assert.eq(table.concat(feature_hooks, ","), "onCreate:book.koplugin")
feature_hooks = {}

-- 主菜单：demo/ 目录存在才转发给演示模块（打包剔除 demo/ 后不出现）
do
    local modes = {}
    package.loaded["libs/libkoreader-lfs"] = {
        attributes = function(path, key) Assert.eq(key, "mode") return modes[path] end,
    }
    stub("demo", {
        addToMainMenu = function(items) items.book_theme_demo = { text = "demo" } end,
    })
    local items = {}
    plugin:addToMainMenu(items)
    Assert.not_nil(items.book_library)
    Assert.is_nil(items.book_theme_demo)
    modes["book.koplugin/demo"] = "directory"
    plugin:addToMainMenu(items)
    Assert.not_nil(items.book_theme_demo)
end

-- 网络恢复：脏重试 + 源事件 + 锁屏刷新；更新检查不在这里（Desktop:activate）
do
    local seen = {}
    current_source = mkSource({
        id = "moon",
        onEvent = function(_, event) seen[#seen + 1] = event end,
    })
    calls.lock_refresh = 0
    calls.update_check = 0
    local net_desk = {
        lifecycle = { state = "Resume" },
        onNetworkConnected = function() seen[#seen + 1] = "desktop_net" end,
    }
    plugin.desktop = net_desk
    plugin.ui = { menu = menu } -- FM
    local before = #source_hooks
    plugin:onNetworkConnected()
    Assert.eq(source_hooks[#source_hooks], "pushDirty:moon")
    Assert.eq(#source_hooks - before, 1, "联网推脏行")
    Assert.eq(calls.lock_refresh, 0, "锁屏刷新由 feature onNetworkConnected 负责")
    Assert.eq(feature_hooks[#feature_hooks], "onNetworkConnected:book.koplugin")
    Assert.eq(calls.update_check, 0, "自动更新检查只在 Desktop:activate")
    -- 桌面在窗口栈上，自己收 UIManager 的 NetworkConnected 广播；插件再转就重复了。
    -- 推脏行不走 onEvent。
    Assert.eq(table.concat(seen, ","), "")
end

-- 阅读事件经 guard 挂会话入口：参数与返回值透传
for _, name in ipairs(READING_EVENTS) do
    Assert.eq(plugin[name](plugin, 7), name, name .. " 返回值透传")
    Assert.eq(reading[name][1], plugin)
    Assert.eq(reading[name][2], 7)
    Assert.is_true(guard_labels[name], name .. " 经 guard")
end

local resumed_desktop = {
    lifecycle = { state = "Resume" },
    tab = "library",
    onSuspend = function()
        calls.desktop_pause = (calls.desktop_pause or 0) + 1
    end,
    onResume = function(self)
        if self.tab == "home" then
            calls.home_enter = self
        else
            calls.library_resume = self
        end
    end,
    onExit = function(self)
        calls.desktop_destroy = (calls.desktop_destroy or 0) + 1
        self.lifecycle.state = "Destroy"
        -- 与 Desktop:destroy 同契约：销毁即摘掉 plugin.desktop。
        if plugin.desktop == self then plugin.desktop = nil end
    end,
    onNetworkConnected = function() end,
}
plugin.desktop = resumed_desktop
calls.session = nil
plugin:onResume()
Assert.is_true(calls.session.resume)
Assert.is_nil(calls.library_resume, "唤醒不经插件再转 Desktop:onResume")

current_source = mkSource({ id = "local" })
plugin.desktop = nil
Assert.is_true(plugin:onBookOpenShelf())
Assert.eq(calls.desktop_opened, plugin, "打开桌面整段交给 Desktop.open")
plugin.desktop = resumed_desktop

calls.session = nil
calls.lock_refresh = 0
local hooks_before_suspend = #source_hooks
plugin:onSuspend()
Assert.is_true(calls.session.suspend)
Assert.is_nil(calls.desktop_pause, "休眠不经插件转，桌面自收 Suspend 广播")
Assert.eq(feature_hooks[#feature_hooks], "onSuspend:book.koplugin", "休眠经 features 通知夜间模式")
Assert.eq(#source_hooks, hooks_before_suspend, "休眠不碰源（关书推送归阅读会话）")
Assert.eq(calls.lock_refresh, 0)

calls.session = nil
plugin:onResume()
Assert.is_true(calls.session.resume)
Assert.eq(feature_hooks[#feature_hooks], "onResume:book.koplugin", "唤醒经 features 通知夜间模式")
Assert.eq(source_hooks[#source_hooks], "pushDirty:local", "唤醒有网就推脏行（Wi-Fi 常开时不会再有联网事件）")

-- 混合模式：所有有脏行的已配置启用源都推；没脏行的不建实例，加载失败、未登录的跳过；离线谁都不推
do
    local resolved_ids = {}
    mixed_mode = true
    dirty.moon_off = true
    other_sources = { "wechat", "jdread", "moon_off", "copymanga", wechat = mkSource({ id = "wechat" }), jdread = false,
        moon_off = mkSource({ id = "moon_off", unconfigured = true }), copymanga = mkSource({ id = "copymanga" }) }
    local registry = require("source.registry")
    local resolve = registry.resolve
    registry.resolve = function(id) resolved_ids[#resolved_ids + 1] = id; return resolve(id) end
    local before = #source_hooks
    plugin:onResume()
    Assert.eq(table.concat(source_hooks, ",", before + 1), "pushDirty:local,pushDirty:wechat")
    Assert.eq(table.concat(resolved_ids, ","), "local,wechat,jdread,moon_off", "没脏行的 copymanga 不建实例")
    connected = false
    before = #source_hooks
    plugin:onResume()
    Assert.eq(#source_hooks, before, "离线不推，等联网")
    connected = true
    mixed_mode = false
    before = #source_hooks
    plugin:onResume()
    Assert.eq(table.concat(source_hooks, ",", before + 1), "pushDirty:local", "非混合模式只推当前源，其它源的脏行等切过去再推")
    feature_hooks[#feature_hooks] = nil
    registry.resolve = resolve
    other_sources = {}
    feature_hooks[#feature_hooks] = nil
end

local hooks_before_exit = #source_hooks
plugin:onExit()
Assert.eq(#source_hooks, hooks_before_exit, "退出不碰源")
Assert.is_nil(calls.desktop_destroy, "退出不经插件转，桌面自收 Exit 广播")
resumed_desktop:onExit()
Assert.eq(table.concat(feature_hooks, ","),
    "onNetworkConnected:book.koplugin,onResume:book.koplugin,onSuspend:book.koplugin,onResume:book.koplugin,onResume:book.koplugin,onExit:book.koplugin")

version_current = 202606000000
local attach_count = calls.attach
package.loaded["ko_version"] = nil
setmetatable({ path = "book.koplugin", ui = { menu = menu } }, Main):init()
Assert.eq(calls.attach, attach_count, "不支持的 KOReader 版本不得进入插件")
Assert.eq(calls.version_dialog.text, "月读需要 KOReader 2026.07 或更高版本。\n\n当前版本：2026.06")

-- 首次安装：强制启动项为月读，只种一次；自动开桌面只由 onShow 同步接管（FileManager 只经 showFiles 新建，init 后必有 Show）。
version_current = 202607000000
package.loaded["ko_version"] = nil
local function boot()
    package.loaded["main"] = nil
    local p = setmetatable({ path = "book.koplugin", ui = { menu = menu } }, require("main"))
    p:init()
    return p
end
current_source = mkSource({ id = "moon", onEvent = function() end })
moon_cfg.start_with_seeded = false
reader_settings.start_with = nil
calls.auto_open = {}
local fm = boot()
Assert.eq(reader_settings.start_with, "bookshelf_book")
Assert.is_true(moon_cfg.start_with_seeded)
Assert.len(calls.auto_open, 0, "init 不开桌面")
fm:onShow()
Assert.len(calls.auto_open, 1)
Assert.eq(calls.auto_open[1], fm)

-- 用户改回 filemanager：已种过，不再覆盖
reader_settings.start_with = "filemanager"
boot()
Assert.eq(reader_settings.start_with, "filemanager")
Assert.is_false(require("menu").openOnStart())
require("menu").setOpenOnStart(true)
Assert.eq(reader_settings.start_with, "bookshelf_book", "已持久化的取值不能改")
require("menu").setOpenOnStart(false)
Assert.eq(reader_settings.start_with, "filemanager", "取消即回到文件管理器")

-- 宿主入口与生命周期各步都经 guard
for _, label in ipairs({
    "init", "onShow", "addToMainMenu", "openShelf",
    "tasks.onSuspend", "session.onSuspend", "tasks.onResume", "session.onResume",
    "tasks.onNetworkConnected", "sources.pushDirty",
}) do
    Assert.is_true(guard_labels[label] or false, label .. " 经 guard")
end
