--[[--
月读插件入口 — 事件接线板。

KOReader 会为 FileManager 和 Reader 各建一个插件实例；
关书后 FM 侧实例才是开桌面的宿主。

本文件只做接线：init 时挂 KOReader 外壳（菜单 / 手势 / 启动项在 menu.lua，开机自动开桌面在
Desktop.autoOpen），其余是生命周期转发：阅读会话 / 所有启用源 / features / 后台任务 / 脏同步重试。
业务规则在 book/、reader/session、source/。

@module koplugin.book
--]]

--- KOReader 只把插件目录的 ?.lua 放进 package.path。目录模块（desktop/init.lua）
--- 要额外的 ?/init.lua。加载器在 dofile 返回后会重写 path，init 里再补一次。
---@param root string 插件根目录
local function allowInitModules(root)
    local entry = root .. "/?/init.lua"
    if not package.path:find(entry, 1, true) then
        package.path = package.path .. ";" .. entry
    end
end
allowInitModules(debug.getinfo(1, "S").source:match("^@(.*)/"))

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local logger = require("utils.log")
require("l10n")

local SourceRegistry = require("source.registry")
local Desktop = require("desktop")
local Features = require("features")
local Guard = require("ui.guard")
local Menu = require("menu")
local Session = require("reader.session")

--- Book 插件实例（FM / Reader 各一份）
---@class BookPlugin : WidgetContainer
---@field desktop BookDesktop|nil 当前全屏桌面实例
---@field path string 插件根目录
---@field ui table KOReader FileManager / ReaderUI
local BookPlugin = WidgetContainer:extend {
    name = "book",
}

--- 插件自己没接的事件交给 feature 的 events 表。
function BookPlugin:handleEvent(event)
    return WidgetContainer.handleEvent(self, event) or Features.handleEvent(event, self)
end

-- ── 插件生命周期 ─────────────────

--- 插件生命周期转给所有启用源：混合模式下它们都在用，要不要响应由源自己判断；加载失败的源跳过。
---@param plugin BookPlugin
---@param hook "onCreate"|"onPause"|"onResume"|"onDestroy"
local function emitSource(plugin, hook)
    for _idx, meta in ipairs(SourceRegistry.listEnabled()) do
        local source = SourceRegistry.resolve(meta.id)
        if source then Guard.call("source " .. meta.id .. "." .. hook, source[hook], source, plugin) end
    end
end

--- 插件初始化：挂接 KOReader 宿主（菜单 / 开机打开等）与各增强模块。
--- KOReader 的 pcall 只会静默跳过插件，经 guard 才能弹错误页让用户反馈。
---@param self BookPlugin
local function init(self)
    allowInitModules(self.path)
    if not require("ko_version").check() then
        return
    end
    logger.info("book plugin init", self.ui.document and "reader" or "filemanager")
    require("ui.fonts").onCreate()
    Menu.onCreate(self)
    emitSource(self, "onCreate")
    Features.emit("onCreate", self)
    -- 兜底：别的插件 onShow 返回 true 会截断 Show，本插件收不到。
    UIManager:nextTick(function() Guard.call("autoOpen", Desktop.autoOpen, self) end)
end
BookPlugin.init = Guard.wrap("init", init)

--- 休眠前：结清阅读状态，生成锁屏图，停远程服务，暂停后台任务；桌面在窗口栈上时自行收 Suspend。
function BookPlugin:onSuspend()
    logger.info("book lifecycle suspend")
    Guard.call("tasks.onSuspend", require("workers.tasks").onSuspend)
    Guard.call("session.onSuspend", Session.onSuspend, self)
    emitSource(self, "onPause")
    Features.emit("onPause", self)
    logger.flush()
end

--- 唤醒：恢复阅读统计、后台服务与后台任务；桌面在窗口栈上时自行收 Resume。
function BookPlugin:onResume()
    logger.info("book lifecycle resume")
    Guard.call("tasks.onResume", require("workers.tasks").onResume)
    Guard.call("session.onResume", Session.onResume, self)
    emitSource(self, "onResume")
    Features.emit("onResume", self)
end

--- 网络恢复：续跑等网络的后台任务、重试脏数据、刷新锁屏。
function BookPlugin:onNetworkConnected()
    logger.info("book lifecycle network_connected")
    Guard.call("tasks.onNetworkConnected", require("workers.tasks").onNetworkConnected)
    Guard.call("sync.onNetworkConnected", require("book.sync").onNetworkConnected)
    Features.emit("onNetworkConnected", self)
end

--- 退出：停更新任务、远程服务；桌面在窗口栈上时自行收 Exit。
function BookPlugin:onExit()
    logger.info("book plugin exit")
    emitSource(self, "onDestroy")
    Features.emit("onDestroy", self)
    logger.flush()
end

-- ── 宿主入口：打开月读 ─────────────────

--- FM 显示时同步接管（避免 FileManager 先闪一帧）
BookPlugin.onShow = Guard.wrap("onShow", Desktop.autoOpen)

--- Dispatcher / 手势：打开月读
---@return boolean 已处理
function BookPlugin:onBookOpenShelf()
    Guard.call("openShelf", Desktop.open, self)
    return true
end

BookPlugin.addToMainMenu = Guard.wrap("addToMainMenu", Menu.addToMainMenu)

-- ── 阅读会话 ─────────────────
-- KOReader 阅读事件只送到插件实例；会话入口与事件同名同参（首参即插件），经 guard 直接挂上。
-- 按一本书从打开到关闭的顺序排列。
for _idx, name in ipairs({
    "onDocSettingsLoad",
    "onReaderReady",
    "onPageUpdate",
    "onPosUpdate",
    "onAnnotationsModified",
    "onEndOfBook",
    "onStartOfBook",
    "onCloseDocument",
}) do
    BookPlugin[name] = Guard.wrap(name, Session[name])
end

return BookPlugin
