--[[--
月读桌面壳 — 顶栏 + 底栏 + Tab 内容拼装。
  页逻辑在 home / library / store / insight / settings；本文件只做编排、转发、手势。

布局（OverlapGroup 叠层）：
  +-----------------------------------------------+
  | TopBar（时钟 · 源名 · 剩余内存/存储/Wi‑Fi/亮度/电量） |
  |-----------------------------------------------|
  |          Tab 内容区（contentHeight）           |
  |-----------------------------------------------|
  | BottomBar  首页|图书馆|[书城]|[统计]|设置      |
  +-----------------------------------------------+
  手势：底栏 tap 切 Tab；内容区左右滑转给当前页；顶栏点源名换源、点其他区域或下滑开快捷面板。

  生命周期：init/onCreate；打开时 onStart+onResume；休眠 Pause+Stop。
  唤醒只靠 KOReader 广播 Resume（窗口栈上自己收）。
  Desktop 是 InputContainer，组合 attach Lifecycle。
  build 一生一次建壳；updateView 换内容槽/底栏。
  onEvent 只广播；换源改自己的 source/tab。Resume 只打顶栏和当前页。

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

---@class BookDesktop : InputContainer
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
---@field _tabs table[]
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

local function notify(child, method, ...)
    if child and child[method] then child[method](child, ...) end
end

local function broadcast(self, method, ...)
    for _, key in ipairs(CHILDREN) do notify(self[key], method, ...) end
end

local function tabPage(self)
    return self[self.tab]
end

local function tabContent(self)
    local page = tabPage(self)
    if page.updateView then return page:updateView() end
    return page.widget or page:build()
end

---@param source table|nil
---@return table
local function desktopTabs(source)
    local tabs = {
        { id = "home", text = _("首页"), icon = "home" },
        { id = "library", text = _("图书馆"), icon = "local_library" },
    }
    local caps = source and source.capabilities and source:capabilities() or {}
    if caps.store or (source and type(source.importBookAsync) == "function") then
        tabs[#tabs + 1] = { id = "store", text = _("书城"), icon = "storefront" }
    end
    if caps.insight then
        tabs[#tabs + 1] = { id = "insight", text = _("统计"), icon = "bar_chart" }
    end
    tabs[#tabs + 1] = { id = "settings", text = _("设置"), icon = "settings" }
    return tabs
end

local function clampTab(self)
    for _, t in ipairs(self._tabs) do
        if t.id == self.tab then return end
    end
    self.tab = "home"
end

local function applySource(self, source)
    self.source = source
    self._tabs = desktopTabs(source)
    broadcast(self, "onEvent", "source_changed", source)
    self:switchTab("home")
end

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

---@param event string|table
---@param payload any
---@return nil
function Desktop:onEvent(event, payload)
    if self.lifecycle.state == "Destroy" then return end
    if event == "source_changed" then
        applySource(self, payload)
        return
    end
    broadcast(self, "onEvent", event, payload)
end

function Desktop:onCharging() self:onEvent("Charging") end
function Desktop:onNotCharging() self:onEvent("NotCharging") end
function Desktop:onNetworkConnected() self:onEvent("NetworkConnected") end
function Desktop:onNetworkDisconnected() self:onEvent("NetworkDisconnected") end
function Desktop:onFrontlightStateChanged() self:onEvent("FrontlightStateChanged") end

function Desktop:onResumeEvent()
    if self.lifecycle.state == "Destroy" then return end
    self:onResume()
end

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

function Desktop:onStart() broadcast(self, "onStart") end
function Desktop:onPause() broadcast(self, "onPause") end
function Desktop:onStop() broadcast(self, "onStop") end
function Desktop:onCancel() broadcast(self, "onCancel") end

function Desktop:onResume()
    notify(self.topbar, "onResume")
    notify(tabPage(self), "onResume")
end

function Desktop:onDestroy()
    broadcast(self, "onDestroy")
    self.ges_events = nil
    local plugin = self.plugin
    if plugin and plugin.desktop == self then
        plugin.desktop = nil
    end
end

function Desktop:onSwipeTopBar(_, ges_ev)
    return self.topbar:onSwipe(_, ges_ev)
end

function Desktop:onTapTopBar(_, ges)
    return self.topbar:onTap(_, ges)
end

---@return number
function Desktop:contentHeight()
    return math.max(1, Screen:getHeight() - UI.barH() - UI.topBarH())
end

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

function Desktop:onTapBar(_, ges)
    if not ges or not ges.pos then return false end
    if ges.pos.y < self.dimen.h - UI.barH() then return false end
    local tabs = self._tabs
    local idx = math.floor(ges.pos.x * #tabs / self.dimen.w) + 1
    if idx < 1 then idx = 1 elseif idx > #tabs then idx = #tabs end
    self:switchTab(tabs[idx].id)
    return true
end

function Desktop:onSwipe(_, ges_ev)
    if type(ges_ev) ~= "table" or not ges_ev.direction then return true end
    if ges_ev.pos and ges_ev.pos.y >= self.dimen.h - UI.barH() then return true end
    notify(tabPage(self), "onEvent", "swipe", {
        direction = BD.flipDirectionIfMirroredUILayout(ges_ev.direction),
    })
    return true
end

---@param id string
---@return nil
function Desktop:switchTab(id)
    if not PAGES[id] then return end
    local changed = self.tab ~= id
    if changed then notify(tabPage(self), "onPause") end
    self.tab = id
    notify(tabPage(self), "onResume", changed)
    self:updateView()
end

---@return table|nil
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

---@return table|nil
function Desktop:updateView()
    local root = self[1] and self[1][1]
    if not root then return self:build() end
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
    logger.dbg("book.perf desktop.updateView", Perf.elapsedMs(started_at), "ms", self.tab)
    if resized and self.lifecycle:uiReady() then UIManager:setDirty(self, "ui") end
end

function Desktop:onClose()
    if self.lifecycle.state == "Destroy" then return true end
    self:onDestroy()
    logger.flush()
    UIManager:close(self, "ui")
    return true
end

function Desktop:onCloseWidget()
    if self.lifecycle.state == "Destroy" then return end
    self:onDestroy()
    logger.flush()
end

return Desktop
