--[[--
月读桌面壳 — 顶栏 + Tab 内容 + 底栏拼装。
  页逻辑在 home / library / store / insight / settings；本文件只做编排、转发、手势。

布局（OverlapGroup 三层：1 内容 / 2 顶栏 / 3 底栏）：
  +-----------------------------------------------+
  | TopBar（时钟 · 源名 · 剩余内存/存储/Wi‑Fi/亮度/电量） |
  |-----------------------------------------------|
  |                                               |
  |          Tab 内容区（contentHeight）           |
  |                                               |
  |-----------------------------------------------|
  | Tabbar 首页|图书馆|[Z站]|[OPDS]|统计|[拓展]|设置 |
  +-----------------------------------------------+
  「拓展」不是页：点它在格子上方弹出第三方插件入口（features.extensions）。
  updateView：外壳（屏幕尺寸 / 主题 / 缩放）变了整壳重建；否则只换内容层和底栏层，刷顶栏以下。
  顶栏读数变化由 TopBar 自己经 updateTopbar 换第 2 层，只刷顶栏。
  手势：控件自己的点按优先（底栏格、顶栏项）；没被消费的底栏点按在这里吞掉，
  其余再交给文件管理器已配置的 gestures；内容区左右滑转给当前页；顶栏下滑开快捷面板。
  active：activate 置真、deactivate 置假；为假时不刷屏（窗口在栈上但被盖住 / 休眠）。

@module koplugin.book.desktop
--]]

local BD = require("ui/bidi")
local Device = require("device")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local Gesture = require("desktop.gesture")
local Sync = require("desktop.sync")
local Guard = require("ui.guard")
local MoonSettings = require("utils.settings")
local OverlapGroup = require("ui/widget/overlapgroup")
local UIManager = require("ui/uimanager")
local logger = require("utils.log")
local Perf = require("utils.perf")
local _ = require("gettext")
local Screen = Device.screen

local Home = require("desktop.pages.home")
local Library = require("desktop.pages.library")
local StorePage = require("desktop.pages.store")
local Insight = require("desktop.pages.insight")
local Settings = require("desktop.pages.setting")
local TopBar = require("desktop.topbar")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Tabbar = require("ui.themes.widgets.tabbar")

---@class BookDesktop : InputContainer
---@field closed boolean|nil destroy 置 true；桌面外持有旧引用的回调据此判断是否已关
---@field active boolean 前台可刷屏
---@field plugin BookPlugin|nil
---@field source BookSource|nil
---@field tab string
---@field home BookHome
---@field library BookLibrary
---@field store BookStorePage Z-Library
---@field opds BookStorePage OPDS 目录
---@field insight BookInsight
---@field settings BookSettings
---@field topbar BookTopBar
---@field layers table|nil 三层 OverlapGroup
---@field detail BookDetailPage|nil
---@field settings_overlay BookSettingsOverlay|nil
---@field _tabs table[]
---@field _shell string|nil 外壳签名：屏幕尺寸 / 主题 / 缩放
---@field _books_sync table<string, { cancel: { cancel: fun(self) }|nil }> 源 id → 在飞书架同步（desktop.sync）
---@field _stats_sync table<string, boolean> 源 id → 统计同步在飞
local Desktop = InputContainer:extend{
    name = "book_desktop",
    covers_fullscreen = true,
    plugin = nil,
    source = nil,
    tab = "home",
}

---@class BookDesktopCtx
---@field width number
---@field height number
---@field plugin BookPlugin|nil
---@field source BookSource|nil
---@field desktop BookDesktop

local PAGES = { home = true, library = true, store = true, opds = true, insight = true, settings = true }
local CHILDREN = { "topbar", "home", "library", "store", "opds", "insight", "settings" }
local CONTENT, TOP, BAR = 1, 2, 3

--- 调用指定子视图的事件或生命周期方法；不存在的接收者直接跳过。
---@param child table|nil 接收事件的子视图；nil 时跳过
---@param method string 子视图上的方法名
---@param ... any 原样传给接收方法的参数
local function notify(child, method, ...)
    if child and child[method] then child[method](child, ...) end
end

--- 按组件注册顺序把同一事件和参数分发给子视图。
---@param self BookDesktop 拥有子视图的父实例
---@param method string 子视图上的方法名
---@param ... any 原样传给接收方法的参数
local function broadcast(self, method, ...)
    for _idx, key in ipairs(CHILDREN) do notify(self[key], method, ...) end
end

--- 按开关生成 Desktop 底栏 Tab（Z-Library / OPDS 默认关）。统计页始终在。
---@return table
local function desktopTabs()
    local tabs = {
        { id = "home", text = _("首页"), icon = "home" },
        { id = "library", text = _("图书馆"), icon = "local_library" },
    }
    local store = MoonSettings.get("store")
    if store.zlib_enabled then
        tabs[#tabs + 1] = { id = "store", text = _("Z站"), icon = "storefront" }
    end
    if store.opds_enabled then
        tabs[#tabs + 1] = { id = "opds", text = _("OPDS"), icon = "rss_feed" }
    end
    tabs[#tabs + 1] = { id = "insight", text = _("统计"), icon = "bar_chart" }
    if MoonSettings.get("features.extensions").enabled then
        tabs[#tabs + 1] = { id = "extensions", text = _("拓展"), icon = "extension" }
    end
    tabs[#tabs + 1] = { id = "settings", text = _("设置"), icon = "settings" }
    return tabs
end

--- 重算 Tab；当前 tab 不在列表中则回退 home（换源 / 书城开关）。
---@param self BookDesktop
local function syncTabs(self)
    self._tabs = desktopTabs()
    for _idx, t in ipairs(self._tabs) do
        if t.id == self.tab then return end
    end
    self.tab = "home"
end

--- 外壳签名：任一项变了，顶栏 / 底栏高度或配色就可能变，只能整壳重建。
---@return string
local function shellKey()
    return table.concat({
        Screen:getWidth(), Screen:getHeight(), tostring(MoonSettings.get("ui").ui_theme), Theme.scale(),
    }, ":")
end

--- 当前页内容，定位到顶栏之下并钉成内容区尺寸。
---@param self BookDesktop
---@return table
local function content(self)
    local widget = self[self.tab]:updateView()
    local w, h = self.dimen.w, self:contentHeight()
    if widget.dimen then
        widget.dimen.w, widget.dimen.h = w, h
    else
        widget.dimen = Geom:new{ w = w, h = h }
    end
    widget.overlap_offset = { 0, TopBar.height() }
    return widget
end

--- 底栏：放在屏幕底部，点格子切 Tab。
---@param self BookDesktop
---@return table
local function tabbar(self)
    local bar = Tabbar.widget{
        width = self.dimen.w,
        tabs = self._tabs,
        active = self.tab,
        on_tab = function(id, rect)
            if id == "extensions" then
                require("features.extensions").show(self.plugin, rect)
            else
                self:switchTab(id)
            end
        end,
    }
    bar.overlap_offset = { 0, self.dimen.h - Tabbar.height() }
    return bar
end

--- 换第 i 层并释放旧层。
---@param self BookDesktop
---@param index integer CONTENT / TOP / BAR
---@param widget table
local function setLayer(self, index, widget)
    local old = self.layers[index]
    self.layers[index] = widget
    if old ~= widget then old:free() end
end

--- 换源：更新 Tab，广播给各页自己复位，再回到首页。
---@param self BookDesktop 当前视图或布局实例
---@param source BookSource|nil 书籍所属数据源实例
local function applySource(self, source)
    self.source = source
    broadcast(self, "onEvent", "source_changed", source)
    self:switchTab("home")
end

--- 只广播给各页。
---@param event string|table 父组件转发的事件名称或事件对象
---@param payload any 与事件一起传入的数据
function Desktop:onEvent(event, payload)
    if self.closed then return end
    broadcast(self, "onEvent", event, payload)
end

--- KOReader 事件 SourceChanged（`source.registry` 的 notifyChanged / reload 广播）：
--- 换成当前源并复位各页，再让新源做桌面打开维护。
function Desktop:onSourceChanged()
    local source = require("source.registry").current()
    logger.info("book source changed", source and source.id or "unavailable")
    applySource(self, source)
    Sync.open(self)
end

--- 建各页与手势区，拼出第一帧（显示与刷屏由调用方 UIManager:show 负责）。
function Desktop:init()
    self.active = false
    self._books_sync, self._stats_sync = {}, {}
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.home = Home:new{ desktop = self, name = "home" }
    self.library = Library:new{ desktop = self, name = "library" }
    self.store = StorePage:new{ desktop = self, name = "store", store_id = "zlib", empty_text = _("Z站暂无内容") }
    self.opds = StorePage:new{ desktop = self, name = "opds", store_id = "opds", empty_text = _("目录暂无内容") }
    self.insight = Insight:new{ desktop = self, name = "insight" }
    self.settings = Settings:new{ desktop = self }
    self.topbar = TopBar:new{ desktop = self }
    self.ges_events = {
        SwipeTopBar = Gesture.range("swipe", function() return 0 end, TopBar.height),
        TapBar = Gesture.range("tap", function() return Screen:getHeight() - Tabbar.height() end, Tabbar.height),
        Swipe = Gesture.range("swipe", TopBar.height, function() return self:contentHeight() end),
    }
    self:build()
end

--- 桌面回到前台：打开后、系统唤醒（Resume 经 UIManager 广播直达，插件不要再转发，否则重复）。
function Desktop:activate()
    if self.closed then return end
    self.active = true
    notify(self.topbar, "activate")
    notify(self[self.tab], "activate")
    -- 插件更新检查、NTP 校时走桌面 Resume，不在插件 init / 网络回调里抢跑。
    local root = self.plugin and self.plugin.path
    if root then
        require("features.update").autoCheck(root)
    end
    require("features.clock").autoSync()
end

Desktop.onResume = Desktop.activate

function Desktop:deactivate()
    self.active = false
    broadcast(self, "deactivate")
end
--- 系统休眠广播直达（窗口在栈上）。
Desktop.onSuspend = Desktop.deactivate

function Desktop:onCancel()
    broadcast(self, "onCancel")
end

function Desktop:destroy()
    if self.closed then return end
    if self.active then self:deactivate() end
    self.closed = true
    if self.settings_overlay then self.settings_overlay:close() end
    broadcast(self, "destroy")
    local plugin = self.plugin
    if plugin and plugin.desktop == self then
        plugin.desktop = nil
    end
end
--- 系统退出广播直达（窗口在栈上）。
Desktop.onExit = Desktop.destroy

--- 桌面盖住 FileManager 后 UIManager 只把手势发给栈顶；月读控件没消费的手势再交给文件管理器已配置动作。
--- 顺序不能反：KOReader 默认把左下角点按绑成开关前光，会吞掉「首页」Tab。
---@param desktop BookDesktop
---@param event table KOReader 事件
---@return boolean|nil
local function route(desktop, event)
    local handled = InputContainer.handleEvent(desktop, event)
    if handled or event.handler ~= "onGesture" then return handled end
    return Gesture.fm(desktop, event.args[1])
end

--- 桌面所有事件的入口，经 guard 隔离：页面里的 bug 弹错误页，不带崩 KOReader。
--- 已销毁的桌面可能还在窗口栈上（Exit 广播只 destroy 不关窗），事件一律放行给下层。
--- 原始输入可能不是 Event、没有 handler，见 Modal:handleEvent。
---@param event table|string KOReader 事件
---@return boolean|nil
function Desktop:handleEvent(event)
    if self.closed then return end
    return Guard.call("desktop " .. tostring(event.handler or event), route, self, event)
end

--- 墨水屏控制器异步读帧缓冲：上一次刷新还没读完就整页重画，会被读成半帧（封面连续落定时满屏错乱）。
--- 先等上一次刷新结束再画；同一刷新只等一次，非墨水屏平台为空操作。
---@param bb BlitBuffer
---@param x number
---@param y number
--- 经 guard 按页签隔离：某页画坏只停画这一页，切到别的页签照常。
function Desktop:paintTo(bb, x, y)
    Screen:refreshWaitForLast()
    Guard.paint("desktop paint " .. self.tab, InputContainer.paintTo, self, bb, x, y)
end

--- 顶栏向下滑：打开桌面快捷面板。
---@param _arg any 事件框架传入但本实现不使用的参数
---@param ges_ev table|nil KOReader 手势数据，含方向和位置
---@return boolean
function Desktop:onSwipeTopBar(_arg, ges_ev)
    if ges_ev.direction == "south" then
        require("features.panel.native").show("desktop")
    end
    return true
end

--- 底栏格子没接住的点按（分割线、右侧取整余量）也吞掉，不漏给文件管理器手势。
---@return boolean
function Desktop:onTapBar()
    return true
end

--- 内容区高度（扣除顶栏 + 底栏）。
---@return number
function Desktop:contentHeight()
    return math.max(1, Screen:getHeight() - TopBar.height() - Tabbar.height())
end

--- 传给各 Tab 的上下文：plugin / source / desktop。
---@return BookDesktopCtx
function Desktop:ctx()
    return {
        width = self.dimen.w,
        height = self:contentHeight(),
        plugin = self.plugin,
        source = self.source,
        desktop = self,
    }
end

--- 内容区左右滑：只转给当前页。
---@param _arg any 事件框架传入但本实现不使用的参数
---@param ges_ev table|nil KOReader 手势数据，含方向和位置
---@return boolean
function Desktop:onSwipe(_arg, ges_ev)
    notify(self[self.tab], "onEvent", "swipe", {
        direction = BD.flipDirectionIfMirroredUILayout(ges_ev.direction),
    })
    return true
end

--- 切换底栏 Tab。页数据跟着页对象走；壳用 updateView 换内容层。
---@param id string 底栏 Tab 标识，须在 PAGES 内
function Desktop:switchTab(id)
    if not PAGES[id] then return end
    local changed = self.tab ~= id
    if changed then notify(self[self.tab], "deactivate") end
    self.tab = id
    notify(self[self.tab], "activate", changed)
    self:updateView()
end

--- 整壳重建：三层全部新建，旧树整棵释放。
function Desktop:build()
    local started_at = Perf.now()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self._shell = shellKey()
    syncTabs(self)
    local top = self.topbar:build(self.dimen.w)
    top.overlap_offset = { 0, 0 }
    self.layers = OverlapGroup:new{
        dimen = Geom:new{ w = self.dimen.w, h = self.dimen.h },
        content(self), top, tabbar(self),
    }
    local old = self[1] --[[@as WidgetContainer|nil]]
    self[1] = Box:new{
        style = { bg = Theme.current().color.page },
        width = self.dimen.w,
        height = self.dimen.h,
        self.layers,
    }
    if old then old:free() end
    logger.dbg("book.perf desktop.build", Perf.elapsedMs(started_at), "ms", self.tab)
end

--- 刷新：外壳变了整壳重建全刷；否则换内容层和底栏层，只刷顶栏以下。
function Desktop:updateView()
    if self.closed then return end
    local started_at = Perf.now()
    if shellKey() ~= self._shell then
        self:build()
        if self.active then UIManager:setDirty(self, "ui") end
    else
        syncTabs(self)
        setLayer(self, BAR, tabbar(self))
        setLayer(self, CONTENT, content(self))
        if self.active then
            local top_h = TopBar.height()
            UIManager:setDirty(self, "ui", Geom:new{ x = 0, y = top_h, w = self.dimen.w, h = self.dimen.h - top_h })
        end
    end
    logger.dbg("book.perf desktop.updateView", Perf.elapsedMs(started_at), "ms", self.tab)
    if self.settings_overlay then
        self.settings_overlay:updateView()
    end
end

--- 顶栏读数变化：只换第 2 层、只刷顶栏。
function Desktop:updateTopbar()
    if self.closed then return end
    local top = self.topbar:build(self.dimen.w)
    top.overlap_offset = { 0, 0 }
    setLayer(self, TOP, top)
    if self.active then
        UIManager:setDirty(self, "ui", Geom:new{ x = 0, y = 0, w = self.dimen.w, h = TopBar.height() })
    end
end

--- KOReader 关窗入口，不是生命周期。destroy 会先补齐 deactivate。
---@return boolean
function Desktop:onClose()
    if self.closed then return true end
    self:destroy()
    logger.flush()
    UIManager:close(self, "ui")
    return true
end

--- Widget 关闭回调：若尚未销毁，走 destroy。
function Desktop:onCloseWidget()
    if self.closed then return end
    self:destroy()
    logger.flush()
end

--- 打开月读全屏桌面。阅读中先关书，再交给 FM 实例打开，避免桌面叠在未关闭的阅读器上；
--- 已有桌面先销毁再重建。桌面可见后后台同步书架与统计（desktop.sync）。
---@param plugin BookPlugin
function Desktop.open(plugin)
    if plugin.ui and plugin.ui.document then
        plugin.ui:onClose()
        local FileManager = require("apps/filemanager/filemanager")
        if not FileManager.instance then FileManager:showFiles() end
        Desktop.open(FileManager.instance.book)
        return
    end

    local source = require("source.registry").current()
    if not source then
        require("ui.themes.widgets.toast"):new{ text = _("当前数据源不可用") }:show()
        return
    end
    require("utils.paths").ensureLayout(source.id)
    logger.info("book openDesktop", source.id)
    local old = plugin.desktop
    if old then
        old:destroy()
        UIManager:close(old)
    end

    -- 入口来自菜单 / 弹窗回调，KOReader 不保护：构建失败弹错误页，不带崩阅读器。
    local desk = Guard.call("desktop open", Desktop.new, Desktop, { plugin = plugin, source = source })
    if not desk then
        plugin.desktop = nil
        return
    end
    plugin.desktop = desk
    UIManager:show(desk)
    UIManager:setDirty(desk, "ui")
    desk:activate()
    Sync.open(desk)
end

--- 本进程是否自动开桌面：nil 还没见过 FM / true 待开 / false 不再自动开
local want_auto_open = nil

--- FM 显示时按启动项自动开桌面，本进程只开一次；Reader 实例忽略。
---@param plugin BookPlugin
function Desktop.autoOpen(plugin)
    if plugin.ui.document or plugin.desktop then return end
    if want_auto_open == nil then
        want_auto_open = require("menu").openOnStart()
    end
    if not want_auto_open then return end
    want_auto_open = false
    Desktop.open(plugin)
end

return Desktop
