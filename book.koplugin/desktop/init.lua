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
  | Tabbar 首页|图书馆|[订阅]|[Z站]|[OPDS]|统计|[拓展]|设置 |
  +-----------------------------------------------+
  方括号内的格子来自扩展点 desktop.tabs（utils.extension）：有 create 的是页，只有 tap 的不是页（点它自己弹东西）。
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
local Ext = require("utils.extension")
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
---@field _room number 底栏剩余格数
---@field monitor table|nil 内存监控页缓存
---@field closed boolean|nil destroy 置 true；桌面外持有旧引用的回调据此判断是否已关
---@field active boolean 前台可刷屏
---@field plugin BookPlugin|nil
---@field source BookSource|nil
---@field tab string
---@field home BookHome
---@field library BookLibrary
---@field store BookStorePage Z-Library
---@field insight BookInsight
---@field settings BookSettings
---@field ext_pages table<string, table> 扩展页签 id → 页实例（按需建，扩展关掉即销毁）
---@field topbar BookTopBar
---@field layers table|nil 三层 OverlapGroup
---@field detail BookDetailPage|nil
---@field settings_overlay BookSettingsOverlay|nil
---@field storage_usage BookStorageUsage|nil 存储空间页的统计缓存（features/storage）
---@field storage_job { cancel: fun() }|nil
---@field _tabs table[]
---@field _shell string|nil 外壳签名：屏幕尺寸 / 主题 / 缩放
---@field _books_sync table<string, { cancel: { cancel: fun(self) }|nil }> 源 id → 在飞书架同步（desktop.sync）
---@field _stats_sync table<string, boolean> 源 id → 统计同步在飞
local Desktop = InputContainer:extend{
    name = "book_desktop",
    -- 月读自己的窗口：退出兜底（BookPlugin:onExit）按此标记清理残留
    book_window = true,
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

local PAGES = { home = true, library = true, store = true, insight = true, settings = true }
local CHILDREN = { "topbar", "home", "library", "store", "insight", "settings" }
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
    for _idx, page in pairs(self.ext_pages or {}) do notify(page, method, ...) end
end

--- 底栏一格的最小宽度（逻辑像素），决定扩展页签能多占几格。
local MIN_CELL = 64

--- 已启用的扩展页签（desktop.tabs），按登记顺序。
---@return table[]
local function extTabs()
    local out = {}
    for _idx, tab in ipairs(Ext.list("desktop.tabs")) do
        if not tab.enabled or tab.enabled() then out[#out + 1] = tab end
    end
    return out
end

--- 扩展页签定义；没启用返回 nil。
---@param id string
---@return table|nil
local function extTab(id)
    for _idx, tab in ipairs(extTabs()) do
        if tab.id == id then return tab end
    end
end

--- 按开关生成 Desktop 底栏 Tab（书城：有可搜索来源才出现）。统计页始终在。
---@return table tabs, number room
local function desktopTabs()
    local tabs = {
        { id = "home", text = _("首页"), icon = "home" },
        { id = "library", text = _("图书馆"), icon = "local_library" },
    }
    if #StorePage.providers() > 0 then
        tabs[#tabs + 1] = { id = "store", text = _("书城"), icon = "storefront" }
    end
    tabs[#tabs + 1] = { id = "insight", text = _("统计"), icon = "bar_chart" }
    -- 扩展页签：插在 after 指定的格子后（同一 after 按登记顺序），没写 after 就排在「设置」前。
    -- 页签可带 cells(room)：按屏宽剩余的空格数换成多个格子（替换自己那一格），没有就是它自己。
    local exts = extTabs()
    local room = math.floor(Screen:getWidth() / Theme.px(MIN_CELL)) - (#tabs + #exts + 1)
    for _idx, ext in ipairs(exts) do
        local at = #tabs + 1
        for i, t in ipairs(tabs) do
            if ext.after and (t.id == ext.after or t.after == ext.after) then at = i + 1 end
        end
        local cells = ext.cells and ext.cells(math.max(room, 0))
        if cells then
            for i, cell in ipairs(cells) do
                table.insert(tabs, at + i - 1, { id = cell.id, text = cell.text, icon = cell.icon, after = ext.after, owner = ext.id })
            end
        else
            table.insert(tabs, at, { id = ext.id, text = ext.text, icon = ext.icon, after = ext.after })
        end
    end
    tabs[#tabs + 1] = { id = "settings", text = _("设置"), icon = "settings" }
    return tabs, room
end

--- 重算 Tab；当前 tab 不在列表中则回退 home（换源 / 书城开关）。
---@param self BookDesktop
local function syncTabs(self)
    self._tabs, self._room = desktopTabs()
    -- 扩展页签关掉后丢掉它的页（连同缓存与在飞请求）。
    for id, page in pairs(self.ext_pages) do
        if not extTab(id) then
            notify(page, "destroy")
            self.ext_pages[id] = nil
        end
    end
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
    local widget = self:page(self.tab):updateView()
    local w, h = self.dimen.w, self:contentHeight()
    if widget.dimen then
        widget.dimen.w, widget.dimen.h = w, h
    else
        widget.dimen = Geom:new{ w = w, h = h }
    end
    widget.overlap_offset = { 0, TopBar.height() }
    local backdrop = Ext.last("desktop.backdrop")
    if backdrop then backdrop.content(widget, self.tab) end
    return widget
end

--- 底栏：放在屏幕底部，点格子切 Tab。
---@param self BookDesktop
---@return table
local function tabbar(self)
    local backdrop = Ext.last("desktop.backdrop")
    local bar = Tabbar.widget{
        plain = backdrop and backdrop.plain_tabbar(self.tab),
        width = self.dimen.w,
        tabs = self._tabs,
        active = self.tab,
        on_tab = function(id, rect)
            local cell
            for _idx, t in ipairs(self._tabs) do
                if t.id == id then cell = t break end
            end
            local ext = extTab(cell and cell.owner or id)
            if ext and not ext.create and ext.tap then
                ext.tap(self, rect, cell and cell.owner and id or nil)
            else
                self:switchTab(id)
            end
        end,
    }
    bar.overlap_offset = { 0, self.dimen.h - Tabbar.height() }
    if backdrop then backdrop.tabbar(bar, self.tab) end
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

--- 换源：广播给各页自己复位，留在当前页签重新激活（页签不可用时 syncTabs 回首页）。
---@param self BookDesktop 当前视图或布局实例
---@param source BookSource|nil 书籍所属数据源实例
local function applySource(self, source)
    self.source = source
    broadcast(self, "onEvent", "source_changed", source)
    syncTabs(self)
    local page = self:page(self.tab)
    notify(page, "activate", true)
    self:updateView()
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

--- KOReader 事件 StoreChanged（书城开关 / 来源地址变了）：只重置书城页并刷新底栏，不换源、不跳首页。
function Desktop:onStoreChanged()
    self.store:reset()
    self:updateView()
end

--- 建各页与手势区，拼出第一帧（显示与刷屏由调用方 UIManager:show 负责）。
function Desktop:init()
    self.active = false
    self._books_sync, self._stats_sync = {}, {}
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ext_pages = {}
    self.home = Home:new{ desktop = self, name = "home" }
    self.library = Library:new{ desktop = self, name = "library" }
    self.store = StorePage:new{ desktop = self, name = "store" }
    self.insight = Insight:new{ desktop = self, name = "insight" }
    self.settings = Settings:new{ desktop = self }
    self:restoreView()
    self.topbar = TopBar:new{ desktop = self }
    self.ges_events = {
        SwipeTopBar = Gesture.range("swipe", function() return 0 end, TopBar.height),
        TapBar = Gesture.range("tap", function() return Screen:getHeight() - Tabbar.height() end, Tabbar.height),
        Swipe = Gesture.range("swipe", TopBar.height, function() return self:contentHeight() end),
    }
    -- 物理翻页键（Kindle / Kobo 侧键，安卓开启音量键翻页后也映射到这里）翻当前页签。
    -- 反转翻页键、横屏键位旋转由 KOReader 设备层处理，这里收到的已是最终方向。
    -- 方向键只给键多的设备，和 ReaderPaging 一致，少键设备不占用。
    if Device:hasKeys() then
        local fwd, back = { "RPgFwd", "LPgFwd" }, { "RPgBack", "LPgBack" }
        if not Device:hasFewKeys() then
            fwd[#fwd + 1], back[#back + 1] = "Right", "Left"
        end
        self.key_events.DesktopPageNext = { { fwd }, event = "DesktopTurn", args = 1 }
        self.key_events.DesktopPagePrev = { { back }, event = "DesktopTurn", args = -1 }
    end
    self:build()
end

--- 桌面回到前台：打开后、系统唤醒（Resume 经 UIManager 广播直达，插件不要再转发，否则重复）。
function Desktop:activate()
    if self.closed then return end
    self.active = true
    notify(self.topbar, "activate")
    notify(self:page(self.tab), "activate")
    -- 扩展的前台维护（更新检查、校时等）走桌面 Resume，不在插件 init / 网络回调里抢跑。
    Ext.emit("desktop.activated", self)
    require("desktop.welcome").promptDocs()
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

--- 上一次桌面的浏览位置：进程内留存，读书退出重开桌面时还原（页签、书架的分组 / 筛选 / 页码 / 目录）。
---@type { source_id: string, tab: string, library: table }|nil
local remembered = nil

--- 重开桌面时还原上次位置；换了源不还原。页签不可用时 syncTabs 会落回首页。
function Desktop:restoreView()
    local last = remembered
    remembered = nil
    if not last or last.source_id ~= self.source.id then return end
    if last.tab ~= "settings" then self.tab = last.tab end
    for k, v in pairs(last.library) do self.library[k] = v end
end

function Desktop:destroy()
    if self.closed then return end
    local lib = self.library
    remembered = { source_id = self.source.id, tab = self.tab, library = {
        group = lib.group, group_page = lib.group_page, page = lib.page, filter = lib.filter, dir = lib.dir,
    } }
    if self.active then self:deactivate() end
    self.closed = true
    -- 桌面打开的子窗口一并关掉，否则退出时残留在窗口栈上，KOReader 等不到空栈不退出。
    -- 先摘引用再关：子窗口的 close_callback 见 desktop.closed 直接返回，不会回头重画桌面。
    local overlay, detail = self.settings_overlay, self.detail
    self.settings_overlay, self.detail = nil, nil
    if overlay then overlay:close() end
    if detail and not detail.closed then detail:close() end
    broadcast(self, "destroy")
    local plugin = self.plugin
    if plugin and plugin.desktop == self then
        plugin.desktop = nil
    end
end
--- 系统退出广播直达（窗口在栈上）：销毁并真正关窗。
--- 只 destroy 不关窗会把已销毁的桌面留在栈上：普通「退出」靠空栈收尾（UIManager:_gated_quit），
--- 于是 KOReader 永不退出、界面假死；「重启」走 quit(85) 清栈才不受影响。
--- 返回 false：广播继续送给下层 FileManager / ReaderUI（DeviceListener 才是真正的退出动作）。
---@return boolean
function Desktop:onExit()
    if not self.closed then self:destroy() end
    UIManager:close(self)
    return false
end

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

--- 旋转屏幕：FileManager 在同一次广播里转屏，桌面等下一 tick 屏幕尺寸稳定后整壳重建。
--- 返回 false 让广播继续送给下层 FileManager。
---@return boolean
function Desktop:onSetRotationMode()
    UIManager:nextTick(function()
        if self.closed or shellKey() == self._shell then return end
        Guard.call("desktop rotate", function()
            self:build()
            UIManager:setDirty(self, "full")
        end)
    end)
    return false
end

Desktop.onScreenResize = Desktop.onSetRotationMode

--- 桌面所有事件的入口，经 guard 隔离：页面里的 bug 弹错误页，不带崩 KOReader。
--- 已销毁、尚未出栈的桌面（关窗过程中）事件一律放行给下层。
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
        Ext.call("quickpanel.show", "desktop")
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
    notify(self:page(self.tab), "onEvent", "swipe", {
        direction = BD.flipDirectionIfMirroredUILayout(ges_ev.direction),
    })
    return true
end

--- 物理翻页键：按「下一页 / 上一页」语义转成当前页签的左右滑（不做 RTL 翻转，按键不是物理方向）。
--- 吃掉按键，不漏给下层文件管理器翻文件列表。弹窗在栈顶时按键到不了这里。
--- 「桌面物理翻页键」关闭时不处理、返回 false，按键照旧交给下层；按键时读设置，切换立即生效。
---@param dir integer 1 下一页，-1 上一页
---@return boolean
function Desktop:onDesktopTurn(dir)
    if MoonSettings.get("desktop").page_keys == false then return false end
    notify(self:page(self.tab), "onEvent", "swipe", { direction = dir > 0 and "west" or "east" })
    return true
end

--- 按 id 取页：核心页直接是字段；扩展页签（desktop.tabs 带 create）按需建，没启用返回 nil。
---@param id string
---@return table|nil
function Desktop:page(id)
    if PAGES[id] then return self[id] end
    local page = self.ext_pages[id]
    if page then return page end
    local ext = extTab(id)
    if ext and ext.create then
        page = ext.create({ desktop = self, name = id })
        self.ext_pages[id] = page
    end
    return page
end

--- 切换底栏 Tab。页数据跟着页对象走；壳用 updateView 换内容层。
---@param id string 底栏 Tab 标识，须在 PAGES 内
function Desktop:switchTab(id)
    if not PAGES[id] and not self:page(id) then return end
    local changed = self.tab ~= id
    if changed then notify(self:page(self.tab), "deactivate") end
    self.tab = id
    notify(self:page(id), "activate", changed)
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
    local backdrop = Ext.last("desktop.backdrop")
    self[1] = Box:new{
        style = { bg = Theme.current().color.page },
        width = self.dimen.w,
        height = self.dimen.h,
        backdrop and backdrop.wrap(self.dimen.w, self.dimen.h, self.layers, self.tab) or self.layers,
    }
    if old then old:free() end
    logger.dbg("book.perf desktop.build", Perf.elapsedMs(started_at), "ms", self.tab)
end

--- 一个扩展页签最多能展开成几格（按屏宽；至少 1）。
---@return integer
function Desktop:cellCapacity()
    return math.max(self._room, 0) + 1
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
        -- 壁纸底座按页签取各界面的壁纸设置；换页后顶栏底下的壁纸也要跟着换
        local backdrop = self[1][1]
        local rescoped = backdrop ~= self.layers and backdrop.scope ~= self.tab
        if rescoped then backdrop.scope = self.tab end
        if self.active then
            local top_h = rescoped and 0 or TopBar.height()
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
        Desktop.open(Desktop.ensureFileManager().book)
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
    -- 扩展的打开后任务（open 前已关书，阅读中不会触发）。
    Ext.emit("desktop.opened", desk)
end

--- 本进程是否自动开桌面：nil 还没见过 FM / true 待开 / false 不再自动开
local want_auto_open = nil

--- FM 在桌面之下停留的空目录（KOReader 数据目录下的 ko-empty，不存在则创建）。
---@return string
local function emptyDir()
    local path = require("datastorage"):getDataDir() .. "/ko-empty"
    require("libs/libkoreader-lfs").mkdir(path)
    return path
end

--- 启动即开桌面时 FM 改列空目录：FM 在 init 里同步列出整个书库目录，
--- 慢存储冷缓存下要几分钟，期间界面白屏无响应。必须在 FM setupLayout 之前调用（插件 init 里）。
---@param plugin BookPlugin
function Desktop.startInDataDir(plugin)
    if plugin.ui.document or want_auto_open ~= nil or not require("menu").openOnStart() then return end
    plugin.ui.root_path = emptyDir()
end

--- 阅读中回桌面：重建 FM 同样只列空目录，并还原 lastdir（不改用户的原生起始目录）。
---@return table FileManager 实例
function Desktop.ensureFileManager()
    local FileManager = require("apps/filemanager/filemanager")
    if not FileManager.instance then
        local lastdir = G_reader_settings:readSetting("lastdir")
        FileManager:showFiles(emptyDir())
        G_reader_settings:saveSetting("lastdir", lastdir)
    end
    return FileManager.instance
end

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
