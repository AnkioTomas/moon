--[[--
图书馆：分组页签 + 工具条 + 封面网格 / 列表 / 分组列表 + 分页。

布局：
  +-----------------------------------------------+
  |   书籍   |   作者   |   系列   |   分类        |
  | 467 本书     [排序▾] [全部▾] [☰] [⌕] [↻]      |
  | +----+ +----+ +----+ +----+                   |   网格（默认）
  | |封面| |封面| |封面| |封面|                   |   或列表：一行一本（rows.lua）
  | |书名| |书名| |书名| |书名|                   |
  | +----+ +----+ +----+ +----+                   |
  | [<]              N / M                   [>]  |
  +-----------------------------------------------+

作者 / 系列 / 分类页签先列分组（按名称，空桶排最后），点进去是该组的书，工具条左侧换成「上级 + 组名」。
分组只在内存里，视图（网格 / 列表）落盘 desktop.library_view。
书城复用 build（网格 + 搜索/清除/上级工具条）与 gridMetrics，不带页签。

@module koplugin.book.ui.library
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local CoverCell = require("ui.widgets.cover")
local Filter = require("desktop.pages.library.filter")
local Rows = require("desktop.pages.library.rows")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Button = require("ui.themes.widgets.button")
local Input = require("ui.themes.widgets.input")
local Pager = require("ui.themes.widgets.pager")
local Tap = require("ui.themes.widgets.tap")
local Text = require("ui.themes.widgets.text")
local MoonSettings = require("utils.settings")
local _ = require("gettext")
local T = require("ffi/util").template

-- 列表书行的目标高度（逻辑像素）：768×1024 一页约 6 行。
local LIST_ROW_H = 120

---@class BookLibrary
---@field desktop BookDesktop
---@field filter table
---@field sort string
---@field view "grid"|"list"
---@field group string 当前分组页签 id
---@field dir string|nil 文件夹页签当前目录，nil 为书库根目录
---@field groups { rows: { value: string, count: integer }[], err: string|nil }|nil 当前页签的分组缓存
---@field group_page number
---@field page number
---@field page_size number
---@field total number
---@field state table|nil
---@field fetch_cancel CancelHandle|nil
---@field random_cancel CancelHandle|nil 随机一本的在飞查询
---@field filter_cancel CancelHandle|nil
---@field _opening_cover table|nil
---@field _opening_bar table|nil
---@field _open_token table|nil
---@field _verify_job table|nil 下载标记后台校验任务
local Library = {}
Library.__index = Library

--- 分组页签：key/flag 是筛选字段（组名 / 空桶），column 是 books 的分组列（也是计数行的取值键）。
---@return table[]
local function groupTabs()
    return {
        { id = "books", text = _("书籍") },
        { id = "author", text = _("作者"), key = "author", flag = "unauthor",
            column = "authors", empty = _("未知作者") },
        { id = "series", text = _("系列"), key = "series", flag = "unseries",
            column = "series", empty = _("无系列") },
        { id = "category", text = _("分类"), key = "category", flag = "uncategorized",
            column = "category", empty = _("未分类") },
        { id = "folder", text = _("文件夹") },
    }
end

Library.tabOptions = groupTabs

--- 本地书库目录；没配置（纯 WebDAV）为空串。
---@return string
local function localRoot()
    return require("source.local.common").rootPath(MoonSettings.getSource("local"))
end

--- 当前可见的页签：按设置 ui.library_tabs 选（书籍恒有）；文件夹只在本地源且配了目录时有。
---@return table[]
function Library:visibleTabs()
    local chosen = {}
    for _idx, id in ipairs(MoonSettings.get("ui").library_tabs) do chosen[id] = true end
    local source = self.desktop and self.desktop.source
    local folder = source and source.id == "local" and localRoot() ~= ""
    local tabs = {}
    for _idx, g in ipairs(groupTabs()) do
        if (g.id == "books" or chosen[g.id]) and (g.id ~= "folder" or folder) then tabs[#tabs + 1] = g end
    end
    return tabs
end

--- 当前页签被设置或换源隐藏后，落到第一个可见页签（不触发查询，随后 updateView 会补拉）。
function Library:normalizeGroup()
    local tabs = self:visibleTabs()
    for _idx, g in ipairs(tabs) do
        if g.id == self.group then return end
    end
    -- 搜索结果显示在书籍页签，书籍页签恒在，不会走到这里。
    for _idx, g in ipairs(groupTabs()) do
        if g.key then self.filter[g.key], self.filter[g.flag] = nil, nil end
    end
    self.group, self.group_page, self.groups = tabs[1].id, 1, nil
    self.dir, self.page, self.state = nil, 1, nil
end

--- 文件夹视图当前所在目录（默认书库根目录）。
---@return string
function Library:currentDir()
    return self.dir or localRoot()
end

--- 进入文件夹；dir 为 nil 回根目录。
---@param dir string|nil
function Library:openDir(dir)
    self.dir = dir
    self:refetch()
end

--- 创建图书馆实例，独立持有筛选、分页和请求句柄。
---@param opts table
---@return BookLibrary
function Library:new(opts)
    local display = MoonSettings.get("desktop")
    opts.filter = opts.filter or {}
    opts.page = opts.page or 1
    opts.page_size = opts.page_size or 12
    opts.total = opts.total or 0
    opts.sort = opts.sort or (display.library_sort or "recent_added")
    opts.view = opts.view or (display.library_view == "list" and "list" or "grid")
    opts.group = opts.group or "books"
    opts.group_page = opts.group_page or 1
    return setmetatable(opts, self)
end

--- 当前分组页签。
---@return table
function Library:currentGroup()
    for _idx, g in ipairs(groupTabs()) do
        if g.id == self.group then return g end
    end
    return groupTabs()[1]
end

--- 是否停在分组列表（分组页签且还没点进某一组）。
---@return boolean
function Library:inGroupList()
    local g = self:currentGroup()
    return g.key ~= nil and self.filter[g.key] == nil and not self.filter[g.flag]
end

--- 改设置项并落盘。
---@param key string
---@param value any
local function persist(key, value)
    local display = MoonSettings.get("desktop")
    display[key] = value
    MoonSettings.save("desktop", display)
end

--- 换书籍列表的条件后回第一页重拉。
function Library:refetch()
    self.page, self.state = 1, nil
    self.desktop:updateView()
end

--- 翻页条与滑动作用的页码：分组列表本地分页，书籍按查询分页。
---@return number
function Library:currentPage()
    return self:inGroupList() and self.group_page or self.page
end

--- 切换分组页签（点当前页签即回到它的首页）：丢掉所有分组下钻条件。
---@param id string
function Library:selectGroup(id)
    for _idx, g in ipairs(groupTabs()) do
        if g.key then self.filter[g.key], self.filter[g.flag] = nil, nil end
    end
    self.group, self.group_page, self.groups, self.dir = id, 1, nil, nil
    self:refetch()
end

--- 点进一组；空串是空桶。
---@param value string
function Library:openGroup(value)
    local g = self:currentGroup()
    if value == "" then
        self.filter[g.flag] = true
    else
        self.filter[g.key] = value
    end
    self:refetch()
end

--- 从一组退回分组列表（group_page 保留）。
function Library:closeGroup()
    local g = self:currentGroup()
    self.filter[g.key], self.filter[g.flag] = nil, nil
    self.state = nil
    self.desktop:updateView()
end

--- 网格 / 列表互切，尽量停在原来第一本书所在页。
function Library:toggleView()
    local first = (self.page - 1) * self.page_size
    self.view = self.view == "list" and "grid" or "list"
    persist("library_view", self.view)
    self.page = math.floor(first / self:syncPageSize()) + 1
    self.state = nil
    self.desktop:updateView()
end

--- 取筛选计数；离开图书馆或换源后丢弃结果。
---@param done fun(data: table|nil, err: string|nil)
function Library:loadFilters(done)
    local desktop = self.desktop
    local source = desktop.source
    if not source then done(nil, _("当前数据源不可用")); return end
    if self.filter_cancel then self.filter_cancel:cancel() end
    self.filter_cancel = require("book.catalog").filtersAsync(source.id, function(res, err)
        self.filter_cancel = nil
        if desktop.closed or desktop.tab ~= "library" or desktop.source ~= source then return end
        done(res and res.data, res and nil or (err or _("加载失败")))
    end)
end

--- 排序下拉。
---@param anchor table
function Library:showSort(anchor)
    Filter.openSort(anchor, self.sort, function(sort)
        self.sort = sort
        persist("library_sort", sort)
        self:refetch()
    end)
end

--- 筛选下拉（阅读状态 / 已下载 / 数据源）。
---@param anchor table
function Library:showStatus(anchor)
    self:loadFilters(function(data, err)
        if not data then
            require("ui.themes.widgets.toast"):new{ text = err, timeout = 2 }:show()
            return
        end
        Filter.openStatus(anchor, data, self.filter, function(filter)
            self.filter = filter
            self:refetch()
        end)
    end)
end

--- 拉当前页签的分组计数；分组变少（删书、改元数据后返回）时页码夹回末页，不停在空页。
function Library:fetchGroups()
    local g = self:currentGroup()
    local desktop = self.desktop
    local source = desktop.source
    if not source then
        self.groups = { rows = {}, err = _("当前数据源不可用") }
        desktop:updateView()
        return
    end
    if self.filter_cancel then self.filter_cancel:cancel() end
    self.filter_cancel = require("book.catalog").groupCountsAsync(source.id, g.column, function(counts, err)
        self.filter_cancel = nil
        if desktop.closed or desktop.tab ~= "library" or desktop.source ~= source then return end
        local rows = {}
        for i, row in ipairs(counts or {}) do
            rows[i] = { value = row[g.column], count = row.count }
        end
        self.groups = { rows = rows, err = not counts and (err or _("加载失败")) or nil }
        self.group_page = math.min(self.group_page, self:pages())
        desktop:updateView()
    end)
end

--- 应用书名搜索：搜索面向全部书籍，回到书籍页签。
---@param value string|nil 当前设置项的值
function Library:applySearch(value)
    self.filter = value and value ~= "" and { search = value } or {}
    self.group, self.groups = "books", nil
    self:refetch()
end

--- 工具条与翻页条的固定高度。
---@param t table
---@return number top_h, number bottom_h
local function barHeights(t)
    return Button.heightOf("small") + Theme.px(t.space.sm) * 2, Theme.px(t.control.height)
end

--- 分组页签条高度（含底线）。
---@return number
function Library.tabsHeight()
    local t = Theme.current()
    return Theme.px(t.control.height) + Theme.px(t.row.divider)
end

--- 按内容区尺寸算出网格容量；请求 page_size 必须与此一致。
---@param w number 可用宽度，单位像素
---@param h number 可用高度，单位像素
---@param head_h number|nil 工具条上方另占的高度（图书馆的分组页签），书城不传
---@param lib table|nil CoverCell.libraryConf()；书城不传
---@return table
function Library.gridMetrics(w, h, head_h, lib)
    local t = Theme.current()
    w = math.max(1, w)
    h = math.max(1, h)
    local pad = Theme.px(t.space.md)
    local top_h, bottom_h = barHeights(t)
    local grid_h = math.max(1, h - (head_h or 0) - top_h - bottom_h)
    local avail = math.max(1, w - pad * 2)
    local slot_w, cw, ch, cols, gap, row_gap, cell_h = CoverCell.denseCoverMetrics(avail, grid_h, {
        title_extra = lib and require("ui.widgets.book").captionExtra(lib.title, lib.author, lib.kobo)
            or require("ui.widgets.book").captionExtra(),
    })
    local rows = math.max(1, math.floor((grid_h + row_gap) / (cell_h + row_gap)))
    return {
        pad = pad,
        top_h = top_h,
        bottom_h = bottom_h,
        grid_h = grid_h,
        gap = gap,
        row_gap = row_gap,
        cols = cols,
        rows = rows,
        slot_w = slot_w,
        cw = cw,
        ch = ch,
        cell_h = cell_h,
        page_size = cols * rows,
    }
end

--- 列表度量：正文均分成书行；分组行另按主题行高算。
---@param w number
---@param h number
---@return table
function Library.listMetrics(w, h)
    local t = Theme.current()
    local top_h, bottom_h = barHeights(t)
    local body_h = math.max(1, h - Library.tabsHeight() - top_h - bottom_h)
    local rows = math.max(1, math.floor(body_h / Theme.px(LIST_ROW_H)))
    return {
        pad = Theme.px(t.space.md),
        width = math.max(1, w),
        top_h = top_h,
        bottom_h = bottom_h,
        grid_h = body_h,
        rows = rows,
        row_h = math.floor(body_h / rows),
        group_rows = math.max(1, math.floor(body_h / Rows.groupHeight())),
        page_size = rows,
    }
end

--- 当前视图的度量。
---@return table
function Library:metrics()
    local desktop = self.desktop
    local w, h = desktop.dimen.w, desktop:contentHeight()
    if self.view == "list" and self.group ~= "folder" then return Library.listMetrics(w, h) end
    return Library.gridMetrics(w, h, Library.tabsHeight(), CoverCell.libraryConf())
end

--- 按网格度量铺满一页封面格子（放不下的整行丢弃）。
---@param ctx table 构建上下文，提供尺寸、数据源和桌面宿主
---@param books table 按展示顺序排列的书籍列表
---@param m table 预先计算的网格布局尺寸
---@param on_open fun(book: table, cover: table, cw: number, ch: number)
---@param show_status boolean|nil 是否显示书籍状态信息
---@param lib table|nil CoverCell.libraryConf()；书城不传
---@return table
local function buildGrid(ctx, books, m, on_open, show_status, lib)
    -- 文件夹条目没有详情 / 状态角标，整卡只用来进目录。
    local grid = VerticalGroup:new{ align = "left" }
    local rows = math.min(m.rows, math.ceil(#books / m.cols))
    for r = 1, rows do
        if r > 1 then grid[#grid + 1] = VerticalSpan:new{ width = m.row_gap } end
        local row = HorizontalGroup:new{ HorizontalSpan:new{ width = m.pad } }
        for c = 1, m.cols do
            local book = books[(r - 1) * m.cols + c]
            if not book then break end
            if c > 1 then row[#row + 1] = HorizontalSpan:new{ width = m.gap } end
            row[#row + 1] = CoverCell.build(
                ctx, book, m.slot_w, m.cw, m.ch, on_open, show_status and not book.is_folder,
                lib and lib.title, lib and lib.author, lib
            )
        end
        grid[#grid + 1] = row
    end
    return grid
end

--- 正文空态：加载中 / 错误 / 空列表。
---@param w number
---@param h number
---@param msg string
---@return table
local function emptyBody(w, h, msg)
    local t = Theme.current()
    return CenterContainer:new{
        dimen = Geom:new{ w = w, h = h },
        Text.line("body", msg, { color = t.color.muted, width = w - Theme.px(t.space.md) * 2 }),
    }
end

--- 工具条：左侧控件靠左，右侧控件靠右，中间留白撑满。
--- 不能对拼好的 HorizontalGroup 调 getSize 再追加：它会缓存子件偏移，后追加的子件绘制时偏移是 nil。
---@param w number
---@param h number
---@param left table[]|fun(avail: number): table[] 函数形式：按右侧用掉后剩余的宽度构建
---@param right table[]|fun(compact: boolean): table[] 函数形式：放不下时以 compact=true 重建
---@return table
local function toolbar(w, h, left, right)
    local t = Theme.current()
    local pad, gap = Theme.px(t.space.md), Theme.px(t.space.sm)
    local function sum(list)
        local n = gap * math.max(0, #list - 1)
        for _idx, child in ipairs(list) do n = n + child:getSize().w end
        return n
    end
    if type(right) == "function" then
        local build = right
        right = build(false)
        local lw = type(left) == "function" and 0 or sum(left)
        if pad * 2 + gap + lw + sum(right) > w then right = build(true) end
    end
    if type(left) == "function" then left = left(w - pad * 2 - gap * 2 - sum(right)) end
    local bar = HorizontalGroup:new{ align = "center", HorizontalSpan:new{ width = pad } }
    local used = pad * 2
    local function put(list)
        for i, child in ipairs(list) do
            if i > 1 then
                bar[#bar + 1] = HorizontalSpan:new{ width = gap }
                used = used + gap
            end
            bar[#bar + 1] = child
            used = used + child:getSize().w
        end
    end
    put(left)
    local filler = HorizontalSpan:new{ width = 0 }
    bar[#bar + 1] = filler
    put(right)
    filler.width = math.max(gap, w - used)
    bar[#bar + 1] = HorizontalSpan:new{ width = pad }
    return CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, bar }
end

--- 页面骨架：头部各行 + 正文（不足补空）+ 翻页条，整页正好是内容区尺寸。
---@param w number
---@param h number
---@param head table[]
---@param body table
---@param body_h number
---@param pager table Pager.widget 参数（width 由这里补）
---@return table
local function frame(w, h, head, body, body_h, pager)
    local group = VerticalGroup:new{ align = "left" }
    for _idx, widget in ipairs(head) do group[#group + 1] = widget end
    group[#group + 1] = body
    group[#group + 1] = VerticalSpan:new{ width = math.max(0, body_h - body:getSize().h) }
    pager.width = w
    group[#group + 1] = Pager.widget(pager)
    return Box:new{ style = { bg = Theme.current().color.page }, width = w, height = h, group }
end

--- 分组页签条：当前页签粗体加下划线。
---@param w number
---@param tabs table[]
---@param active string
---@param on_tab fun(id: string)
---@return table
local function tabStrip(w, tabs, active, on_tab)
    local t = Theme.current()
    local tab_w = math.floor(w / #tabs)
    local line = Theme.px(2)
    local text_h = Theme.px(t.control.height) - line
    local strip = HorizontalGroup:new{}
    for _idx, g in ipairs(tabs) do
        local on = g.id == active
        strip[#strip + 1] = Tap.wrap(VerticalGroup:new{
            CenterContainer:new{
                dimen = Geom:new{ w = tab_w, h = text_h },
                Text.line("body", g.text, { bold = on, color = on and t.color.ink or t.color.muted }),
            },
            on and LineWidget:new{
                background = Blitbuffer.Color8(t.color.ink),
                dimen = Geom:new{ w = tab_w, h = line },
            } or VerticalSpan:new{ width = line },
        }, function() on_tab(g.id) end)
    end
    return VerticalGroup:new{
        align = "left",
        strip,
        LineWidget:new{
            background = Blitbuffer.Color8(t.color.rule),
            dimen = Geom:new{ w = w, h = Theme.px(t.row.divider) },
        },
    }
end

local MAX_CHIP_ROWS = 2

--- chip 分组排成至多两行（靠左）：分组依次接在当前行后；放不下就换行，
--- 最后一行放不下的分组只留放得下的前几项（选中项必在其中）+「更多 ▾」（点开列出全部），并给后面分组的「更多」留出位置。
---@param w number
---@param groups { title: string|nil, chips: { id: string, title: string }[], active: string|nil }[]
---@param on_pick fun(id: string)|nil
---@return table[][] rows 每行是 { widget, gap_before }[]
local function chipLayout(w, groups, on_pick)
    local t = Theme.current()
    local pad, gap = Theme.px(t.space.md), Theme.px(t.space.sm)
    local avail = w - pad * 2
    local built = {}
    for gi, group in ipairs(groups) do
        local g = { chips = {}, full = 0 }
        for i, chip in ipairs(group.chips) do
            g.chips[i] = Button:new{
                text = chip.title, size = "small", variant = chip.id == group.active and "primary" or "ghost",
                callback = function() on_pick(chip.id) end,
            }
            g.full = g.full + g.chips[i]:getSize().w + (i > 1 and gap or 0)
        end
        for i, chip in ipairs(group.chips) do
            if chip.id == group.active then g.active_idx = i end
        end
        local dropdown
        dropdown = Button:new{
            text = _("更多"), icon = "arrow_drop_down", trailing = true, size = "small", variant = "ghost",
            callback = function()
                local items = {}
                for i, chip in ipairs(group.chips) do
                    items[i] = { text = chip.title, checked = chip.id == group.active, callback = function() on_pick(chip.id) end }
                end
                require("ui.themes.widgets.list"):new{
                    centered = true, anchor = dropdown.dimen, inner_width = Theme.px(160), items = items,
                }:show()
            end,
        }
        g.dropdown = dropdown
        built[gi] = g
    end

    local sep = gap * 2
    if #built == 0 then return {} end
    local rows = { {} }
    local used = 0
    --- 当前行（from 已用）还能给第 gi 组的宽度；最后一行要扣掉后面各组「更多」的位置。
    local function room(gi, from)
        local left = avail - from - (from > 0 and sep or 0)
        if #rows == MAX_CHIP_ROWS then
            for k = gi + 1, #built do left = left - sep - built[k].dropdown:getSize().w end
        end
        return left
    end
    --- 只留放得下的前几项 + 「更多」；选中项挤掉最后一个可见项。
    local function collapse(g, space)
        local more = g.dropdown
        space = space - more:getSize().w - gap
        local fit, w = 0, 0
        for i, widget in ipairs(g.chips) do
            local nw = w + (i > 1 and gap or 0) + widget:getSize().w
            if nw > space then break end
            w, fit = nw, i
        end
        local shown = {}
        for i = 1, fit do shown[i] = g.chips[i] end
        local a = g.active_idx
        if a and a > fit then
            if fit > 0 then
                shown[fit] = g.chips[a]
            elseif g.chips[a]:getSize().w <= space then
                shown[1] = g.chips[a]
            end
        end
        shown[#shown + 1] = more
        return shown
    end
    for gi, g in ipairs(built) do
        if g.full > room(gi, used) and used > 0 and #rows < MAX_CHIP_ROWS then
            rows[#rows + 1] = {}
            used = 0
        end
        local space = room(gi, used)
        local items = g.full <= space and g.chips or collapse(g, space)
        local row = rows[#rows]
        for i, widget in ipairs(items) do
            local before = i > 1 and gap or (used > 0 and sep or 0)
            row[#row + 1] = { widget, before }
            used = used + before + widget:getSize().w
        end
    end
    return rows
end

--- chip 区总高度（行数随宽度变化，书城据此算网格容量）。
---@param w number
---@param groups table[]
---@return number
function Library.chipHeight(w, groups)
    local row_h = Button.heightOf("small") + Theme.px(Theme.current().space.sm)
    return #chipLayout(w, groups) * row_h
end

---@param w number
---@param groups table[]
---@param on_pick fun(id: string)
---@return table[] 每行一个靠左容器
local function chipRows(w, groups, on_pick)
    local pad = Theme.px(Theme.current().space.md)
    local row_h = Button.heightOf("small") + Theme.px(Theme.current().space.sm)
    local out = {}
    for _idx, items in ipairs(chipLayout(w, groups, on_pick)) do
        local row = HorizontalGroup:new{ align = "center", HorizontalSpan:new{ width = pad } }
        for _idx2, item in ipairs(items) do
            if item[2] > 0 then row[#row + 1] = HorizontalSpan:new{ width = item[2] } end
            row[#row + 1] = item[1]
        end
        out[#out + 1] = LeftContainer:new{ dimen = Geom:new{ w = w, h = row_h }, row }
    end
    return out
end

--- 构建书城页（网格 + 上级/搜索 + 总数）；清空搜索框再搜即退出搜索。
---@param ctx table 构建上下文，提供尺寸、数据源和桌面宿主
---@param state table 当前页面的数据和分页状态
---@param opts table groups = { { chips, active }... } 工具条下的 chip 行（点选回调 on_chip(id)）；on_open 接管点击；on_back 出现「上级」；on_search；provider={text,on_pick(anchor)} 工具条左侧的切换按钮；show_status=false 不画角标
---@return table
function Library:build(ctx, state, opts)
    local t = Theme.current()
    local w, h = ctx.width, ctx.height
    local groups = opts.groups or {}
    local m = Library.gridMetrics(w, h, Library.chipHeight(w, groups))
    local left = {}
    if opts.on_back then
        left[#left + 1] = Button:new{ icon = "arrow_back", text = _("上级"), size = "small", callback = opts.on_back }
    end
    if opts.provider then
        local pick
        pick = Button:new{
            text = opts.provider.text, icon = "arrow_drop_down", trailing = true, size = "small",
            callback = function() opts.provider.on_pick(pick.dimen) end,
        }
        left[#left + 1] = pick
    end
    left[#left + 1] = Button:new{ icon = "search", variant = "ghost", size = "small", callback = opts.on_search }
    local total = Text.line("caption", T(_("共%1"), opts.total or 0), { color = t.color.muted })
    local books = state.books
    local body
    if books and #books > 0 then
        body = buildGrid(ctx, books, m, opts.on_open, opts.show_status)
    else
        body = emptyBody(w, m.grid_h, not books and _("加载中…") or state.err or opts.empty_text or _("没有书籍"))
    end
    local head = { toolbar(w, m.top_h, left, { total }) }
    for _idx, row in ipairs(chipRows(w, groups, opts.on_chip)) do head[#head + 1] = row end
    return frame(w, h, head, body, m.grid_h, {
        page = opts.page or 1,
        pages = opts.pages or 1,
        on_prev = opts.on_prev,
        on_next = opts.on_next,
    })
end

--- 书籍视图的工具条右侧：排序、筛选、视图切换、搜索、刷新，搜索中再加清除。
---@return table[]
function Library:bookTools(compact)
    local sort_btn, status_btn
    if compact then
        sort_btn = Button:new{
            icon = "sort", variant = "ghost", size = "small",
            callback = function() self:showSort(sort_btn.dimen) end,
        }
        status_btn = Button:new{
            icon = "filter_list", variant = "ghost", size = "small",
            callback = function() self:showStatus(status_btn.dimen) end,
        }
    else
        sort_btn = Button:new{
            text = Filter.sortText(self.sort), icon = "arrow_drop_down", trailing = true, size = "small",
            callback = function() self:showSort(sort_btn.dimen) end,
        }
        status_btn = Button:new{
            text = Filter.status(self.filter).text, icon = "arrow_drop_down", trailing = true, size = "small",
            callback = function() self:showStatus(status_btn.dimen) end,
        }
    end
    local tools = {
        sort_btn,
        status_btn,
        Button:new{
            icon = self.view == "list" and "grid_view" or "view_list", variant = "ghost", size = "small",
            callback = function() self:toggleView() end,
        },
        Button:new{ icon = "search", variant = "ghost", size = "small", callback = function() self:showSearch() end },
        Button:new{ icon = "refresh", variant = "ghost", size = "small", callback = function() self:rescan() end },
    }
    if self.total > 0 and MoonSettings.get("ui").library_random then
        table.insert(tools, 3, Button:new{
            icon = "casino", variant = "ghost", size = "small", callback = function() self:openRandom() end,
        })
    end
    if self.filter.search then
        tools[#tools + 1] = Button:new{
            icon = "search_off", variant = "ghost", size = "small",
            callback = function() self:applySearch("") end,
        }
    end
    return tools
end

--- 图书馆页面：页签 + 工具条 + 分组列表 / 书籍（网格或列表）+ 翻页。
---@param ctx table
---@return table
function Library:buildPage(ctx)
    local t = Theme.current()
    local w, h = ctx.width, ctx.height
    local tabs = tabStrip(w, self:visibleTabs(), self.group, function(id) self:selectGroup(id) end)
    local muted = { color = t.color.muted }
    local pager = {
        page = self:currentPage(),
        pages = self:pages(),
        on_prev = function() self:gotoPage(self:currentPage() - 1) end,
        on_next = function() self:gotoPage(self:currentPage() + 1) end,
    }

    if self:inGroupList() then
        local m = Library.listMetrics(w, h)
        local g = self:currentGroup()
        local groups = self.groups
        local left = { Text.line("caption", T(_("共%1"), groups and #groups.rows or 0), muted) }
        local right = {
            Button:new{ icon = "search", variant = "ghost", size = "small", callback = function() self:showSearch() end },
            Button:new{ icon = "refresh", variant = "ghost", size = "small", callback = function() self:rescan() end },
        }
        local body
        if groups and #groups.rows > 0 then
            body = VerticalGroup:new{ align = "left" }
            local first = (self.group_page - 1) * m.group_rows
            for i = first + 1, math.min(#groups.rows, first + m.group_rows) do
                local row = groups.rows[i]
                body[#body + 1] = Rows.group(row.value ~= "" and row.value or g.empty, row.count, w, function()
                    self:openGroup(row.value)
                end)
            end
        else
            body = emptyBody(w, m.grid_h, not groups and _("加载中…") or groups.err or _("没有书籍"))
        end
        return frame(w, h, { tabs, toolbar(w, m.top_h, left, right) }, body, m.grid_h, pager)
    end

    local m = self:metrics()
    local left
    local g = self:currentGroup()
    if g.key then
        local back = Button:new{
            icon = "arrow_back", variant = "ghost", size = "small",
            callback = function() self:closeGroup() end,
        }
        local name = self.filter[g.key] or g.empty
        left = function(avail)
            local room = avail - back:getSize().w - Theme.px(t.space.sm)
            return { back, Text.line("body", name, { bold = true, width = math.max(Theme.px(t.space.md), room) }) }
        end
    elseif g.id == "folder" then
        local root = localRoot()
        local dir = self:currentDir()
        if dir ~= root then
            local back = Button:new{
                icon = "arrow_back", variant = "ghost", size = "small",
                callback = function()
                    local parent = dir:match("^(.*)/[^/]+$")
                    self:openDir(parent and #parent > #root and parent or nil)
                end,
            }
            local name = dir:match("([^/]+)$") or dir
            left = function(avail)
                local room = avail - back:getSize().w - Theme.px(t.space.sm)
                return { back, Text.line("body", name, { bold = true, width = math.max(Theme.px(t.space.md), room) }) }
            end
        else
            left = { Text.line("caption", T(_("%1 项"), self.total), muted) }
        end
    else
        left = { Text.line("caption", T(_("%1 本书"), self.total), muted) }
    end
    local state = self.state or {}
    local books = state.books
    local on_open = CoverCell.opener(self, ctx, require("desktop.open").book)
    local on_detail = function(book) require("desktop.detail").open(ctx.desktop, "library", book) end
    local body
    if not books or #books == 0 then
        body = emptyBody(w, m.grid_h, not books and _("加载中…") or state.err or _("没有书籍"))
    elseif self.view == "list" and g.id ~= "folder" then
        body = VerticalGroup:new{ align = "left" }
        for i = 1, math.min(#books, m.rows) do
            body[i] = Rows.book(ctx, books[i], w, m.row_h, on_open, on_detail)
        end
    else
        ctx.on_detail = on_detail
        local lib = CoverCell.libraryConf()
        local on_tap = on_open
        if lib.tap_detail then on_tap = function(book) on_detail(book) end end
        if g.id == "folder" then
            local tap_book = on_tap
            on_tap = function(book, ...)
                if book.is_folder then self:openDir(book.dir) else tap_book(book, ...) end
            end
        end
        body = buildGrid(ctx, books, m, on_tap, true, lib)
    end
    ---@type function|table
    local right = function(compact) return self:bookTools(compact) end
    if g.id == "folder" then
        right = {
            Button:new{ icon = "search", variant = "ghost", size = "small", callback = function() self:showSearch() end },
            Button:new{ icon = "refresh", variant = "ghost", size = "small", callback = function() self:rescan() end },
        }
    end
    return frame(w, h, { tabs, toolbar(w, m.top_h, left, right) }, body, m.grid_h, pager)
end

--- 异步拉取图书馆列表。
function Library:fetch()
    --- 写入图书馆状态并重建。
    ---@param books table 按展示顺序排列的书籍列表
    ---@param err string|nil 操作失败的原因
    local function done(books, err)
        if self.desktop.closed or self.desktop.tab ~= "library" then
            return
        end
        self.state = {
            books = books,
            err = err,
        }
        self.desktop:updateView()
    end

    if self.fetch_cancel then
        self.fetch_cancel:cancel()
        self.fetch_cancel = nil
    end

    self:syncPageSize()
    local source = self.desktop.source
    if not source then done({}, _("当前数据源不可用")); return end
    local Catalog = require("book.catalog")
    local request, query = Catalog.listLibraryAsync, self:query()
    if self.group == "folder" then
        request = Catalog.folderPageAsync
        query = { dir = self:currentDir(), root = localRoot(), page = self.page, page_size = self.page_size, sort = self.sort }
    end
    self.fetch_cancel = request(source.id, query, function(res, err)
        self.fetch_cancel = nil
        if self.desktop.closed or self.desktop.tab ~= "library"
            or self.desktop.source ~= source then
            return
        end
        if not res then
            done({}, err or _("加载失败"))
            return
        end
        self.total = res.count
        -- 书变少（删书、对账）后当前页可能越界：退到末页重拉。
        local pages = math.max(1, math.ceil(self.total / self.page_size))
        if self.page > pages then
            self.page = pages
            self:fetch()
            return
        end
        done(res.data)
    end)
end

--- 当前页的书库查询参数：分页 + 筛选 + 排序。
---@return BookListOpts
function Library:query()
    local f = self.filter
    return {
        page = self.page,
        page_size = self.page_size,
        search = f.search or "",
        category = f.category or "",
        uncategorized = not not f.uncategorized,
        series = f.series or "",
        unseries = not not f.unseries,
        author = f.author or "",
        unauthor = not not f.unauthor,
        read_status = f.read_status,
        downloaded = f.downloaded,
        hidden = f.hidden,
        source_id = f.source_id or "",
        sort = self.sort,
    }
end

--- 从当前筛选结果里随机抽一本并打开它的介绍页：按总数随机一页、每页一本，只取那一行。
--- 筛选没限定阅读状态时按随机范围设置抽（见 home.random.statuses），范围内没有书就提示。
function Library:openRandom()
    local source = self.desktop.source
    if not source or self.total < 1 then return end
    if self.random_cancel then self.random_cancel:cancel() end
    local Catalog = require("book.catalog")
    local function run(opts, fn)
        local done = false
        local handle = Catalog.listLibraryAsync(source.id, opts, function(res)
            done, self.random_cancel = true, nil
            if not self.desktop.closed and self.desktop.source == source then fn(res) end
        end)
        -- 同步回调时句柄已作废，不能再记成在飞。
        if not done then self.random_cancel = handle end
    end
    local function pick(opts, total)
        opts.page, opts.page_size = math.random(total), 1
        run(opts, function(res)
            local book = res and res.data[1]
            if book then require("desktop.detail").open(self.desktop, "library", book) end
        end)
    end
    if self.filter.read_status then return pick(self:query(), self.total) end
    local statuses = require("desktop.pages.home.random").statuses()
    local function probe(idx)
        if not statuses[idx] then
            require("ui.themes.widgets.toast"):new{ text = _("没有符合随机范围的书") }:show()
            return
        end
        local opts = self:query()
        opts.read_status, opts.page, opts.page_size = statuses[idx], 1, 1
        run(opts, function(res)
            local count = res and res.count or 0
            if count > 0 then pick(opts, count) else probe(idx + 1) end
        end)
    end
    probe(1)
end

--- 按当前视图容量同步 page_size。
---@return number
function Library:syncPageSize()
    local n = self:metrics().page_size
    if self.page_size ~= n then
        self.page_size = n
        self.state = nil
        local pages = math.max(1, math.ceil(self.total / n))
        if self.page > pages then
            self.page = pages
        end
    end
    return self.page_size
end

--- 总页数：分组列表按分组行数，书籍按 page_size（由 updateView / fetch 同步）。
---@return number
function Library:pages()
    if self:inGroupList() then
        local d = self.desktop
        local per = Library.listMetrics(d.dimen.w, d:contentHeight()).group_rows
        return math.max(1, math.ceil(#(self.groups and self.groups.rows or {}) / per))
    end
    return math.max(1, math.ceil(self.total / self.page_size))
end

--- 跳转到指定页并重建；分组列表本地翻页，不发请求。
---@param page number 当前页码，从 1 开始
function Library:gotoPage(page)
    page = math.max(1, math.min(self:pages(), page))
    if self:inGroupList() then
        if page == self.group_page then return end
        self.group_page = page
        self.desktop:updateView()
        return
    end
    if page == self.page and self.state and self.state.books then
        return
    end
    self.page = page
    self.state = nil
    self.desktop:updateView()
end

--- 手动强制刷新书库；具体动作由当前源决定（本地源扫盘，远端源拉全量）。
--- 进度弹窗归任务队列：源把刷新入队并前台跟随，刷新中再点只重新弹出进度。
function Library:rescan()
    local source = self.desktop.source
    if not source or not source.syncBooksAsync then return end
    self:verifyDownloads()
    require("desktop.sync").refresh(self.desktop)
end

--- 后台校验已下载标记（文件可能被手动删掉），撤掉了登记且仍在图书馆就重拉当前页。
--- 离开页面不取消：写库纠正本身要落地，回调只在仍停留图书馆时刷新界面。
function Library:verifyDownloads()
    if self._verify_job then return end
    local scope = require("book.catalog").libraryScope(self.desktop.source.id)
    self._verify_job = require("book.store").verifyDownloadsAsync(scope, function(changed)
        self._verify_job = nil
        local desktop = self.desktop
        if changed == 0 or desktop.closed or desktop.tab ~= "library" then return end
        self.state = nil
        desktop:updateView()
    end)
end

--- 弹出搜索输入框；提交空串等同清除。
---@param on_apply fun(query: string)|nil 调用方没给时落到书库的独占搜索筛选
---@param initial_query string|nil 搜索框初始文字
function Library:showSearch(on_apply, initial_query)
    Input:new{
        title = _("搜索书籍"),
        fields = { { text = initial_query or self.filter.search or "", hint = _("书名或作者") } },
        ok_text = _("搜索"),
        callback = on_apply or function(query) self:applySearch(query) end,
    }:show()
end

--- Desktop 入口：同步 page_size、缺数据就下一 tick 补拉、拼页面。
---@return table
function Library:updateView()
    self:normalizeGroup()
    self:syncPageSize()
    local load
    if self:inGroupList() then
        load = not self.groups and self.fetchGroups
    else
        load = not self.state and self.fetch
    end
    if load then
        UIManager:nextTick(require("ui.guard").wrap("library fetch", function()
            if self.desktop.closed or self.desktop.tab ~= "library" then return end
            load(self)
        end))
    end
    return self:buildPage(self.desktop:ctx())
end

--- 仅取消本实例当前的列表查询，并清空请求句柄；同步本身归源管。
function Library:cancel()
    if self.fetch_cancel then
        self.fetch_cancel:cancel()
        self.fetch_cancel = nil
    end
    if self.filter_cancel then
        self.filter_cancel:cancel()
        self.filter_cancel = nil
    end
    if self.random_cancel then
        self.random_cancel:cancel()
        self.random_cancel = nil
    end
end

--- 取消旧查询并清除筛选、分页及列表缓存（分组页签与视图保留）。
function Library:reset()
    self:cancel()
    self.filter = {}
    self.page = 1
    self.group_page = 1
    self.total = 0
    self.state = nil
    self.groups = nil
    self.dir = nil
end

-- 取消、暂停、销毁都只需停掉在飞查询，避免离开页面后旧结果继续更新界面。
Library.onCancel = Library.cancel
Library.deactivate = Library.cancel
Library.destroy = Library.cancel

--- 处理换源重置、书架变化和左右滑动分页，忽略不属于图书馆的事件。
---@param event string 父组件转发的事件名称或事件对象
---@param payload any 与事件一起传入的数据
function Library:onEvent(event, payload)
    if event == "source_changed" then
        self:reset()
        return
    end
    if event == "shelf_changed" then
        self.state, self.groups = nil, nil
        return
    end
    if event ~= "swipe" then return end
    if payload.direction == "west" then
        self:gotoPage(self:currentPage() + 1)
    elseif payload.direction == "east" then
        self:gotoPage(self:currentPage() - 1)
    end
end

return Library
