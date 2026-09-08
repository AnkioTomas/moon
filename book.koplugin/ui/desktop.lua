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
  | BottomBar  首页|图书馆|[书城]|[统计]|设置      |
  +-----------------------------------------------+
  手势：底栏 tap 切 Tab；内容区左右滑转给当前页；顶栏点源名换源、点其他区域或下滑开快捷面板。

  生命周期由 main.lua 驱动，不继承 ui/lifecycle.lua（Desktop 已经是 InputContainer）：
    onCreate → onStart → onResume
    onPause → onStop → onDestroy

  KOReader 自己的手势 / 关窗走 onSwipe / onTapBar / onClose。
  Desktop:onEvent 只广播；换源先改自己的 source/tab。
  先画壳（白内容 + 顶栏 + 底栏），不填页。页在 onResume / rebuild 里自己刷内容槽。
  详情走 Detail.open，设置子页走 Settings:showSub。

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
local OverlapGroup = require("ui/widget/overlapgroup")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")
local logger = require("utils.log")
local Perf = require("utils.perf")
local _ = require("gettext")
local Screen = Device.screen

local Home = require("ui.desktop.home")
local Library = require("ui.desktop.library")
local StorePage = require("ui.desktop.store")
local Insight = require("ui.desktop.insight")
local Settings = require("ui.desktop.settings")
local TopBar = require("ui.components.topbar")
local BottomBar = require("ui.components.bottombar")
local UI = require("ui.components.bookui")

---@class BookDesktop : InputContainer
---@field plugin BookPlugin|nil
---@field source BookSource|nil
---@field tab string
---@field filter table|nil
---@field lifecycle Lifecycle
---@field home BookHome
---@field library BookLibrary
---@field store BookStorePage
---@field insight BookInsight
---@field settings BookSettings
---@field topbar BookTopBar
---@field bottombar BookBottomBar
---@field _tabs table[]
---@field source_generation number
local Desktop = InputContainer:extend{
    name = "book_desktop",
    covers_fullscreen = true,
    plugin = nil,
    source = nil,
    tab = "home",
    filter = nil,
}

---@class BookDesktopCtx
---@field width number
---@field height number
---@field plugin BookPlugin|nil
---@field source BookSource|nil
---@field desktop BookDesktop
---@field filter table|nil

local TAB_COMPONENT = { home = "home", library = "library", store = "store", stats = "insight", settings = "settings" }
local CHILDREN = { "topbar", "bottombar", "home", "library", "store", "insight", "settings" }


local function notify(child, method, ...)
    if child and child[method] then child[method](child, ...) end
end

local function broadcast(self, method, ...)
    for _, key in ipairs(CHILDREN) do notify(self[key], method, ...) end
end

--- 按数据源能力生成 Desktop 底栏 Tab。
---@param source table|nil
---@return table
local function desktopTabs(source)
    local tabs = {
        { id = "home", text = _("首页"), icon = "home" },
        { id = "library", text = _("图书馆"), icon = "local_library" },
    }
    local caps = source and source.capabilities and source:capabilities() or {}
    if caps.store or (source and type(source.importBookAsync) == "function") then
        table.insert(tabs, { id = "store", text = _("书城"), icon = "storefront" })
    end
    if caps.insight then
        table.insert(tabs, { id = "stats", text = _("统计"), icon = "bar_chart" })
    end
    table.insert(tabs, { id = "settings", text = _("设置"), icon = "settings" })
    return tabs
end

--- 当前 tab 不在 tabs 列表中则回退 home（换源 / 能力变化后调用）。
---@param self BookDesktop
local function clampTab(self)
    for _, t in ipairs(self._tabs) do
        if t.id == self.tab then
            return
        end
    end
    self.tab = "home"
end


--- 换源：取消窗口任务、更新 Tab，再广播给各页自己复位。
---@param self BookDesktop
---@param source BookSource|nil
local function applySource(self, source)
    self.source = source
    self._tabs = desktopTabs(source)
    broadcast(self, "onEvent", "source_changed", source)
    self:switchTab("home")
end

--- 只广播。换源改的是 Desktop 自己的 source/tab，不是替孩子分流。
---@param event string|table
---@param payload any
function Desktop:onEvent(event, payload)
    if self.lifecycle.state == "Destroy" then return end
    if event == "source_changed" then
        applySource(self, payload)
        return
    end
    broadcast(self, "onEvent", event, payload)
end

--- 初始化手势区与默认分页状态，再 onCreate 画出第一帧。
function Desktop:init()
    self.lifecycle = Lifecycle.attach(self)
    self._tabs = desktopTabs(self.source)
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.tab = self.tab or "home"
    self.home = Home.new(self)
    self.library = Library.new(self)
    self.store = StorePage.new(self)
    self.insight = Insight.new(self)
    self.settings = Settings.new(self)
    self.topbar = TopBar:new()
    self.topbar.desktop = self
    self.bottombar = BottomBar.new()
    clampTab(self)
    self.ges_events = {
        SwipeTopBar = {
            GestureRange:new{
                ges = "swipe",
                range = function()
                    return Geom:new{
                        x = 0,
                        y = 0,
                        w = Screen:getWidth(),
                        h = UI.topBarH(),
                    }
                end,
            },
        },
        TapTopBar = {
            GestureRange:new{
                ges = "tap",
                range = function()
                    return Geom:new{
                        x = 0,
                        y = 0,
                        w = Screen:getWidth(),
                        h = UI.topBarH(),
                    }
                end,
            },
        },
        TapBar = {
            GestureRange:new{
                ges = "tap",
                range = function()
                    local h = UI.barH()
                    return Geom:new{
                        x = 0,
                        y = Screen:getHeight() - h,
                        w = Screen:getWidth(),
                        h = h,
                    }
                end,
            },
        },
        Swipe = {
            GestureRange:new{
                ges = "swipe",
                range = function()
                    return Geom:new{
                        x = 0,
                        y = UI.topBarH(),
                        w = Screen:getWidth(),
                        h = Screen:getHeight() - UI.barH() - UI.topBarH(),
                    }
                end,
            },
        },
    }
    self:onCreate()
end

--- 创建：挂长期对象，先画壳，当前页自己刷内容。
function Desktop:onCreate()
    broadcast(self, "onCreate")
    self:rebuild()
    notify(self[TAB_COMPONENT[self.tab]], "onResume")
end

--- 启动：通知顶栏开始心跳。
function Desktop:onStart()
    broadcast(self, "onStart")
end

--- 恢复工作：通知顶栏与当前页。同一轮事件只处理一次。
function Desktop:onResume()
    broadcast(self, "onResume")

    -- todo source tasks, such as http sync or download

end

--- 暂停：
function Desktop:onPause()
    broadcast(self, "onPause")
end

--- 停止：通知所有子组件停工。
function Desktop:onStop()
    broadcast(self, "onStop")
end

--- 取消在飞请求，不拆窗体。
function Desktop:onCancel()
    broadcast(self, "onCancel")
end

--- 销毁：通知子组件销毁，再拆手势和详情浮层。
function Desktop:onDestroy()
    broadcast(self, "onDestroy")
    self.ges_events = nil
    local plugin = self.plugin
    if plugin and plugin.desktop == self then
        plugin.desktop = nil
    end
end

--- 顶栏向下滑：打开 KOReader 原生菜单的 Book 快捷 Tab。
---@param _ any
---@param ges_ev table|nil
---@return boolean
function Desktop:onSwipeTopBar(_, ges_ev)
    return self.topbar:onSwipe(_, ges_ev)
end

--- 顶栏点击：缓存指标打开任务列表，源名区域切换数据源，其余区域打开原生快捷面板 Tab。
---@param _ any
---@param ges table|nil
---@return boolean
function Desktop:onTapTopBar(_, ges)
    return self.topbar:onTap(_, ges)
end

--- 内容区高度（扣除顶栏 + 底栏）。
---@return number
function Desktop:contentHeight()
    return math.max(1, Screen:getHeight() - UI.barH() - UI.topBarH())
end

--- 传给各 Tab 的上下文：plugin / source / desktop / filter。
---@return BookDesktopCtx
function Desktop:ctx()
    return {
        width = self.dimen.w,
        height = self:contentHeight(),
        plugin = self.plugin,
        source = self.source,
        desktop = self,
        filter = self.library.filter,
    }
end

--- 底栏点击：按 x 落点切换 Tab。
---@param _ any
---@param ges table|nil
---@return boolean
function Desktop:onTapBar(_, ges)
    if not ges or not ges.pos then return false end
    local tabs = self._tabs or desktopTabs(self.source)
    local bh = UI.barH()
    if ges.pos.y < self.dimen.h - bh then return false end
    local idx = math.floor(ges.pos.x * #tabs / self.dimen.w) + 1
    if idx < 1 then idx = 1 end
    if idx > #tabs then idx = #tabs end
    self:switchTab(tabs[idx].id)
    return true
end

--- 内容区左右滑：转给当前页，桌面不认图书馆/书城。
---@param _ any
---@param ges_ev table|nil
---@return boolean
function Desktop:onSwipe(_, ges_ev)
    if type(ges_ev) ~= "table" or not ges_ev.direction then return true end
    if ges_ev.pos and ges_ev.pos.y >= self.dimen.h - UI.barH() then return true end
    self:onEvent("swipe", {
        direction = BD.flipDirectionIfMirroredUILayout(ges_ev.direction),
    })
    return true
end

--- 切换底栏 Tab。页数据跟着页对象走；内容由页 rebuild。
---@param id string
function Desktop:switchTab(id)
    if not TAB_COMPONENT[id] then return end
    local changed = self.tab ~= id
    if changed then notify(self[TAB_COMPONENT[self.tab]], "onPause") end
    self.tab = id
    notify(self[TAB_COMPONENT[id]], "onResume", changed)
    self:rebuild()
end

--- 没壳：只画三个槽。有壳：只换内容槽和底栏，顶栏不动。
function Desktop:rebuild()
    local started_at = Perf.now()
    local root = self[1] and self[1][1]
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self._tabs = desktopTabs(self.source)
    clampTab(self)
    local ok, err = pcall(function()
        local sw, sh = Screen:getWidth(), Screen:getHeight()
        local bar = self.bottombar:build(self._tabs, self.tab)
        bar.overlap_offset = { 0, sh - UI.barH() }
        if root then
            local page = self[TAB_COMPONENT[self.tab]]
            local content = self.tab == "settings" and page:build() or page:content()
            local h = self:contentHeight()
            if content.dimen then
                content.dimen.w = sw
                content.dimen.h = h
            else
                content.dimen = Geom:new{ w = sw, h = h }
            end
            content.overlap_offset = { 0, UI.topBarH() }
            local old = root[1]
            root[1] = content
            if old and old.free then old:free() end
            old = root[3]
            root[3] = bar
            if old and old.free then old:free() end
            return
        end
        pcall(function() require("utils.font").applyCurrent() end)
        -- FrameContainer:getSize 固定读 self[1]，空壳不能用无孩子的 FrameContainer。
        -- 外层已经是白底，这里只要占住内容槽尺寸。
        local content = Widget:new{ dimen = Geom:new{ w = sw, h = self:contentHeight() } }
        content.overlap_offset = { 0, UI.topBarH() }
        local top = self.topbar:build()
        top.overlap_offset = { 0, 0 }
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
    end)
    logger.dbg("book.perf desktop.rebuild", Perf.elapsedMs(started_at), "ms",
        self.tab or "-", ok and "ok" or "failed")
    if not ok then
        logger.err("book desktop rebuild failed:", err)
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{ text = _("桌面构建失败:\n") .. tostring(err) })
    end
    UIManager:setDirty(self, "ui")
end

--- KOReader 关窗入口，不是生命周期。关窗前走完 pause/stop/destroy。
---@return boolean
function Desktop:onClose()
    logger.info("book.desktop close")
    if not self.lifecycle:Alive() then return true end
    self:onPause()
    self:onStop()
    self:onDestroy()
    UIManager:close(self, "ui")
    return true
end

--- Widget 关闭回调：若尚未走完生命周期，补齐停止与销毁。
function Desktop:onCloseWidget()
    if not self.lifecycle:Alive() then return end
    self:onPause()
    self:onStop()
    self:onDestroy()
end

return Desktop
