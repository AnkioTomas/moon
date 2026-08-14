--[[--
Book 桌面壳 — 顶栏 + 底栏 + Tab 内容拼装。
  页逻辑在 home / library / store / insight / settings；本文件只做窗体与手势。

@module koplugin.book.ui.desktop
--]]

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen

local Home = require("ui.desktop.home")
local Library = require("ui.desktop.library")
local StorePage = require("ui.desktop.store")
local Insight = require("ui.desktop.insight")
local Settings = require("ui.desktop.settings")
local Detail = require("ui.desktop.detail")
local Image = require("ui.components.image")
local TopBar = require("ui.components.topbar")
local BottomBar = require("ui.components.bottombar")
local UI = require("ui.components.bookui")
local BookStore = require("book.store")

local Desktop = InputContainer:extend{
    name = "book_desktop",
    covers_fullscreen = true,
    plugin = nil,
    source = nil,
    tab = "home",
    filter = nil,
}

--- 当前 tab 不在 tabs 列表中则回退 home（换源 / 能力变化后调用）。
---@param self table
local function clampTab(self)
    for _, t in ipairs(self._tabs) do
        if t.id == self.tab then
            return
        end
    end
    self.tab = "home"
end

--- 初始化手势区与默认分页状态，立刻 rebuild。
function Desktop:init()
    self.filter = self.filter or {}
    self._tabs = BottomBar.tabs(self.source)
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.page = 1
    self.page_size = 12
    self.total = 0
    self.store_page = 1
    self.store_page_size = 12
    self.store_total = 0
    self.source_generation = self.source_generation or 0
    self.tab = self.tab or "home"
    clampTab(self)
    self._closed = false
    self.ges_events = {
        -- 顶栏纯展示：不注册 tap/swipe，避免误触关桌面或抢原生区
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
    self:rebuild()
    UIManager:nextTick(function()
        if not self._closed then
            self:scheduleClockTick()
        end
    end)
end

--- 内容区高度（扣除顶栏 + 底栏）。
---@return number
function Desktop:contentHeight()
    return math.max(1, Screen:getHeight() - UI.barH() - UI.topBarH())
end

--- 返回桌面全屏尺寸（必要时懒建 dimen）。
---@return table
function Desktop:getSize()
    if not self.dimen then
        self.dimen = Geom:new{
            x = 0, y = 0,
            w = Screen:getWidth(),
            h = Screen:getHeight(),
        }
    end
    return self.dimen
end

--- 传给各 Tab 的上下文：plugin / source / desktop / filter。
---@return table
function Desktop:ctx()
    return {
        width = self.dimen.w,
        height = self:contentHeight(),
        plugin = self.plugin,
        source = self.source,
        desktop = self,
        filter = self.filter,
    }
end

--- 底栏点击：按 x 落点切换 Tab。
---@param _ any
---@param ges table|nil
---@return boolean
function Desktop:onTapBar(_, ges)
    if not ges or not ges.pos then return false end
    local tabs = BottomBar.tabs(self.source)
    self._tabs = tabs
    local bh = UI.barH()
    if ges.pos.y < self.dimen.h - bh then return false end
    local idx = math.floor(ges.pos.x * #tabs / self.dimen.w) + 1
    if idx < 1 then idx = 1 end
    if idx > #tabs then idx = #tabs end
    self:switchTab(tabs[idx].id)
    return true
end

--- 内容区左右滑：图书馆/书城翻页（不消费底栏区）。
---@param _ any
---@param ges_ev table|nil
---@return boolean
function Desktop:onSwipe(_, ges_ev)
    if type(ges_ev) ~= "table" or not ges_ev.direction then return true end
    if ges_ev.pos and ges_ev.pos.y >= self.dimen.h - UI.barH() then return true end
    local direction = BD.flipDirectionIfMirroredUILayout(ges_ev.direction)
    -- 不下滑关闭：内容区任意 south 都关太容易误触；退出走设置
    if self.tab == "library" then
        if direction == "west" then
            Library.gotoPage(self, self.page + 1)
        elseif direction == "east" then
            Library.gotoPage(self, self.page - 1)
        end
    elseif self.tab == "store" then
        if direction == "west" then
            StorePage.gotoPage(self, (self.store_page or 1) + 1)
        elseif direction == "east" then
            StorePage.gotoPage(self, (self.store_page or 1) - 1)
        end
    end
    return true
end

--- 切换底栏 Tab 并重建；进页时清对应缓存状态。
---@param id string
function Desktop:switchTab(id)
    if id == "library" and self.tab ~= "library" then
        self._library_state = nil
        self.page = self.page or 1
    end
    if id == "store" and self.tab ~= "store" then
        self._store_state = nil
        self.store_page = self.store_page or 1
    end
    if id == "home" then
        self._home_state = nil
        self._home_loaded = false
        self._home_reading_page = 1
        self:scheduleClockTick()
    end
    if id == "settings" then
        self._settings_page = 1
        self._cache_size_label = nil
    end
    if id == "stats" then
        self._insight_ui_page = 1
    end
    self.tab = id
    self:rebuild()
end

--- 数据源切换：取消在飞请求、清各 Tab 缓存、回退不支持的 Tab 并重建。
---@param source BookSource|nil
function Desktop:sourceChanged(source)
    self.source_generation = (self.source_generation or 0) + 1
    for _, key in ipairs({
        "_home_fetch_cancel",
        "_library_fetch_cancel",
        "_store_fetch_cancel",
        "_insight_fetch_cancel",
    }) do
        local job = self[key]
        if type(job) == "table" and type(job.cancel) == "function" then
            pcall(function() job:cancel() end)
        end
        self[key] = nil
    end
    Image.abortPending()
    self.source = source
    self._tabs = BottomBar.tabs(source)
    clampTab(self)
    self._home_state = nil
    self._home_loaded = false
    self._library_state = nil
    self._store_state = nil
    self._insight_state = nil
    self._insight_loaded = false
    self.filter = nil
    self:rebuild()
end

--- 重建顶栏 + 内容 + 底栏。
function Desktop:rebuild()
    pcall(function()
        require("utils.font").applyCurrent()
    end)
    local ok, err = pcall(function()
        local sw = Screen:getWidth()
        local sh = Screen:getHeight()
        self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }

        local content
        if self.tab == "home" then
            content = Home.page(self)
        elseif self.tab == "library" then
            content = Library.page(self)
        elseif self.tab == "store" then
            content = StorePage.page(self)
        elseif self.tab == "stats" then
            content = Insight.page(self)
        else
            content = Settings.build(self)
        end
        local content_h = self:contentHeight()
        local top_h = UI.topBarH()
        if content.dimen then
            content.dimen.w = sw
            content.dimen.h = content_h
        else
            content.dimen = Geom:new{ w = sw, h = content_h }
        end
        content.overlap_offset = { 0, top_h }

        local top = TopBar.build()
        top.overlap_offset = { 0, 0 }

        local bar = BottomBar.build(self)
        bar.overlap_offset = { 0, sh - UI.barH() }

        local root = OverlapGroup:new{
            dimen = Geom:new{ w = sw, h = sh },
            content,
            top,
            bar,
        }
        self[1] = FrameContainer:new{
            bordersize = 0,
            padding = 0,
            margin = 0,
            background = Blitbuffer.COLOR_WHITE,
            root,
        }
    end)
    if not ok then
        logger.err("book desktop rebuild failed:", err)
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{ text = _("桌面构建失败:\n") .. tostring(err) })
        return
    end
    UIManager:setDirty(self, "full")
end

--- 只换顶栏并区域刷新；分钟心跳禁止整页 rebuild / full flash。
function Desktop:refreshTopBar()
    local root = self[1] and self[1][1]
    if not root or not root[2] then
        self:rebuild()
        return
    end
    local ok, err = pcall(function()
        local top = TopBar.build()
        top.overlap_offset = { 0, 0 }
        if root[2].free then
            root[2]:free()
        end
        root[2] = top
    end)
    if not ok then
        logger.err("book desktop refreshTopBar failed:", err)
        self:rebuild()
        return
    end
    UIManager:setDirty(self, "ui", Geom:new{
        x = 0,
        y = 0,
        w = Screen:getWidth(),
        h = UI.topBarH(),
    })
end

--- 按分钟对齐调度顶栏时钟刷新。
function Desktop:scheduleClockTick()
    if self._clock_tick then
        UIManager:unschedule(self._clock_tick)
    end
    self._clock_tick = function()
        if self._closed then return end
        self:refreshTopBar()
        self:scheduleClockTick()
    end
    local delay = math.max(1, 61 - (tonumber(os.date("%S")) or 0))
    UIManager:scheduleIn(delay, self._clock_tick)
end

--- 打开书籍详情浮层。
---@param book table
function Desktop:showDetail(book)
    if self.detail then
        UIManager:close(self.detail)
        self.detail = nil
    end
    BookStore.remember(book)
    local desk = self
    self.detail = Detail:new{
        book = book,
        plugin = self.plugin,
        source = self.source,
        desktop = self,
        covers_fullscreen = true,
        close_callback = function()
            desk.detail = nil
            if not desk._closed then
                UIManager:setDirty(desk, "full")
            end
        end,
    }
    UIManager:show(self.detail)
    UIManager:setDirty(self.detail, "full")
end

--- 关闭桌面：取消在飞请求、中止图片下载、回 FM。
---@return boolean
function Desktop:onClose()
    logger.info("book.desktop close")
    self._closed = true
    if self._clock_tick then
        UIManager:unschedule(self._clock_tick)
        self._clock_tick = nil
    end
    for _, key in ipairs({
        "_home_fetch_cancel",
        "_library_fetch_cancel",
        "_store_fetch_cancel",
        "_insight_fetch_cancel",
        "_cache_size_job",
        "_cache_clear_job",
        "_local_cleanup_job",
    }) do
        local job = self[key]
        if type(job) == "table" and type(job.cancel) == "function" then
            pcall(function() job:cancel() end)
        elseif type(job) == "function" then
            pcall(job)
        end
        self[key] = nil
    end
    self._home_refresh_pending = false
    self._library_refresh_pending = false
    self._insight_refresh_pending = false
    self._store_refresh_pending = false
    self._settings_refresh_pending = false
    self.ges_events = nil
    Image.abortPending()
    if self.detail then
        pcall(function()
            self.detail._closed = true
            self.detail.ges_events = nil
            UIManager:close(self.detail)
        end)
        self.detail = nil
    end
    if self._filter_root then
        pcall(UIManager.close, UIManager, self._filter_root)
        self._filter_root = nil
    end
    if self._filter_menu then
        pcall(UIManager.close, UIManager, self._filter_menu)
        self._filter_menu = nil
    end
    UIManager:close(self)
    if self.close_callback then
        pcall(self.close_callback)
    end
    -- 全屏桌面盖过 FM 后，必须强制整屏刷新，否则顶栏点击会踩到残影/野指针
    UIManager:nextTick(function()
        UIManager:setDirty("all", "full")
        local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
        if ok and FileManager and FileManager.instance then
            UIManager:setDirty(FileManager.instance, "full")
        end
    end)
    return true
end

--- Widget 关闭回调：停时钟、清手势、中止图片下载。
function Desktop:onCloseWidget()
    self._closed = true
    if self._clock_tick then
        UIManager:unschedule(self._clock_tick)
        self._clock_tick = nil
    end
    self.ges_events = nil
    Image.abortPending()
end

return Desktop
