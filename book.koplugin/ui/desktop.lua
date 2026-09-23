--[[--
月读桌面壳 — 顶栏 + 底栏 + Tab 内容拼装。
  页逻辑在 home / library / store / insight / settings；本文件只做编排、转发、手势。

布局（OverlapGroup 叠层）：
  +-----------------------------------------------+
  | TopBar（时钟 · 源名 · 剩余内存/存储/Wi‑Fi/亮度/电量） |
  |-----------------------------------------------|
  |                                               |
  |          Tab 内容区（contentHeight）           |
  |                                               |
  |-----------------------------------------------|
  | BottomBar  首页|图书馆|[Z站]|[统计]|设置       |
  +-----------------------------------------------+
  手势：底栏 tap 切 Tab；内容区左右滑转给当前页；顶栏点源名换源、点其他区域或下滑开快捷面板。
  Lifecycle：Create → Resume ↔ Pause → Destroy；Resume 只打 topbar+当前 Tab；详情浮层自挂 Lifecycle。

@module koplugin.book.ui.desktop
--]]

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Lifecycle = require("ui.lifecycle")
local View = require("ui.view")
local OverlapGroup = require("ui/widget/overlapgroup")
local UIManager = require("ui/uimanager")
local logger = require("utils.log")
local Perf = require("utils.perf")
local _ = require("gettext")
local Screen = Device.screen

local Home = require("ui.desktop.home")
local Library = require("ui.desktop.library")
local StorePage = require("ui.desktop.store")
local Insight = require("ui.desktop.insight")
local Settings = require("ui.desktop.settings")
local TopBar = require("ui.views.topbar")
local BottomBar = require("ui.views.bottombar")
local UI = require("ui.components.bookui")

---@class BookDesktop : InputContainer, LifecycleOwner
---@field plugin BookPlugin|nil
---@field source BookSource|nil
---@field tab string
---@field lifecycle Lifecycle
---@field home BookHome
---@field library BookLibrary
---@field store BookStorePage
---@field insight BookInsight
---@field settings BookSettings
---@field topbar BookTopBar
---@field bottombar BookBottomBar
---@field detail BookDetailPage|nil
---@field settings_overlay BookSettingsOverlay|nil
---@field source_generation integer|nil 换源代数，页内请求防串
---@field _tabs table[]
---@field _closed boolean|nil 桌面已关闭，异步回调短路
---@field _cache_size_label string|nil 设置页缓存体积文案
---@field _cache_size_job CancelHandle|nil 缓存体积测量任务
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

local PAGES = { home = true, library = true, store = true, insight = true, settings = true }
local CHILDREN = { "topbar", "bottombar", "home", "library", "store", "insight", "settings" }


--- 调用指定子视图的事件或生命周期方法；不存在的接收者直接跳过。
---@param child table|nil 接收事件的子视图；nil 时跳过
---@param method string 子视图上的方法名
---@param ... any 原样传给接收方法的参数
---@return nil
local function notify(child, method, ...)
    if child and child[method] then child[method](child, ...) end
end

--- 按组件注册顺序把同一事件和参数分发给子视图。
---@param self BookDesktop 拥有子视图的父实例
---@param method string 子视图上的方法名
---@param ... any 原样传给接收方法的参数
---@return nil
local function broadcast(self, method, ...)
    for _, key in ipairs(CHILDREN) do notify(self[key], method, ...) end
end

--- 当前底栏 Tab 对应的页对象。
---@param self BookDesktop 当前桌面实例
---@return table|nil
local function tabPage(self)
    return self[self.tab]
end

--- 取当前页内容 widget。页实现了 updateView 则走它，否则用已有 widget / build。
---@param self BookDesktop 当前桌面实例
---@return table
local function tabContent(self)
    local page = tabPage(self)
    if not page then return {} end
    if page.updateView then return page:updateView() end
    return page.widget or page:build()
end

--- 按开关生成 Desktop 底栏 Tab（Z-Library 默认关）。
---@param source table|nil 书籍所属数据源实例
---@return table
local function desktopTabs(source)
    local tabs = {
        { id = "home", text = _("首页"), icon = "home" },
        { id = "library", text = _("图书馆"), icon = "local_library" },
    }
    if require("utils.settings").zlibEnabled() then
        tabs[#tabs + 1] = { id = "store", text = _("Z站"), icon = "storefront" }
    end
    local caps = source and source.capabilities and source:capabilities() or {}
    if caps.insight then
        tabs[#tabs + 1] = { id = "insight", text = _("统计"), icon = "bar_chart" }
    end
    tabs[#tabs + 1] = { id = "settings", text = _("设置"), icon = "settings" }
    return tabs
end

--- 当前 tab 不在 tabs 列表中则回退 home（换源 / 能力变化后调用）。
---@param self BookDesktop 当前视图或布局实例
---@return nil
local function clampTab(self)
    for _, t in ipairs(self._tabs) do
        if t.id == self.tab then
            return
        end
    end
    self.tab = "home"
end

--- 换源：更新 Tab，广播给各页自己复位，再回到首页。
---@param self BookDesktop 当前视图或布局实例
---@param source BookSource|nil 书籍所属数据源实例
---@return nil
local function applySource(self, source)
    self.source = source
    self._tabs = desktopTabs(source)
    broadcast(self, "onEvent", "source_changed", source)
    self:switchTab("home")
end

--- 构造全宽手势区；y / h 是取当前屏幕坐标的函数。
---@param ges string KOReader 手势名，如 tap / swipe
---@param y fun():number 手势区顶部 y
---@param h fun():number 手势区高度
---@return table
local function gesRange(ges, y, h)
    return {
        GestureRange:new{
            ges = ges,
            range = function()
                return Geom:new{ x = 0, y = y(), w = Screen:getWidth(), h = h() }
            end,
        },
    }
end

--- 把 widget 放到 OverlapGroup 指定偏移；传入 w 时同时写入 dimen。
---@param widget table 参与叠层的子控件
---@param x number 相对 OverlapGroup 的 x 偏移
---@param y number 相对 OverlapGroup 的 y 偏移
---@param w number|nil 内容区宽度；省略则只改 overlap_offset
---@param h number|nil 内容区高度，与 w 成对使用
---@return table widget 原样返回，便于链式安装
local function overlapAt(widget, x, y, w, h)
    if w then
        if widget.dimen then
            widget.dimen.w, widget.dimen.h = w, h
        else
            widget.dimen = Geom:new{ w = w, h = h }
        end
    end
    widget.overlap_offset = { x, y }
    return widget
end

--- 只广播。换源改的是 Desktop 自己的 source/tab，不是替孩子分流。
---@param event string|table 父组件转发的事件名称或事件对象
---@param payload any 与事件一起传入的数据
---@return nil
function Desktop:onEvent(event, payload)
    if self.lifecycle.state == "Destroy" then return end
    if event == "source_changed" then
        applySource(self, payload)
        return
    end
    broadcast(self, "onEvent", event, payload)
end

--- KOReader 电源 / 网络 / 前光事件 → 统一 onEvent 名。
---@return nil
function Desktop:onCharging()
    self:onEvent("Charging")
end
--- 将停止充电事件转发给桌面子组件。
---@return nil
function Desktop:onNotCharging()
    self:onEvent("NotCharging")
end
--- 将网络连接成功事件转发给桌面子组件。
---@return nil
function Desktop:onNetworkConnected()
    self:onEvent("NetworkConnected")
end
--- 将网络断开事件转发给桌面子组件。
---@return nil
function Desktop:onNetworkDisconnected()
    self:onEvent("NetworkDisconnected")
end
--- 将前光状态变化事件转发给桌面子组件。
---@return nil
function Desktop:onFrontlightStateChanged()
    self:onEvent("FrontlightStateChanged")
end

--- 系统 Resume 广播进桌面（窗口在栈上时）。
---@return nil
function Desktop:onResumeEvent()
    if self.lifecycle.state == "Destroy" then return end
    self:onResume()
end

--- 初始化手势区与默认分页状态，再 onCreate 画出第一帧。
---@return nil
function Desktop:init()
    self.lifecycle = Lifecycle.attach(self)
    self.view = View.attach(self)
    self._tabs = desktopTabs(self.source)
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.tab = self.tab or "home"
    self.home = Home:new{ desktop = self, name = "home" }
    self.library = Library:new{ desktop = self, name = "library" }
    self.store = StorePage:new{ desktop = self, name = "store" }
    self.insight = Insight:new{ desktop = self, name = "insight" }
    self.settings = Settings:new{ desktop = self }
    self.topbar = TopBar:new{ desktop = self, name = "topbar" }
    self.bottombar = BottomBar:new{ host = self, name = "bottombar" }
    clampTab(self)
    self.ges_events = {
        SwipeTopBar = gesRange("swipe", function() return 0 end, UI.topBarH),
        TapTopBar = gesRange("tap", function() return 0 end, UI.topBarH),
        TapBar = gesRange("tap", function() return Screen:getHeight() - UI.barH() end, UI.barH),
        Swipe = gesRange("swipe", UI.topBarH, function()
            return Screen:getHeight() - UI.barH() - UI.topBarH()
        end),
    }
    self:onCreate()
end

function Desktop:onCreate()
    broadcast(self, "onCreate")
    self:build()
end

function Desktop:onResume()
    notify(self.topbar, "onResume")
    notify(tabPage(self), "onResume")
    -- 插件更新检查走桌面 Resume，不在插件 init / 网络回调里抢跑。
    local root = self.plugin and self.plugin.path
    if root then
        require("update.init").autoCheck(root)
    end
end

function Desktop:onPause()
    broadcast(self, "onPause")
end

function Desktop:onCancel()
    broadcast(self, "onCancel")
end

function Desktop:onDestroy()
    local overlay = self.settings_overlay
    if overlay then overlay:onClose() end
    broadcast(self, "onDestroy")
    self.ges_events = nil
    local plugin = self.plugin
    if plugin and plugin.desktop == self then
        plugin.desktop = nil
    end
end

--- 顶栏向下滑：打开 KOReader 原生菜单的 Book 快捷 Tab。
---@param _ any 事件框架传入但本实现不使用的参数
---@param ges_ev table|nil KOReader 手势数据，含方向和位置
---@return boolean
function Desktop:onSwipeTopBar(_, ges_ev)
    return self.topbar:onSwipe(_, ges_ev)
end

--- 顶栏点击：缓存指标打开任务列表，源名区域切换数据源，其余区域打开原生快捷面板 Tab。
---@param _ any 事件框架传入但本实现不使用的参数
---@param ges table|nil KOReader 手势数据，含方向和位置
---@return boolean
function Desktop:onTapTopBar(_, ges)
    return self.topbar:onTap(_, ges)
end

--- 内容区高度（扣除顶栏 + 底栏）。
---@return number
function Desktop:contentHeight()
    return math.max(1, Screen:getHeight() - UI.barH() - UI.topBarH())
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

--- 底栏点击：按 x 落点切换 Tab。
---@param _ any 事件框架传入但本实现不使用的参数
---@param ges table|nil KOReader 手势数据，含方向和位置
---@return boolean
function Desktop:onTapBar(_, ges)
    if not ges or not ges.pos then return false end
    if ges.pos.y < self.dimen.h - UI.barH() then return false end
    local tabs = self._tabs
    local idx = math.floor(ges.pos.x * #tabs / self.dimen.w) + 1
    if idx < 1 then idx = 1 elseif idx > #tabs then idx = #tabs end
    self:switchTab(tabs[idx].id)
    return true
end

--- 内容区左右滑：只转给当前页。
---@param _ any 事件框架传入但本实现不使用的参数
---@param ges_ev table|nil KOReader 手势数据，含方向和位置
---@return boolean
function Desktop:onSwipe(_, ges_ev)
    if type(ges_ev) ~= "table" or not ges_ev.direction then return true end
    if ges_ev.pos and ges_ev.pos.y >= self.dimen.h - UI.barH() then return true end
    notify(tabPage(self), "onEvent", "swipe", {
        direction = BD.flipDirectionIfMirroredUILayout(ges_ev.direction),
    })
    return true
end

--- 切换底栏 Tab。页数据跟着页对象走；壳用 updateView 换槽。
---@param id string 底栏 Tab 标识，须在 PAGES 内
---@return nil
function Desktop:switchTab(id)
    if not PAGES[id] then return end
    local changed = self.tab ~= id
    if changed then notify(tabPage(self), "onPause") end
    self.tab = id
    notify(tabPage(self), "onResume", changed)
    self:updateView()
end

--- 一生一次：拼顶栏 + 当前页 + 底栏壳。
---@return table|nil widget 根内容树；已有壳时返回原根
function Desktop:build()
    if self[1] then return self[1] end
    local started_at = Perf.now()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self._tabs = desktopTabs(self.source)
    clampTab(self)
    local content = overlapAt(tabContent(self), 0, UI.topBarH(), sw, self:contentHeight())
    local top = self.topbar.widget or self.topbar:build()
    top.overlap_offset = { 0, 0 }
    local bar = overlapAt(self.bottombar:updateView({ tabs = self._tabs, active = self.tab }), 0, sh - UI.barH())
    self[1] = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        OverlapGroup:new{
            dimen = Geom:new{ w = sw, h = sh },
            content, top, bar,
        },
    }
    self.view:registerRegion("content", self[1][1], 1, function()
        return Geom:new{ x = 0, y = UI.topBarH(), w = Screen:getWidth(), h = self:contentHeight() }
    end)
    self.view:registerRegion("topbar", self[1][1], 2, function()
        return Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = UI.topBarH() }
    end)
    self.view:registerRegion("bottombar", self[1][1], 3, function()
        return Geom:new{ x = 0, y = Screen:getHeight() - UI.barH(), w = Screen:getWidth(), h = UI.barH() }
    end)
    logger.dbg("book.perf desktop.build", Perf.elapsedMs(started_at), "ms", self.tab)
    UIManager:setDirty(self, "ui")
    return self[1]
end

--- 刷新：只换内容槽和底栏，顶栏不动（已有壳）；无壳则走 build。
---@return table|nil widget 尚无骨架时返回构建结果，否则原地更新不返回值
function Desktop:updateView()
    local root = self[1] and self[1][1]
    if not root then
        return self:build()
    end
    local started_at = Perf.now()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local resized = self.dimen.w ~= sw or self.dimen.h ~= sh
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self._tabs = desktopTabs(self.source)
    clampTab(self)
    root.dimen.w, root.dimen.h = sw, sh
    local top = self.topbar.widget
    if resized or (top and top:getSize().h ~= UI.topBarH()) then
        self.topbar:updateView()
    end
    local bar = overlapAt(self.bottombar:updateView({ tabs = self._tabs, active = self.tab }), 0, sh - UI.barH())
    local content = overlapAt(tabContent(self), 0, UI.topBarH(), sw, self:contentHeight())
    self.view:replaceRegion("content", content, root[1] and root[1]._view_owner)
    self.view:replaceRegion("bottombar", bar)
    -- 底栏根 widget 身份不变，replaceRegion 会 early-return；选中态已在内部换掉，必须显式 dirty。
    if self.lifecycle:uiReady() then
        self.view:dirty("bottombar")
    end
    logger.dbg("book.perf desktop.updateView", Perf.elapsedMs(started_at), "ms", self.tab)
    if resized and self.lifecycle:uiReady() then UIManager:setDirty(self, "ui") end
    if self.settings_overlay then
        self.settings_overlay:updateView()
    end
end

--- KOReader 关窗入口，不是生命周期。关窗前 Destroy 会按状态补齐 Pause/Stop。
---@return boolean
function Desktop:onClose()
    if self.lifecycle.state == "Destroy" then return true end
    self:onDestroy()
    logger.flush()
    UIManager:close(self, "ui")
    return true
end

--- Widget 关闭回调：若尚未销毁，走 Destroy（含停止系列补全）。
---@return nil
function Desktop:onCloseWidget()
    if self.lifecycle.state == "Destroy" then return end
    self:onDestroy()
    logger.flush()
end

return Desktop
