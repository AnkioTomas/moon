--[[--
月读插件入口 — 事件接线板。

KOReader 会为 FileManager 和 Reader 各建一个插件实例；
关书后 FM 侧实例才是开桌面的宿主。

本文件只做接线：init 时挂 KOReader 外壳（菜单 / 手势 / 启动项在 menu.lua，开机自动开桌面在
Desktop.autoOpen），其余是生命周期转发：阅读会话 / 启用源推脏行 / features / 后台任务。
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
local ROOT = debug.getinfo(1, "S").source:match("^@(.*)/")
allowInitModules(ROOT)
require("utils.modules").install(ROOT)

local WidgetContainer = require("ui/widget/container/widgetcontainer")
-- 版本门禁必须在其它业务模块加载之前：旧版 KOReader 缺 ffi/posix 等，顶层 require 就会抛错。
local KoVersion = require("ko_version")
if not KoVersion.supported() then return KoVersion.stub(WidgetContainer) end
local logger = require("utils.log")
-- 启动横幅只是诊断信息，失败不能拖垮插件加载。
local boot_ok, boot_err = pcall(logger.boot)
if not boot_ok then logger.warn("book boot banner failed", boot_err) end
local Wake = require("utils.wake")
pcall(Wake.boot)
require("l10n")

-- feature 加载器：各 feature 在自己的 init 里往 utils.extension 的通用挂点登记；这里不点名任何 feature。
require("features").load()

local SourceRegistry = require("source.registry")
local Desktop = require("desktop")
local Features = require("features")
local Guard = require("ui.guard")
local Perf = require("utils.perf")
local Menu = require("menu")
local Session = require("reader.session")
local Tasks = require("workers.tasks")

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

--- 有网时让有脏行的源推脏行：混合模式是全部启用源，否则只有当前源；没脏行的源不建实例，加载失败的源跳过。
local function pushDirty()
    if not require("ui/network/manager"):isConnected() then return end
    local SourceBase = require("source.base")
    for _idx, meta in ipairs(SourceRegistry.syncScope()) do
        local source = SourceBase.hasDirty(meta.id) and SourceRegistry.resolve(meta.id)
        if source and source:configured() then source:pushDirty() end
    end
end

--- 插件初始化：挂接 KOReader 宿主（菜单 / 开机打开等）与各增强模块。
--- KOReader 的 pcall 只会静默跳过插件，经 guard 才能弹错误页让用户反馈。
---@param self BookPlugin
local function init(self)
    allowInitModules(self.path)
    require("utils.event").init(require("features").listeners("events"))
    logger.info("book plugin init", self.ui.document and "reader" or "filemanager")
    Desktop.startInDataDir(self)
    local started_at = Perf.now()
    require("ui.fonts").onCreate()
    Perf.slow("init fonts", started_at)
    Menu.onCreate(self)
    require("desktop.reader_exit").install()
    require("source.auth").onExpired(function(id, msg) require("desktop.sync").promptLogin(self, id, msg) end)
    Perf.slow("init menu", started_at)
    Guard.call("sources.pushDirty", pushDirty)
    Features.emit("onCreate", self)
    Perf.slow("init total", started_at)
end
BookPlugin.init = Guard.wrap("init", init)

--- 休眠前：结清阅读状态，生成锁屏图，停远程服务，暂停后台任务；桌面在窗口栈上时自行收 Suspend。
function BookPlugin:onSuspend()
    logger.info("book lifecycle suspend")
    Wake.suspend()
    Wake.timed("tasks.onSuspend", Guard.call, "tasks.onSuspend", Tasks.onSuspend)
    Wake.timed("session.onSuspend", Guard.call, "session.onSuspend", Session.onSuspend, self)
    Wake.timed("hooks.onSuspend", Features.emit, "onSuspend", self)
    logger.info("book lifecycle suspend done")
    logger.flush()
end

--- 唤醒：恢复阅读统计、后台服务与后台任务；桌面在窗口栈上时自行收 Resume。
function BookPlugin:onResume()
    logger.info("book lifecycle resume")
    Wake.resume()
    Wake.timed("tasks.onResume", Guard.call, "tasks.onResume", Tasks.onResume)
    Wake.timed("session.onResume", Guard.call, "session.onResume", Session.onResume, self)
    -- 推脏行要查网络、走远程请求，放到锁屏关闭之后，不阻塞唤醒。
    require("ui/uimanager"):scheduleIn(Wake.GRACE, function() Guard.call("sources.pushDirty", pushDirty) end)
    Wake.timed("hooks.onResume", Features.emit, "onResume", self)
end

--- 网络恢复：续跑等网络的后台任务、源推脏、feature 自己刷新。
function BookPlugin:onNetworkConnected()
    logger.info("book lifecycle network_connected")
    Guard.call("tasks.onNetworkConnected", Tasks.onNetworkConnected)
    Guard.call("sources.pushDirty", pushDirty)
    Features.emit("onNetworkConnected", self)
end

--- 转屏：KOReader 的 IterateRotation 等动作只把 SetRotationMode / SetDimensions 送给 FileManager 或
--- ReaderUI（含本插件），桌面和弹窗是独立窗口收不到，这里转给窗口栈上要重排的窗口。
function BookPlugin:onSetDimensions()
    for _idx, win in ipairs(require("ui/uimanager")._window_stack) do
        local widget = win.widget
        if widget.relayout or widget.name == "book_desktop" then widget:onScreenResize() end
    end
end

--- 退出：停更新任务、远程服务；桌面在窗口栈上时自行收 Exit（销毁并关窗），这里再兜底清残留。
function BookPlugin:onExit()
    logger.info("book plugin exit")
    require("ui.exit_windows").exiting = true
    Features.emit("onExit", self)
    Guard.call("exit.closeWindows", require("ui.exit_windows").close)
    logger.info("book plugin exit done")
    logger.flush()
    Wake.exit()
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
    "onCloseDocument",
}) do
    BookPlugin[name] = Guard.wrap(name, Session[name])
end

return BookPlugin
