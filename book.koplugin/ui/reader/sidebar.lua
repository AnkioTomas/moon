--[[--
阅读页左侧栏：书籍 / 目录 / 阅读字体 / 书摘 / X-Ray / 阅读票根，右侧网状遮罩压暗正文。
阅读字体仅在文档支持换字体时出现，复用字体选择器菜单。
书籍页右上角关闭按钮退出本书；票根页复用锁屏票根并可分享。

目录、书摘、X-Ray 不自己画：借用各自原有入口弹出的全屏 Menu（KOReader 原生目录的折叠/搜索、
原生书签列表、连续章节全书笔记、X-Ray 分栏菜单），把尺寸压进侧栏、改挂到侧栏窗口上。

入口：
  - 阅读页右滑，范围由设置 reader.sidebar_gesture 决定：
    edge（缺省）左缘起手右滑 / full 任意位置右滑（顶替原生「右滑上一页」）/ off 关闭；
  - Dispatcher 动作 book_reader_sidebar，可在 KOReader 手势管理里绑任意手势。
书籍页左右滑切页（列表页的左右滑归 Menu 翻页），底栏切页；点遮罩、返回键或菜单关闭键关闭。

@module koplugin.book.ui.reader.sidebar
--]]

require("l10n").apply()

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local MeshMask = require("ui.components.meshmask")
local PageStrip = require("ui.components.pagestrip")
local UI = require("ui.components.bookui")
local MoonSettings = require("utils.settings")
local _ = require("gettext")

--- 左缘起手区占屏宽比例。
local EDGE_RATIO = 0.15
--- 侧栏占屏宽比例。
local PANEL_RATIO = 0.85

---@class BookReaderSidebar : InputContainer
---@field ui table ReaderUI
---@field snapshot ReaderSessionSnapshot
---@field tabs string[]
---@field tab integer
---@field menus table<string, table|false> 借来的 Menu；false = 入口没弹 Menu
---@field native_closes fun()[] 借来菜单的原 close_callback，侧栏关闭时各调一次做原生清理
---@field panel_w integer
---@field ticket BookSidebarTicket|nil 首次进入票根页时生成，关侧栏取消
---@field font_job table|nil 字体列表拉取中（{ cancel }），关侧栏取消
---@field closed boolean|nil 已关闭：迟到的异步回调不再重画
local Sidebar = InputContainer:extend{}

local TITLES = {
    info = _("书籍"),
    toc = _("目录"),
    font = _("阅读字体"),
    notes = _("书摘"),
    xray = _("X-Ray"),
    ticket = _("阅读票根"),
}

--- 各列表页的原有入口（与快捷面板同一条路径，整书 / 连续章节的分流都在入口内部）。
local OPENERS = {
    toc = function(ui) require("ui.panel.actions.reader.toc").run({ ui = ui }) end,
    notes = function(ui) ui.bookmark:onShowBookmark() end,
    xray = function(ui) require("xray.ui").openMain(ui) end,
}

--- 执行 open()，截下其中第一次 UIManager:show，期间 Menu 缺省宽高改成 width × height。
--- 调用方都不给 Menu 传宽高（全屏菜单），所以缺省值决定尺寸。
--- 截到的不是 Menu（如只弹了一条提示）就照常显示，返回 nil。
---@param open fun()
---@param width integer
---@param height integer
---@return table|nil
local function borrowMenu(open, width, height)
    local Menu = require("ui/widget/menu")
    local show = UIManager.show
    local captured
    UIManager.show = function(um, widget, ...)
        if captured == nil then
            captured = widget
            return
        end
        return show(um, widget, ...)
    end
    Menu.width, Menu.height = width, height
    -- 无论 open 是否抛错都要还原全局，错误原样再抛。
    local ok, err = pcall(open)
    Menu.width, Menu.height = nil, nil
    UIManager.show = show
    if not ok then error(err, 0) end
    if not captured then return nil end
    -- 原生目录 / 书签把 Menu 套在全屏 CenterContainer 里；其余直接 show Menu。
    local menu = captured.item_table and captured or captured[1]
    if menu and menu.item_table then return menu end
    show(UIManager, captured)
    return nil
end

--- 窄菜单页脚：KOReader 翻页条四个间隔写死宽度，窄面板里排不下会居中溢出（左侧被裁），
--- 每次刷新页码后等量收窄；只有一页时整行藏起，少一层底栏。
---@param menu table
local function fitPager(menu)
    local update = menu.updatePageInfo
    local spacer = menu.page_info_spacer
    local full = spacer.width
    local chevs = {
        menu.page_info_left_chev, menu.page_info_right_chev,
        menu.page_info_first_chev, menu.page_info_last_chev,
    }
    local function fit()
        local single = menu.page_num <= 1
        for _, chev in ipairs(chevs) do chev:showHide(not single) end
        -- Button:hide 只对图标按钮生效，页码文字只能清空；多页时原生 updatePageInfo 会写回
        if single then menu.page_info_text:setText("") end
        spacer.width = full
        menu.page_info:resetLayout()
        local over = menu.page_info:getSize().w - menu.inner_dimen.w
        if over > 0 then
            spacer.width = math.max(0, full - math.ceil(over / 4))
            menu.page_info:resetLayout()
        end
    end
    function menu:updatePageInfo(...)
        update(self, ...)
        fit()
    end
    fit()
end

function Sidebar:init()
    local screen = Device.screen:getSize()
    self.dimen = Geom:new{ x = 0, y = 0, w = screen.w, h = screen.h }
    self.panel_w = math.floor(screen.w * PANEL_RATIO)
    self.tabs = { "info", "toc" }
    if require("utils.font").supportsReader(self.ui) then
        self.tabs[#self.tabs + 1] = "font"
    end
    self.tabs[#self.tabs + 1] = "notes"
    if MoonSettings.get("reader").book_xray_enabled ~= false then
        self.tabs[#self.tabs + 1] = "xray"
    end
    self.tabs[#self.tabs + 1] = "ticket"
    self.tab = 1
    self.menus = {}
    self.native_closes = {}
    self.ges_events = {
        TapSidebar = { GestureRange:new{ ges = "tap", range = self.dimen } },
        SwipeSidebar = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self:render()
end

--- 列表页：首次进入时借菜单并改挂到侧栏；之后复用同一个（保留折叠状态和页码）。
---@param id string
---@param width integer
---@param height integer
---@return table|nil
function Sidebar:menuFor(id, width, height)
    if self.menus[id] == nil then
        self:adopt(id, borrowMenu(function() OPENERS[id](self.ui) end, width, height))
    end
    return self.menus[id] or nil
end

--- 借来的菜单改挂到侧栏：选中条目 / 关闭键都经 close_callback 关侧栏。
---@param id string
---@param menu table|nil
function Sidebar:adopt(id, menu)
    if menu then
        self.native_closes[#self.native_closes + 1] = menu.close_callback
        menu.close_callback = function() self:onClose() end
        menu.show_parent = self
        fitPager(menu)
    end
    self.menus[id] = menu or false
end

--- 字体页：选择器自己的入口会先弹加载提示，借不到菜单；这里自己拉列表，拉到后借
--- FontPicker.show 的菜单并刷新本页。选中字体即应用到当前文档（Menu 选中后关侧栏）。
---@param width integer
---@param height integer
---@return table|nil
function Sidebar:fontMenu(width, height)
    if self.menus.font == nil and not self.font_job then
        local job = require("utils.font").listAsync(false, function(items)
            self.font_job = nil
            if items then
                local opts = require("ui.panel.actions.reader.font").pickerOpts(self.ui)
                self:adopt("font", borrowMenu(function()
                    require("ui.components.fontpicker").show(opts, items)
                end, width, height))
            else
                self.menus.font = false
            end
            -- 可能同步回调（缓存命中），推迟到下一 tick 再重画
            UIManager:nextTick(function()
                if self.closed or self.tabs[self.tab] ~= "font" then return end
                self:render()
                UIManager:setDirty(self, "ui")
            end)
        end)
        if self.menus.font == nil then self.font_job = job end
    end
    return self.menus.font or nil
end

--- 票根首次进入时生成（每次打开侧栏重画一张，进度和今日统计跟着变）；出图后刷新本页。
---@return BookSidebarTicket
function Sidebar:ticketFor()
    if not self.ticket then
        local ticket
        ticket = require("ui.reader.sidebar.ticket").new(self.snapshot, function()
            -- 可能在 new 里同步回调，推迟到下一 tick，别在 render 里嵌套 render
            UIManager:nextTick(function()
                if self.ticket ~= ticket or self.tabs[self.tab] ~= "ticket" then return end
                self:render()
                UIManager:setDirty(self, "ui")
            end)
        end)
        self.ticket = ticket
    end
    return self.ticket
end

--- 书籍页关闭按钮：先关侧栏，再关书回月读桌面。
function Sidebar:exitBook()
    self:onClose()
    require("ui.panel.native").closeToDesktop(self.ui)
end

function Sidebar:render()
    local h = self.dimen.h
    local id = self.tabs[self.tab]
    local rule_h = UI.line()
    local body_h = h - PageStrip.bandH() - rule_h
    -- FrameContainer:getSize 只认内容尺寸，不认 width/height；内容区必须自己定死宽高，
    -- 否则翻页条跟着内容上浮、面板盖不满整屏。
    local body
    if id == "info" then
        local pad = UI.pagePad()
        local inner_w, inner_h = self.panel_w - pad * 2, body_h - pad * 2
        body = FrameContainer:new{
            bordersize = 0,
            padding = pad,
            background = Blitbuffer.COLOR_WHITE,
            OverlapGroup:new{
                dimen = Geom:new{ w = inner_w, h = inner_h },
                require("ui.reader.sidebar.info").build(self.snapshot, inner_w, inner_h, self,
                    function() self:exitBook() end),
            },
        }
    elseif id == "ticket" then
        body = FrameContainer:new{
            bordersize = 0,
            padding = 0,
            background = Blitbuffer.COLOR_WHITE,
            OverlapGroup:new{
                dimen = Geom:new{ w = self.panel_w, h = body_h },
                self:ticketFor():widget(self.panel_w, body_h),
            },
        }
    else
        local menu, status
        if id == "font" then
            menu = self:fontMenu(self.panel_w, body_h)
            status = self.font_job and _("正在加载字体列表…") or _("字体列表加载失败")
        else
            menu = self:menuFor(id, self.panel_w, body_h)
        end
        body = OverlapGroup:new{
            dimen = Geom:new{ w = self.panel_w, h = body_h },
            menu or FrameContainer:new{
                bordersize = 0,
                background = Blitbuffer.COLOR_WHITE,
                width = self.panel_w,
                height = body_h,
                status and CenterContainer:new{
                    dimen = Geom:new{ w = self.panel_w, h = body_h },
                    UI.mutedText(status, self.panel_w - UI.pagePad() * 2, 14),
                } or VerticalGroup:new{},
            },
        }
    end
    local panel = VerticalGroup:new{
        align = "left",
        body,
        LineWidget:new{
            dimen = Geom:new{ w = self.panel_w, h = rule_h },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        },
        PageStrip.widget{
            width = self.panel_w,
            page = self.tab,
            pages = #self.tabs,
            center = "title",
            title = TITLES[id],
            on_prev = function() self:goTab(self.tab - 1) end,
            on_next = function() self:goTab(self.tab + 1) end,
        },
    }
    self[1] = OverlapGroup:new{
        allow_mirroring = false,
        dimen = Geom:new{ w = self.dimen.w, h = h },
        MeshMask.widget{ width = self.dimen.w, height = h },
        HorizontalGroup:new{
            align = "top",
            panel,
            LineWidget:new{
                dimen = Geom:new{ w = UI.line() * 2, h = h },
                background = Blitbuffer.COLOR_BLACK,
            },
        },
    }
end

---@param tab integer
function Sidebar:goTab(tab)
    if tab < 1 or tab > #self.tabs or tab == self.tab then return end
    self.tab = tab
    self:render()
    UIManager:setDirty(self, "ui")
end

--- 子控件（菜单、翻页按钮）先收点击；落到这里的只剩空白处，遮罩区关闭。
function Sidebar:onTapSidebar(_, ges)
    if ges.pos.x >= self.panel_w then self:onClose() end
    return true
end

--- 列表页的滑动已被 Menu 收走（翻页 / 下滑关闭），到这里的是书籍页或遮罩上的滑动。
function Sidebar:onSwipeSidebar(_, ges)
    if ges.pos.x >= self.panel_w then
        self:onClose()
    elseif ges.direction == "west" then
        self:goTab(self.tab + 1)
    elseif ges.direction == "east" then
        self:goTab(self.tab - 1)
    end
    return true
end

function Sidebar:onClose()
    UIManager:close(self, "ui")
    return true
end

--- 原生 close_callback 里有状态清理（如 ReaderBookmark.bookmark_menu 置空），关侧栏时补跑。
function Sidebar:onCloseWidget()
    local closes = self.native_closes
    self.native_closes = {}
    for _, close in ipairs(closes) do close() end
    self.closed = true
    if self.font_job then
        self.font_job.cancel()
        self.font_job = nil
    end
    if self.ticket then
        self.ticket:cancel()
        self.ticket = nil
    end
end

--- 打开侧栏；没有阅读会话（书还没就绪）时不接手。
---@param ui table ReaderUI
---@return boolean
function Sidebar.open(ui)
    local snapshot = require("ui.reader.session").current()
    if not snapshot then return false end
    UIManager:show(Sidebar:new{ ui = ui, snapshot = snapshot }, "ui")
    return true
end

--- 阅读页右滑入口：优先于原生翻页 swipe；不满足设置时返回 false 交还原生翻页。
---@param ui table ReaderUI
---@param ges table
---@return boolean
function Sidebar.onReaderSwipe(ui, ges)
    if ges.direction ~= "east" then return false end
    local mode = MoonSettings.get("reader").sidebar_gesture or "edge"
    if mode == "off" then return false end
    if mode == "edge" and ges.pos.x > Device.screen:getWidth() * EDGE_RATIO then return false end
    return Sidebar.open(ui)
end

---@param ui table ReaderUI
function Sidebar.install(ui)
    if ui._book_sidebar_touch then return end
    ui._book_sidebar_touch = true
    ui:registerTouchZones({ {
        id = "book_sidebar_swipe",
        ges = "swipe",
        screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
        overrides = { "paging_swipe", "rolling_swipe" },
        handler = function(ges) return Sidebar.onReaderSwipe(ui, ges) end,
    } })
end

return Sidebar
