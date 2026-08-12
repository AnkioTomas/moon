--[[--
Book 桌面壳 — 底栏：图书馆 / [书城] / 首页 / 统计 / 设置
  书城仅当当前 source.capabilities.store 时插入

@module koplugin.book.ui.desktop
--]]

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen

local Home = require("ui.home")
local Library = require("ui.library")
local Store = require("ui.store")
local Insight = require("ui.insight")
local Settings = require("ui.settings")
local Detail = require("ui.detail")
local Cover = require("ui.components.cover")
local UI = require("ui.components.bookui")
local MoonSettings = require("moon.settings")
local Cache = require("moon.cache")

local function buildTabs(source)
    local tabs = {
        { id = "library", text = _("图书馆"), icon = "library.svg" },
    }
    local caps = source and source.capabilities and source:capabilities() or {}
    if caps.store then
        table.insert(tabs, { id = "store", text = _("书城"), icon = "view.svg" })
    end
    table.insert(tabs, { id = "home", text = _("首页"), icon = "home.svg" })
    table.insert(tabs, { id = "stats", text = _("统计"), icon = "stats.svg" })
    table.insert(tabs, { id = "settings", text = _("设置"), icon = "settings.svg" })
    return tabs
end

local Desktop = InputContainer:extend{
    name = "book_desktop",
    covers_fullscreen = true,
    plugin = nil,
    source = nil,
    tab = "home",
    filter = nil,
}


function Desktop:init()
    self.filter = self.filter or {}
    self._tabs = buildTabs(self.source)
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.page = 1
    self.page_size = 12
    self.total = 0
    self.store_page = 1
    self.store_page_size = 12
    self.store_total = 0
    self.tab = self.tab or "home"
    -- 若当前 tab 因能力变化不可用，回首页
    local ok_tab = false
    for _, t in ipairs(self._tabs) do
        if t.id == self.tab then ok_tab = true break end
    end
    if not ok_tab then
        self.tab = "home"
    end
    self._closed = false
    self.ges_events = {
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
                        x = 0, y = 0,
                        w = Screen:getWidth(),
                        h = Screen:getHeight() - UI.barH(),
                    }
                end,
            },
        },
    }
    self:rebuild()
    local desk = self
    Cover.setIdleHandler(function()
        if desk._closed then return end
        if desk.detail and not desk.detail._closed and desk.detail.rebuild then
            desk.detail:rebuild()
            UIManager:setDirty(desk.detail, "ui")
        end
        if desk.tab == "home" then
            desk:requestHomeRefresh()
        elseif desk.tab == "library" then
            desk:requestLibraryRefresh()
        elseif desk.tab == "store" then
            desk:requestStoreRefresh()
        elseif desk.tab == "stats" then
            desk:requestInsightRefresh()
        end
    end)
    UIManager:nextTick(function()
        if not self._closed and self.tab == "home" then
            self:scheduleClockTick()
        end
    end)
end

function Desktop:tabs()
    self._tabs = buildTabs(self.source)
    return self._tabs
end

function Desktop:contentHeight()
    return math.max(1, Screen:getHeight() - UI.barH())
end

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

function Desktop:ctx()
    local source = self.source
    return {
        width = self.dimen.w,
        height = self:contentHeight(),
        plugin = self.plugin,
        source = source,
        desktop = self,
        filter = self.filter,
    }
end

function Desktop:buildBottomBar()
    local tabs = self:tabs()
    local sw = Screen:getWidth()
    local bh = UI.barH()
    local icon_sz = UI.iconSz()
    local icon_dir = UI.iconDir()
    local cell_w = math.floor(sw / #tabs)
    local row = HorizontalGroup:new{ align = "center" }
    for _, tab in ipairs(tabs) do
        local active = self.tab == tab.id
        local icon
        local ok, img = pcall(function()
            -- SVG：传 width/height 且 scale_factor 保持 nil，按目标尺寸渲染
            return ImageWidget:new{
                file = icon_dir .. tab.icon,
                width = icon_sz,
                height = icon_sz,
                alpha = true,
            }
        end)
        if ok and img then
            icon = img
        else
            icon = TextWidget:new{
                text = "•",
                face = UI.face("cfont", 18),
                fgcolor = active and Blitbuffer.COLOR_BLACK or UI.dim(),
            }
        end
        local label = TextWidget:new{
            text = tab.text,
            face = UI.face("xx_smallinfofont", 12),
            fgcolor = active and Blitbuffer.COLOR_BLACK or UI.muted(),
        }
        table.insert(row, CenterContainer:new{
            dimen = Geom:new{ w = cell_w, h = bh },
            VerticalGroup:new{
                align = "center",
                VerticalSpan:new{ width = UI.sz(6) },
                icon,
                VerticalSpan:new{ width = UI.sz(2) },
                label,
            },
        })
    end
    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = sw, h = bh },
        VerticalGroup:new{
            align = "left",
            LineWidget:new{
                background = UI.rule(),
                dimen = Geom:new{ w = sw, h = UI.line() },
            },
            row,
        },
    }
end

function Desktop:onTapBar(_, ges)
    if not ges or not ges.pos then return false end
    local tabs = self:tabs()
    local bh = UI.barH()
    if ges.pos.y < self.dimen.h - bh then return false end
    local idx = math.floor(ges.pos.x * #tabs / self.dimen.w) + 1
    if idx < 1 then idx = 1 end
    if idx > #tabs then idx = #tabs end
    self:switchTab(tabs[idx].id)
    return true
end

function Desktop:onSwipe(_, ges_ev)
    if type(ges_ev) ~= "table" or not ges_ev.direction then return true end
    if ges_ev.pos and ges_ev.pos.y >= self.dimen.h - UI.barH() then return true end
    local direction = BD.flipDirectionIfMirroredUILayout(ges_ev.direction)
    if direction == "south" then
        self:onClose()
        return true
    end
    if self.tab == "library" then
        if direction == "west" then
            self:gotoLibraryPage(self.page + 1)
        elseif direction == "east" then
            self:gotoLibraryPage(self.page - 1)
        end
    elseif self.tab == "store" then
        if direction == "west" then
            self:gotoStorePage((self.store_page or 1) + 1)
        elseif direction == "east" then
            self:gotoStorePage((self.store_page or 1) - 1)
        end
    end
    return true
end

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
        self:scheduleClockTick()
    end
    -- 统计页：保留内存态；过期由 insight TTL / 手动刷新处理
    self.tab = id
    self:rebuild()
end

function Desktop:rebuild()
    local ok, err = pcall(function()
        local sw = Screen:getWidth()
        local sh = Screen:getHeight()
        self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }

        local content
        if self.tab == "home" then
            content = self:buildHome()
        elseif self.tab == "library" then
            content = self:buildLibrary()
        elseif self.tab == "store" then
            content = self:buildStore()
        elseif self.tab == "stats" then
            content = self:buildInsight()
        else
            content = Settings.build(self)
        end

        local content_h = self:contentHeight()
        if content.dimen then
            content.dimen.w = sw
            content.dimen.h = content_h
        else
            content.dimen = Geom:new{ w = sw, h = content_h }
        end
        content.overlap_offset = { 0, 0 }

        local bar = self:buildBottomBar()
        bar.overlap_offset = { 0, sh - UI.barH() }

        local root = OverlapGroup:new{
            dimen = Geom:new{ w = sw, h = sh },
            content,
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

function Desktop:buildHome()
    local h = self:contentHeight()
    local w = Screen:getWidth()
    if not self._home_loaded then
        UIManager:nextTick(function()
            if self._closed or self.tab ~= "home" then return end
            Home.fetch(self)
        end)
        return FrameContainer:new{
            bordersize = 0,
            padding = 0,
            background = Blitbuffer.COLOR_WHITE,
            dimen = Geom:new{ w = w, h = h },
            CenterContainer:new{
                dimen = Geom:new{ w = w, h = h },
                TextWidget:new{
                    text = _("加载主页…"),
                    face = UI.face("cfont", 18),
                    fgcolor = UI.muted(),
                },
            },
        }
    end
    return Home.build(self:ctx(), self._home_state or {})
end

function Desktop:buildInsight()
    local h = self:contentHeight()
    local w = Screen:getWidth()
    if not self._insight_loaded then
        UIManager:nextTick(function()
            if self._closed or self.tab ~= "stats" then return end
            Insight.fetch(self)
        end)
        return FrameContainer:new{
            bordersize = 0,
            padding = 0,
            background = Blitbuffer.COLOR_WHITE,
            dimen = Geom:new{ w = w, h = h },
            CenterContainer:new{
                dimen = Geom:new{ w = w, h = h },
                TextWidget:new{
                    text = _("加载统计…"),
                    face = UI.face("cfont", 18),
                    fgcolor = UI.muted(),
                },
            },
        }
    end
    return Insight.build(self)
end

function Desktop:requestInsightRefresh()
    if self._closed or self.tab ~= "stats" then return end
    if self._insight_refresh_pending then return end
    self._insight_refresh_pending = true
    UIManager:scheduleIn(0.5, function()
        self._insight_refresh_pending = false
        if self._closed or self.tab ~= "stats" or not self._insight_loaded then return end
        self:rebuild()
    end)
end

function Desktop:scheduleClockTick()
    local s = MoonSettings.get()
    if (s.home_header or "clock") == "hitokoto" then
        return
    end
    if self._clock_scheduled then return end
    self._clock_scheduled = true
    UIManager:scheduleIn(60, function()
        self._clock_scheduled = false
        if self._closed or self.tab ~= "home" or not self._home_loaded then return end
        -- 仅在已加载且空闲时轻量刷新；避开封面下载高峰
        if self._home_fetching then
            self:scheduleClockTick()
            return
        end
        self:rebuild()
        self:scheduleClockTick()
    end)
end

function Desktop:requestHomeRefresh()
    if self._closed or self.tab ~= "home" then return end
    if self._home_refresh_pending then return end
    self._home_refresh_pending = true
    UIManager:scheduleIn(0.5, function()
        self._home_refresh_pending = false
        if self._closed or self.tab ~= "home" then return end
        self:rebuild()
    end)
end

function Desktop:syncLibraryPageSize()
    local m = Library.gridMetrics(
        (self.dimen and self.dimen.w) or Screen:getWidth(),
        self:contentHeight()
    )
    local n = math.max(1, m.page_size or 1)
    if self.page_size ~= n then
        self.page_size = n
        local pages = math.max(1, math.ceil((self.total or 0) / n))
        if (self.page or 1) > pages then
            self.page = pages
            self._library_state = nil
        end
    end
    return self.page_size
end

function Desktop:libraryPages()
    local ps = self:syncLibraryPageSize()
    return math.max(1, math.ceil((self.total or 0) / ps))
end

function Desktop:gotoLibraryPage(page)
    local pages = self:libraryPages()
    page = math.max(1, math.min(pages, tonumber(page) or 1))
    if page == self.page and self._library_state and self._library_state.books then
        return
    end
    self.page = page
    self._library_state = nil
    self.tab = "library"
    self:rebuild()
end

function Desktop:buildLibrary()
    local prev_ps = self.page_size
    self:syncLibraryPageSize()
    if prev_ps and prev_ps ~= self.page_size then
        -- 字号/分辨率变了，容量变了，必须按新 pageSize 重拉
        self._library_state = nil
        local pages = self:libraryPages()
        if (self.page or 1) > pages then
            self.page = pages
        end
    end
    local state = self._library_state
    if not state then
        UIManager:nextTick(function()
            if self._closed or self.tab ~= "library" then return end
            Library.fetch(self)
        end)
    end
    local desk = self
    return Library.build(self:ctx(), state or {}, {
        page = self.page,
        pages = self:libraryPages(),
        total = self.total or 0,
        on_prev = function()
            desk:gotoLibraryPage(desk.page - 1)
        end,
        on_next = function()
            desk:gotoLibraryPage(desk.page + 1)
        end,
        on_first = function()
            desk:gotoLibraryPage(1)
        end,
        on_last = function()
            desk:gotoLibraryPage(desk:libraryPages())
        end,
    })
end

function Desktop:syncStorePageSize()
    self:syncLibraryPageSize()
    self.store_page_size = self.page_size
end

function Desktop:storePages()
    local ps = self.store_page_size or self.page_size or 1
    local total = self.store_total or 0
    return math.max(1, math.ceil(total / ps))
end

function Desktop:gotoStorePage(page)
    page = tonumber(page) or 1
    local pages = self:storePages()
    if page < 1 then page = 1 end
    if page > pages then page = pages end
    if page == self.store_page and self._store_state then
        return
    end
    self.store_page = page
    self._store_state = nil
    self:rebuild()
end

function Desktop:buildStore()
    local prev_ps = self.store_page_size
    self:syncStorePageSize()
    if prev_ps and prev_ps ~= self.store_page_size then
        self._store_state = nil
        local pages = self:storePages()
        if (self.store_page or 1) > pages then
            self.store_page = pages
        end
    end
    local state = self._store_state
    if not state then
        UIManager:nextTick(function()
            if self._closed or self.tab ~= "store" then return end
            Store.fetch(self)
        end)
    end
    local desk = self
    return Store.build(self:ctx(), state or {}, {
        page = self.store_page,
        pages = self:storePages(),
        total = self.store_total or 0,
        loading_text = _("加载书城…"),
        empty_text = _("书城暂无内容"),
        on_prev = function()
            desk:gotoStorePage((desk.store_page or 1) - 1)
        end,
        on_next = function()
            desk:gotoStorePage((desk.store_page or 1) + 1)
        end,
        on_first = function()
            desk:gotoStorePage(1)
        end,
        on_last = function()
            desk:gotoStorePage(desk:storePages())
        end,
    })
end

function Desktop:requestStoreRefresh()
    if self._closed or self.tab ~= "store" then return end
    if self._store_refresh_pending then return end
    self._store_refresh_pending = true
    UIManager:scheduleIn(0.6, function()
        self._store_refresh_pending = false
        if self._closed or self.tab ~= "store" then return end
        self:rebuild()
    end)
end

function Desktop:requestLibraryRefresh()
    if self._closed or self.tab ~= "library" then return end
    if self._library_refresh_pending then return end
    self._library_refresh_pending = true
    UIManager:scheduleIn(0.6, function()
        self._library_refresh_pending = false
        if self._closed or self.tab ~= "library" then return end
        self:rebuild()
    end)
end

function Desktop:showSearch()
    local dialog
    dialog = InputDialog:new{
        title = _("搜索书籍"),
        input = self.filter.search or "",
        input_hint = _("书名或作者"),
        buttons = {{
            {
                text = _("清除"),
                callback = function()
                    UIManager:close(dialog)
                    Library.applyExclusive(self, "search", "")
                end,
            },
            {
                text = _("取消"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("搜索"),
                is_enter_default = true,
                callback = function()
                    local q = dialog:getInputText() or ""
                    UIManager:close(dialog)
                    Library.applyExclusive(self, "search", q)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Desktop:clearLibraryFilters()
    self.filter = {}
    self.page = 1
    self._library_state = nil
    self.tab = "library"
    self:rebuild()
end

function Desktop:showDetail(book)
    if self.detail then
        UIManager:close(self.detail)
        self.detail = nil
    end
    Cache.remember(book)
    local desk = self
    self.detail = Detail:new{
        book = book,
        plugin = self.plugin,
        source = self.source,
        desktop = self,
        covers_fullscreen = true,
        close_callback = function()
            desk.detail = nil
        end,
    }
    UIManager:show(self.detail)
    UIManager:setDirty(self.detail, "full")
end

function Desktop:onClose()
    self._closed = true
    self._clock_scheduled = false
    self._home_refresh_pending = false
    self._library_refresh_pending = false
    self._insight_refresh_pending = false
    self.ges_events = nil
    Cover.stopAll()
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

function Desktop:onCloseWidget()
    self._closed = true
    self.ges_events = nil
    Cover.stopAll()
end

return Desktop
