--[[--
主体：最近阅读封面堆叠。最多 9 本，底边对齐，中间封面压住两侧透视封面；
两侧淡色箭头和滑动均可循环切换；标题、作者、进度位于封面下方。

@module koplugin.book.desktop.pages.home.recent_cards
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Book = require("ui.widgets.book")
local CoverCell = require("ui.widgets.cover")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Theme = require("ui.themes")
local Icon = require("ui.themes.widgets.icon")
local Progress = require("ui.themes.widgets.progress")
local Tap = require("ui.themes.widgets.tap")
local Text = require("ui.themes.widgets.text")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookRecentCardSlot
---@field book Book

---@class BookRecentCardPlacement
---@field slot integer 扇形槽位，中间槽位为 CENTER
---@field book Book
---@field dist integer 距离中间槽位的层数
---@field cw integer 封面包围盒宽度
---@field ch integer 封面包围盒高度
---@field x integer 相对于中间封面左边缘的横坐标
---@class BookHomeRecentCards : BookHomeComponent
---@field focus integer|nil 当前居中的书籍索引，从 1 开始
---@field _book_n integer|nil 当前参与轮换的书籍数量
local M = {
    id = "recent_cards",
    label = _("最近阅读卡片"),
    icon = "collections_bookmark",
}
setmetatable(M, require("desktop.pages.home.base"))
M.__index = M

local PREFERRED_H = Theme.px(220)
local MAX_BOOKS = 9
local CENTER = 5
local RINGS = 4
local FILL = { 4, 6, 3, 7, 2, 8, 1, 9 }
local PAINT = { 1, 9, 2, 8, 3, 7, 4, 6, 5 }
local PEEK = 0.48
local SCALE = { [0] = 1, 0.91, 0.82, 0.73, 0.64 }

-- 侧封面保持竖直，仅缩小并重叠摆放；底边始终对齐，形成书堆纵深。
---@class BookRecentCardPerspective : WidgetContainer
---@field dimen table 封面投影包围盒
local Perspective = WidgetContainer:extend{}
--- 先画封面，再提亮两次压淡，衬出中间封面。
---@param bb BlitBuffer 目标画布
---@param x integer 目标左上角横坐标
---@param y integer 目标左上角纵坐标
function Perspective:paintTo(bb, x, y)
    self[1]:paintTo(bb, x, y)
    bb:lightenRect(x, y, self.dimen.w, self.dimen.h)
    bb:lightenRect(x, y, self.dimen.w, self.dimen.h)
end

--- 封面堆叠的内容高度。
---@return BookHomeHeightSpec
function M:heightRange()
    return { height = PREFERRED_H }
end

--- 按离中心的层数等比缩小封面，返回至少 1 像素的包围盒。
---@param main_cw integer 中间封面宽度，单位像素
---@param main_ch integer 中间封面高度，单位像素
---@param dist integer 距中心层数，范围 0 到 RINGS
---@return integer width 当前层封面宽度
---@return integer height 当前层封面高度
local function slotSize(main_cw, main_ch, dist)
    if dist == 0 then
        return main_cw, main_ch
    end
    local scale = SCALE[dist]
    return math.max(1, math.floor(main_cw * scale)), math.max(1, math.floor(main_ch * scale))
end

--- 从中心向两侧计算重叠位置；返回整组宽度供居中和缩放使用。
---@param slots table<integer, BookRecentCardSlot> 槽位到书籍的映射，中间槽位必有书，两侧允许空缺
---@param main_cw integer 中间封面宽度，单位像素
---@param main_ch integer 中间封面高度，单位像素
---@return table<integer, BookRecentCardPlacement> by_slot 槽位到摆放项
---@return number min_x 最左侧坐标
---@return number width 整组包围盒宽度
local function fanItems(slots, main_cw, main_ch)
    local by_slot = {}
    for slot, entry in pairs(slots) do
        local dist = math.abs(slot - CENTER)
        local cw, ch = slotSize(main_cw, main_ch, dist)
        by_slot[slot] = { slot = slot, book = entry.book, dist = dist, cw = cw, ch = ch, x = 0 }
    end
    local center = by_slot[CENTER]
    for ring = 1, RINGS do
        local left, right = CENTER - ring, CENTER + ring
        local inner_l, inner_r = by_slot[left + 1], by_slot[right - 1]
        if by_slot[left] and inner_l then
            by_slot[left].x = inner_l.x - math.floor(by_slot[left].cw * PEEK)
        end
        if by_slot[right] and inner_r then
            by_slot[right].x = inner_r.x + inner_r.cw - math.floor(by_slot[right].cw * (1 - PEEK))
        end
    end
    local min_x, max_x = center.x, center.x + center.cw
    for _slot, item in pairs(by_slot) do
        if item.x < min_x then min_x = item.x end
        if item.x + item.cw > max_x then max_x = item.x + item.cw end
    end
    return by_slot, min_x, max_x - min_x
end

--- 第一本居中，其余从近到远交替放在左右槽位，超过九本的忽略。
---@param books Book[] 非空书籍列表，第一本为当前焦点
---@return table<integer, BookRecentCardSlot> slots 已占用槽位
local function assignSlots(books)
    local slots = {}
    slots[CENTER] = { book = books[1] }
    for i = 2, #books do
        local slot = FILL[i - 1]
        if slot then
            slots[slot] = { book = books[i] }
        end
    end
    return slots
end

--- 构建可点击封面：中间保留正面与阴影，侧面增加透视绘制容器。
---@param ctx BookDesktopCtx 提供封面数据源及异步刷新宿主
---@param book Book 封面对应的书籍
---@param cw integer 封面包围盒宽度，单位像素
---@param ch integer 封面包围盒高度，单位像素
---@param on_tap fun() 点击封面时打开对应书籍
---@param dist integer 距离中间封面的层数
---@return table
local function coverCard(ctx, book, cw, ch, on_tap, dist)
    local body = (Book.cover(ctx.plugin, ctx.source, book, cw, ch, {
        badge = false,
        shadow = dist == 0,
        show_parent = ctx.desktop,
    }))
    if dist > 0 then
        body = Perspective:new{ dimen = Geom:new{ w = cw, h = ch }, body }
    end
    return Tap.wrap(body, on_tap)
end

--- 生成焦点书籍的标题、作者及阅读进度，整个说明区可点击打开书籍。
---@param book Book 当前居中的书籍
---@param width integer 说明区可用宽度，单位像素
---@param on_tap fun() 点击说明区时的打开回调
---@return table widget 可点击的说明区容器
---@return number height 文本与进度条的实测总高度
local function captionBlock(book, width, on_tap)
    local t = Theme.current()
    local xs = Theme.px(t.space.xs)
    local author = Book.author(book)
    local pct = Book.pct(book)
    local label = Text.line("caption", T(_("已读 %1%"), string.format("%.0f", pct)))
    local col = VerticalGroup:new{
        align = "center",
        Text.line("title", Book.title(book), { width = width }),
        VerticalSpan:new{ width = xs },
        Text.line("caption", author ~= "" and T(_("作者：%1"), author) or _("未知作者"),
            { width = width, color = t.color.muted }),
        VerticalSpan:new{ width = xs },
        HorizontalGroup:new{
            align = "center",
            label,
            HorizontalSpan:new{ width = xs },
            Progress:new{ width = math.max(Theme.px(48), width - label:getSize().w - xs), percent = pct },
        },
    }
    return Tap.wrap(col, on_tap), col:getSize().h
end

--- 将焦点书籍移到首位，其余保持原顺序，不修改输入列表。
---@param books Book[] 参与轮换的书籍列表，允许空列表或单本
---@param focus integer 当前焦点的 1-based 索引，越界时循环归一化
---@return Book[] ordered 用于分配槽位的书籍列表
local function rotateBooks(books, focus)
    if #books <= 1 then return books end
    focus = ((focus - 1) % #books) + 1
    local out = { books[focus] }
    for i = 1, #books do
        if i ~= focus then
            out[#out + 1] = books[i]
        end
    end
    return out
end

--- 移动焦点并重建内容区域；无书或单本时不触发刷新。
---@param self BookHomeRecentCards 拥有焦点与布局上下文的视图实例
---@param delta integer -1 上一本，1 下一本；首尾循环
local function shiftFocus(self, delta)
    local n = self._book_n or 0
    if n <= 1 then return end
    self.focus = (self.focus - 1 + delta) % n + 1
    self:refresh()
end

--- 读取最近阅读列表，按可用宽高拼装底边对齐的封面、切换箭头和说明区。
--- 数据为空时返回图书馆入口；封面资源由书籍组件管理。
---@return table widget 本次构建的内容树
function M:createWidget()
    local ctx, opts = self.ctx, self.opts
    local w = opts.width
    local h = opts.height
    local recent, reading, err = self:shelf()

    if not recent then return M.libraryPrompt(ctx, w, h, err) end

    local books = { recent }
    for _idx, book in ipairs(reading) do
        if #books < MAX_BOOKS then
            books[#books + 1] = book
        end
    end
    self._book_n = #books
    self.focus = math.min(self.focus or 1, #books)
    books = rotateBooks(books, self.focus)
    local center_book = books[1]

    local gap_cap = Theme.px(Theme.current().space.sm)
    local avail_w = w
    local caption_w = math.min(avail_w, Theme.px(220))
    local caption, caption_h = captionBlock(center_book, caption_w, function()
        M.openBook(ctx, center_book)
    end)
    local avail_h = math.max(1, h - caption_h - gap_cap)
    local arrow_w = #books > 1 and math.min(Theme.px(28), math.floor(avail_w / 8)) or 0
    local fan_w = math.max(1, avail_w - arrow_w * 2)
    local main_cw = math.max(1, math.floor(math.min(Theme.px(120), fan_w * 0.38, avail_h * 2 / 3)))
    local main_ch = math.max(1, math.floor(main_cw * 3 / 2))

    local slots = assignSlots(books)
    local by_slot, min_x, group_w = fanItems(slots, main_cw, main_ch)
    while group_w > fan_w and main_cw > 1 do
        local next_w = math.max(1, math.floor(main_cw * fan_w / group_w))
        if next_w >= main_cw then break end
        main_cw, main_ch = CoverCell.coverDim(next_w)
        by_slot, min_x, group_w = fanItems(slots, main_cw, main_ch)
    end

    local origin = math.floor((avail_w - group_w) / 2) - min_x
    local row_bottom = avail_h
    local overlap = OverlapGroup:new{
        dimen = Geom:new{ w = avail_w, h = avail_h },
        overlap_offset = { 0, 0 },
    }
    for _idx, slot in ipairs(PAINT) do
        local item = by_slot[slot]
        if item then
            local book = item.book
            local cell = coverCard(ctx, book, item.cw, item.ch, function()
                M.openBook(ctx, book)
            end, item.dist)
            local x = origin + item.x
            cell.overlap_offset = {
                math.max(0, math.min(x, avail_w - item.cw)),
                row_bottom - item.ch,
            }
            table.insert(overlap, cell)
        end
    end

    if #books > 1 then
        for _idx, delta in ipairs({ -1, 1 }) do
            local button = Tap.wrap(CenterContainer:new{
                dimen = Geom:new{ w = arrow_w, h = avail_h },
                Icon.widget{
                    name = delta < 0 and "chevron_left" or "chevron_right",
                    size = 12,
                    color = Blitbuffer.Color8(Theme.current().color.faint),
                },
            }, function() shiftFocus(self, delta) end)
            button.overlap_offset = { delta < 0 and 0 or avail_w - arrow_w, 0 }
            table.insert(overlap, button)
        end
    end
    --- 上层封面及箭头先接收点击，避免后方书籍抢走中间封面的事件。
    ---@param event table KOReader Event
    ---@return boolean consumed 是否已消费事件
    function overlap:propagateEvent(event)
        for i = #self, 1, -1 do
            if self[i]:handleEvent(event) then return true end
        end
        return false
    end

    local body = VerticalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = avail_w, h = avail_h },
            overlap,
        },
        VerticalSpan:new{ width = gap_cap },
        CenterContainer:new{
            dimen = Geom:new{ w = avail_w, h = caption_h },
            caption,
        },
    }
    local host = InputContainer:new{
        dimen = Geom:new{ w = avail_w, h = math.max(1, h) },
        body,
    }
    host.ges_events = {
        SwipeCards = {
            GestureRange:new{
                ges = "swipe",
                range = function() return host.dimen end,
            },
        },
    }
    --- 将左右滑动转换为与箭头相同的焦点偏移。
    ---@param _host table 手势接收容器
    ---@param ges table|nil 手势数据，direction 为滑动方向
    ---@return boolean|nil consumed
    host.onSwipeCards = function(_host, ges)
        local dir = ges and ges.direction
        if dir == "west" then
            shiftFocus(self, 1)
            return true
        elseif dir == "east" then
            shiftFocus(self, -1)
            return true
        end
    end
    return CenterContainer:new{ dimen = Geom:new{ w = w, h = math.max(1, h) }, host }
end

return M
