--[[--
阅读页左侧栏：书籍 / 目录 / 阅读字体 / 书签 / 书摘 / X-Ray / 阅读票根 / 统计，右侧网状遮罩压暗正文。
阅读字体仅在文档支持换字体时出现，复用字体选择器菜单。
页面清单在 setting.lua 的 TABS，用户顺序 sidebar_tab_order（Setting.orderedTabs）；用户隐藏的页记在 sidebar_hidden_tabs。
书籍页右上角关闭按钮退出本书；票根页复用锁屏票根并可分享。

目录、书签、书摘、X-Ray、字体不自己画：借用各自原有入口弹出的全屏列表（KOReader 原生目录的折叠/搜索、
原生书签列表按类型过滤——书签页只看页书签、书摘页只看划线/笔记；X-Ray 分栏、字体选择器用主题 List），
把尺寸压进侧栏、改挂到侧栏窗口上。

入口：
  - 阅读页右滑，范围由设置 sidebar_gesture（settings/sidebar.lua）决定：
    edge（缺省）左缘起手右滑 / full 任意位置右滑（顶替原生「右滑上一页」）/ off 关闭；
  - Dispatcher 动作 book_reader_sidebar，可在 KOReader 手势管理里绑任意手势。
书籍页左右滑切页（列表页的左右滑归 Menu 翻页），底栏图标直达各页；点遮罩、返回键或菜单关闭键关闭。

@module koplugin.book.features.sidebar.init
--]]

require("l10n").apply()

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Box = require("ui.themes.widgets.box")
local Modal = require("ui.themes.widgets.modal")
local Guard = require("ui.guard")
local Tabbar = require("ui.themes.widgets.tabbar")
local Text = require("ui.themes.widgets.text")
local Theme = require("ui.themes")
local MoonSettings = require("utils.settings")
local Setting = require("features.sidebar.setting")
local _ = require("gettext")

--- 左缘起手区占屏宽比例。
local EDGE_RATIO = 0.15
--- 侧栏占屏宽比例。
local PANEL_RATIO = 0.85

---@class BookReaderSidebar : BookThemeModal
---@field ui table ReaderUI
---@field snapshot ReaderSessionSnapshot
---@field tabs string[] 显示的页 id，顺序同 Setting.orderedTabs
---@field bar_tabs table[] 与 tabs 一一对应的页定义，交给底栏
---@field tab integer
---@field menus table<string, table|false> 借来的 Menu；false = 入口没弹 Menu
---@field native_closes fun()[] 借来菜单的原 close_callback，侧栏关闭时各调一次做原生清理
---@field panel_w integer
---@field ticket BookSidebarTicket|nil 首次进入票根页时生成，关侧栏取消
---@field font_job table|nil 字体列表拉取中（{ cancel }），关侧栏取消
---@field font_items table[]|nil 两类字体共用的字体目录
---@field font_kind string 当前选择中文 chinese 或西文 western
---@field mixed_fonts boolean 开启时显示中西文字体切换
---@field closed boolean|nil 已关闭：迟到的异步回调不再重画
--- 用 Modal 的整屏遮罩，面板贴左缘盖住左侧部分（见 render 末尾）。
local Sidebar = Modal:extend{}

--- 按条件出现的页：字体页要文档能换字体，X-Ray 页要功能开着。
local AVAILABLE = {
    font = function(ui) return require("ui.fonts.reader").supports(ui) end,
    xray = function() return require("features.xray").available() end,
    stats = function() return require("features.sidebar.stats").available() end,
}

--- 打开原生书签列表并套上类型过滤。match_table 留到关侧栏再清，删改条目后重绘仍按该过滤。
---@param ui table
---@param filter table
local function openBookmarks(ui, filter)
    ui.bookmark.match_table = filter
    ui.bookmark:onShowBookmark()
end

--- 各列表页的原有入口（与快捷面板同一条路径，整书 / 连续章节的分流都在入口内部）。
local OPENERS = {
    toc = function(ui) require("features.panel.actions.reader.toc").run({ ui = ui }) end,
    bookmarks = function(ui) openBookmarks(ui, { bookmark = true }) end,
    notes = function(ui) openBookmarks(ui, { highlight = true, note = true }) end,
    xray = function(ui) require("features.xray.ui").openMain(ui) end,
}

--- 执行 open()，截下其中第一次 UIManager:show，期间 Menu / 主题 List 缺省宽高改成 width × height。
--- 调用方都不给它们传宽高（全屏列表），所以缺省值决定尺寸。
--- 截到的不是列表（如只弹了一条提示）就照常显示，返回 nil。
---@param open fun()
---@param width integer
---@param height integer
---@return table|nil
local function borrowMenu(open, width, height)
    local Menu = require("ui/widget/menu")
    local List = require("ui.themes.widgets.list")
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
    List.width, List.height = width, height
    -- 无论 open 是否抛错都要还原全局，错误原样再抛。
    local ok, err = pcall(open)
    Menu.width, Menu.height = nil, nil
    List.width, List.height = nil, nil
    UIManager.show = show
    if not ok then error(err, 0) end
    if not captured then return nil end
    -- 主题 List 直接可嵌；原生目录 / 书签把 Menu 套在全屏 CenterContainer 里，其余直接 show Menu。
    if captured.items then return captured end
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
        for _idx, chev in ipairs(chevs) do chev:showHide(not single) end
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
    Modal.init(self)
    self.panel_w = math.floor(self.dimen.w * PANEL_RATIO)
    local settings = MoonSettings.get("features.sidebar")
    local hidden = Setting.hiddenTabs(settings)
    self.tabs, self.bar_tabs = {}, {}
    for _idx, tab in ipairs(Setting.orderedTabs(settings)) do
        local available = AVAILABLE[tab.id]
        if not hidden[tab.id] and (not available or available(self.ui)) then
            self.tabs[#self.tabs + 1] = tab.id
            self.bar_tabs[#self.bar_tabs + 1] = tab
        end
    end
    -- 设置页不让全隐藏，但只留了条件页、条件又不满足时会空：退回书籍页
    if #self.tabs == 0 then
        self.tabs, self.bar_tabs = { "info" }, { Setting.TABS[1] }
    end
    self.tab = 1
    self.menus = {}
    self.font_kind = "chinese"
    self.mixed_fonts = MoonSettings.get("reader").mixed_fonts == true
    self.native_closes = {}
    self.ges_events.SwipeSidebar = { GestureRange:new{ ges = "swipe", range = self.dimen } }
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

--- 借来的列表改挂到侧栏：选中条目 / 关闭键都关侧栏（Menu 经 close_callback，主题 List 经 close）。
---@param id string
---@param menu table|nil
function Sidebar:adopt(id, menu)
    if menu then
        self.native_closes[#self.native_closes + 1] = menu.close_callback
        menu.close_callback = function() self:onClose() end
        menu.show_parent = self
        if menu.item_table then
            fitPager(menu)
        else
            menu.close = function() self:onClose() end
        end
    end
    self.menus[id] = menu or false
end

--- 字体页：共用一次目录加载，按中文 / 西文借用各自的字体选择器。
---@param width integer
---@param height integer
---@return table|nil
function Sidebar:fontMenu(width, height)
    if self.menus.font == nil and self.font_items then
        local opts = self.font_kind == "western"
            and require("ui.fonts.reader").westernPickerOpts(self.ui)
            or require("features.panel.actions.reader.font").pickerOpts(self.ui)
        self:adopt("font", borrowMenu(function()
            require("ui.widgets.fontpicker").show(opts, self.font_items)
        end, width, height))
    end
    if self.menus.font == nil and not self.font_job then
        local job = require("ui.fonts.catalog").listAsync(function(items)
            self.font_job = nil
            self.font_items = items
            if not items then self.menus.font = false end
            -- 可能同步回调（缓存命中），推迟到下一 tick 再重画
            UIManager:nextTick(require("ui.guard").wrap("sidebar font", function()
                if self.closed or self.tabs[self.tab] ~= "font" then return end
                self:render()
                UIManager:setDirty(self, "ui")
            end))
        end)
        if not self.font_items and self.menus.font == nil then self.font_job = job end
    end
    return self.menus.font or nil
end

--- 票根首次进入时生成（每次打开侧栏重画一张，进度和今日统计跟着变）；出图后刷新本页。
---@return BookSidebarTicket
function Sidebar:ticketFor()
    if not self.ticket then
        local ticket
        ticket = require("features.sidebar.ticket").new(self.snapshot, function()
            -- 可能在 new 里同步回调，推迟到下一 tick，别在 render 里嵌套 render
            UIManager:nextTick(require("ui.guard").wrap("sidebar ticket", function()
                if self.ticket ~= ticket or self.tabs[self.tab] ~= "ticket" then return end
                self:render()
                UIManager:setDirty(self, "ui")
            end))
        end)
        self.ticket = ticket
    end
    return self.ticket
end

--- 书籍页关闭按钮：先关侧栏，再关书回月读桌面。
function Sidebar:exitBook()
    self:onClose()
    require("desktop.reader_exit").closeToDesktop(self.ui)
end

function Sidebar:render()
    local h = self.dimen.h
    local id = self.tabs[self.tab]
    local t = Theme.current()
    local body_h = h - Tabbar.height()
    local surface = { bg = t.color.page }
    local body
    if id == "info" then
        local pad = Theme.px(t.space.lg)
        local inner_w, inner_h = self.panel_w - pad * 2, body_h - pad * 2
        body = Box:new{
            style = surface,
            width = self.panel_w,
            height = body_h,
            OverlapGroup:new{
                dimen = Geom:new{ w = inner_w, h = inner_h },
                require("features.sidebar.info").build(self.snapshot, inner_w, inner_h, self,
                    function() self:exitBook() end),
            },
        }
    elseif id == "stats" then
        local pad = Theme.px(t.space.lg)
        body = Box:new{
            style = surface,
            width = self.panel_w,
            height = body_h,
            OverlapGroup:new{
                dimen = Geom:new{ w = self.panel_w - pad * 2, h = body_h - pad * 2 },
                require("features.sidebar.stats").build(self.panel_w - pad * 2),
            },
        }
    elseif id == "ticket" then
        body = Box:new{
            style = surface,
            width = self.panel_w,
            height = body_h,
            OverlapGroup:new{
                dimen = Geom:new{ w = self.panel_w, h = body_h },
                self:ticketFor():widget(self.panel_w, body_h),
            },
        }
    else
        local menu, status
        local menu_h = body_h
        if id == "font" then
            if self.mixed_fonts then menu_h = body_h - Tabbar.height() end
            menu = self:fontMenu(self.panel_w, menu_h)
            status = self.font_job and _("正在加载字体列表…") or _("字体列表加载失败")
        else
            menu = self:menuFor(id, self.panel_w, body_h)
        end
        body = OverlapGroup:new{
            dimen = Geom:new{ w = self.panel_w, h = menu_h },
            menu or Box:new{
                style = surface,
                width = self.panel_w,
                height = menu_h,
                status and Text.line("body", status, {
                    width = self.panel_w - Theme.px(t.space.lg) * 2,
                    color = t.color.muted,
                }) or nil,
            },
        }
        if id == "font" and self.mixed_fonts then
            body = VerticalGroup:new{
                align = "left",
                Tabbar.widget({
                    width = self.panel_w,
                    active = self.font_kind,
                    tabs = {
                        { id = "chinese", text = _("中文字体"), icon = "text_fields" },
                        { id = "western", text = _("西文字体"), icon = "font_download" },
                    },
                    on_tab = function(kind)
                        self.font_kind = kind
                        self.menus.font = nil
                        self:render()
                        UIManager:setDirty(self, "ui")
                    end,
                }),
                body,
            }
        end
    end
    local panel = VerticalGroup:new{
        align = "left",
        body,
        -- 页签按 floor(宽/个数) 等分会剩几像素，选中标记那一行也只画中间短线：铺底，别露出遮罩
        Box:new{
            style = surface,
            width = self.panel_w,
            height = Tabbar.height(),
            Tabbar.widget({
                width = self.panel_w,
                active = id,
                tabs = self.bar_tabs,
                on_tab = function(tab_id)
                    for index, other in ipairs(self.tabs) do
                        if other == tab_id then self:goTab(index) end
                    end
                end,
            }),
        },
    }
    self:setPanel(HorizontalGroup:new{
        align = "top",
        panel,
        LineWidget:new{
            dimen = Geom:new{ w = math.max(1, Theme.px(t.row.divider)) * 2, h = h },
            background = Blitbuffer.Color8(t.color.ink),
        },
    })
    self.panel_x, self.panel_y = 0, 0
end

--- 旋转后由 Modal:relayout 调用：列表页按旧宽度借来的，丢掉重借。
function Sidebar:updateView()
    self.panel_w = math.floor(self.dimen.w * PANEL_RATIO)
    self.menus = {}
    self:render()
end

---@param tab integer
function Sidebar:goTab(tab)
    if tab < 1 or tab > #self.tabs or tab == self.tab then return end
    self.tab = tab
    self:render()
    UIManager:setDirty(self, "ui")
end

--- 子控件（菜单、翻页按钮）先收点击；落到这里的只剩空白处，遮罩区关闭。
function Sidebar:onTapModal(_arg, ges)
    if ges.pos.x >= self.panel_w then self:onClose() end
    return true
end

--- 列表页的左右滑已被列表收走（翻页），到这里的是书籍页、遮罩或列表没消费的滑动。
function Sidebar:onSwipeSidebar(_arg, ges)
    if require("ui.input").isDiagonalSwipe(ges.direction) then return false end
    if ges.pos.x >= self.panel_w then
        self:onClose()
    elseif ges.direction == "west" then
        self:goTab(self.tab + 1)
    elseif ges.direction == "east" then
        self:goTab(self.tab - 1)
    else
        return false
    end
    return true
end

--- 原生 close_callback 里有状态清理（如 ReaderBookmark.bookmark_menu 置空），关侧栏时补跑。
function Sidebar:onCloseWidget()
    local closes = self.native_closes
    self.native_closes = {}
    for _idx, close in ipairs(closes) do close() end
    self.closed = true
    -- 书签 / 书摘页写入的类型过滤只属于侧栏；清掉免得快捷面板「高亮与笔记」被卡住。
    if self.ui.bookmark then self.ui.bookmark.match_table = nil end
    if self.font_job then
        self.font_job.cancel()
        self.font_job = nil
    end
    if self.ticket then
        self.ticket:cancel()
        self.ticket = nil
    end
    Modal.onCloseWidget(self)
end

--- 打开侧栏；没有阅读会话（书还没就绪）时不接手。
---@param ui table ReaderUI
---@return boolean
function Sidebar.open(ui)
    local snapshot = require("reader.session").current()
    if not snapshot then return false end
    Sidebar:new{ ui = ui, snapshot = snapshot }:show()
    return true
end

--- 阅读页右滑入口：优先于原生翻页 swipe；不满足设置时返回 false 交还原生翻页。
---@param ui table ReaderUI
---@param ges table
---@return boolean
function Sidebar.onReaderSwipe(ui, ges)
    if ges.direction ~= "east" then return false end
    local mode = MoonSettings.get("features.sidebar").sidebar_gesture
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
        handler = function(ges) return Guard.call("sidebar swipe", Sidebar.onReaderSwipe, ui, ges) end,
    } })
end

--- 登记「打开月读侧栏」手势，事件由下面的 events 接住。
function Sidebar.onCreate()
    require("dispatcher"):registerAction("book_reader_sidebar", {
        category = "none",
        event = "BookReaderSidebar",
        title = _("打开月读侧栏"),
        reader = true,
    })
end

Sidebar.events = {
    ---@param plugin BookPlugin
    BookReaderSidebar = function(plugin)
        if not plugin.ui.document then return false end
        return Sidebar.open(plugin.ui)
    end,
}

--- 阅读页创建时登记右滑区。
---@param plugin BookPlugin
function Sidebar.onReaderReady(plugin)
    local ui = plugin and plugin.ui
    if not ui then return end
    Sidebar.install(ui)
end

return Sidebar
