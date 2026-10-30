--[[--
主体：最近阅读封面堆叠 / 立体。最多 9 本，底边对齐，中间封面压住两侧；
堆叠侧封面竖直缩小提亮；立体侧封面按 SimpleUI Cover Deck「flow」同款透视
（外缘近、内缘远的梯形），箭头和滑动循环切换；标题、作者、进度在封面下方。

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
local MoonSettings = require("utils.settings")
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
---@field slot integer|nil 堆叠扇形槽位
---@field book Book
---@field dist integer 距离中间的层数
---@field cw integer 目标宽
---@field ch integer 目标高
---@field src_w integer|nil 立体：倾斜前封面宽（完整 2:3）
---@field src_h integer|nil 立体：倾斜前封面高
---@field side integer|nil -1 左 / 1 右
---@field rho number|nil 立体：内缘/外缘高度比
---@field x integer 相对组左缘的横坐标
---@class BookHomeRecentCards : BookHomeComponent
---@field focus integer|nil
---@field _book_n integer|nil
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
local FILL = { 4, 6, 3, 7, 2, 8, 1, 9 }
local PAINT = { 1, 9, 2, 8, 3, 7, 4, 6, 5 }

-- 堆叠：竖直缩小重叠。
local STACK = {
    rings = 4,
    peek = 0.48,
    scale = { [0] = 1, 0.91, 0.82, 0.73, 0.64 },
}

-- 立体：透视公式同 SimpleUI CoverWarp；摆位故意比 flow 少叠一点——
-- SimpleUI 的 offset=0.30 / w=0.55 只露出槽宽一半多，外缘几乎同高，
-- 小尺寸 / 纯色封面时看起来就像书脊。offset 贴近 w，短边才进画面。
local STEREO = {
    rho = 0.75,
    levels = {
        { w = 0.65, h = 0.92, offset = 0.50 },
        { w = 0.65, h = 0.92, offset = 0.95 },
    },
    main_cap = 160,
    main_frac = 0.48,
    preferred_h = 280,
}

-- 侧封面保持竖直，仅缩小并重叠摆放；底边始终对齐，形成书堆纵深。
---@class BookRecentCardPerspective : WidgetContainer
---@field dimen table
local Perspective = WidgetContainer:extend{}
---@param bb BlitBuffer
---@param x integer
---@param y integer
function Perspective:paintTo(bb, x, y)
    self[1]:paintTo(bb, x, y)
    bb:lightenRect(x, y, self.dimen.w, self.dimen.h)
end

--- 透视列映射：t=0 外缘（近、全高），t=1 内缘；rho 为内/外高度比。
--- 公式同 SimpleUI CoverWarp.columnAt（标准 Y 轴透视）。
---@param t number
---@param rho number
---@return number u
---@return number relative_h
local function columnAt(t, rho)
    if rho >= 1 then return t, 1 end
    if rho <= 0 then return t, 1 end
    local denom = 1 - t * (1 - rho)
    if denom <= 0 then return 1, rho end
    local u = t * rho / denom
    return u, 1 / (1 + (1 / rho - 1) * u)
end

-- 立体侧封面：整本 2:3 正图透视压进窄槽；外缘近、内缘远。
-- 梯形采样极贵：结果挂模块 LRU，滑动 refresh 重建控件时复用，widget 不拥有缓冲。
---@class BookRecentCardStereo : WidgetContainer
---@field dimen table
---@field src_w integer
---@field src_h integer
---@field side integer
---@field rho number
---@field book_key string
---@field _warp BlitBuffer|nil
---@field _tops integer[]|nil
---@field _heights integer[]|nil
local Stereo = WidgetContainer:extend{}

local WARP_MAX = 24
local warp_cache = {} ---@type table<string, { warp: BlitBuffer, tops: integer[], heights: integer[] }>
local warp_order = {} ---@type string[]

local function warpClear()
    for key, entry in pairs(warp_cache) do
        if entry.warp and entry.warp.free then entry.warp:free() end
        warp_cache[key] = nil
    end
    warp_order = {}
end

---@param key string
---@param entry { warp: BlitBuffer, tops: integer[], heights: integer[] }
local function warpPut(key, entry)
    if warp_cache[key] then
        local old = warp_cache[key]
        if old.warp and old.warp ~= entry.warp and old.warp.free then old.warp:free() end
    else
        warp_order[#warp_order + 1] = key
    end
    warp_cache[key] = entry
    while #warp_order > WARP_MAX do
        local evict = table.remove(warp_order, 1)
        local old = warp_cache[evict]
        warp_cache[evict] = nil
        if old and old.warp and old.warp.free then old.warp:free() end
    end
end

function Stereo:getSize()
    return self.dimen
end

--- widget 不拥有 _warp（归模块缓存）；只放下子控件。
---@param full boolean|nil
function Stereo:free(full)
    self._warp, self._tops, self._heights = nil, nil, nil
    WidgetContainer.free(self, full)
end

--- 生成梯形缓冲与每列 tops/heights；命中模块缓存则跳过采样。
---@param typ any|nil
function Stereo:ensureWarp(typ)
    if self._warp then return end
    local sw, sh = self.src_w, self.src_h
    local dw, dh = self.dimen.w, self.dimen.h
    local key = table.concat({
        self.book_key or "", tostring(self.side or 0), tostring(sw), tostring(sh),
        tostring(dw), tostring(dh), tostring(self.rho or 0), tostring(typ or ""),
    }, "\0")
    local hit = warp_cache[key]
    if hit then
        self._warp, self._tops, self._heights = hit.warp, hit.tops, hit.heights
        return
    end
    local src = typ and Blitbuffer.new(sw, sh, typ) or Blitbuffer.new(sw, sh)
    src:fill(Blitbuffer.COLOR_WHITE)
    self[1]:paintTo(src, 0, 0)
    local warp = typ and Blitbuffer.new(dw, dh, typ) or Blitbuffer.new(dw, dh)
    warp:fill(Blitbuffer.COLOR_WHITE)
    local outer_left = self.side < 0
    local rho = self.rho
    local last, src_last = dw - 1, sw - 1
    local tops, heights = {}, {}
    for dx = 0, last do
        local t = (outer_left and dx or (last - dx)) / last
        local u, relative_h = columnAt(t, rho)
        local pos = (outer_left and u or (1 - u)) * src_last
        if pos < 0 then pos = 0 elseif pos > src_last then pos = src_last end
        local src_x = math.floor(pos + 0.5)
        local col_h = math.max(1, math.min(dh, math.floor(dh * relative_h + 0.5)))
        local top = math.floor((dh - col_h) / 2)
        tops[dx + 1] = top
        heights[dx + 1] = col_h
        for dy = 0, col_h - 1 do
            local sy = col_h <= 1 and 0 or math.floor(dy * (sh - 1) / (col_h - 1) + 0.5)
            warp:setPixelClamped(dx, top + dy, src:getPixel(src_x, sy))
        end
    end
    src:free()
    warpPut(key, { warp = warp, tops = tops, heights = heights })
    self._warp, self._tops, self._heights = warp, tops, heights
end

---@param bb BlitBuffer
---@param x integer
---@param y integer
function Stereo:paintTo(bb, x, y)
    local sw, sh = self.src_w, self.src_h
    local dw, dh = self.dimen.w, self.dimen.h
    if dw < 2 or dh < 2 or sw < 2 or sh < 2 then
        self[1]:paintTo(bb, x, y)
        return
    end
    self:ensureWarp(bb.getType and bb:getType() or nil)
    local warp, tops, heights = self._warp, self._tops, self._heights
    -- 按列合并同高段，blitFrom 一次画一截（无 alpha，只贴梯形本体）。
    if bb.blitFrom then
        local dx = 0
        while dx < dw do
            local top, col_h = tops[dx + 1], heights[dx + 1]
            local run = 1
            while dx + run < dw
                and tops[dx + run + 1] == top
                and heights[dx + run + 1] == col_h do
                run = run + 1
            end
            if col_h > 0 then
                bb:blitFrom(warp, x + dx, y + top, dx, top, run, col_h)
            end
            dx = dx + run
        end
        return
    end
    for dx = 0, dw - 1 do
        local top, col_h = tops[dx + 1], heights[dx + 1]
        for dy = 0, col_h - 1 do
            bb:setPixelClamped(x + dx, y + top + dy, warp:getPixel(dx, top + dy))
        end
    end
end

--- 当前布局：stack 堆叠（默认）/ stereo 立体。
---@return string
function M.layout()
    local id = MoonSettings.get("desktop.pages.home").home_recent_cards_layout
    return id == "stereo" and "stereo" or "stack"
end

---@param id string|nil
---@return string
function M.saveLayout(id)
    id = id == "stereo" and "stereo" or "stack"
    local home = MoonSettings.get("desktop.pages.home")
    home.home_recent_cards_layout = id
    MoonSettings.save("desktop.pages.home", home)
    return id
end

--- 是否把第一本放进卡片；缺省放，居中。
---@return boolean
function M.showFirst()
    return MoonSettings.get("desktop.pages.home").home_recent_cards_show_first ~= false
end

---@param desktop BookDesktop
function M:showSettings(desktop)
    local layout = M.layout()
    local function refresh()
        desktop:onEvent("home_refresh")
    end
    require("ui.themes.widgets.sheet"):new{
        title = M.label,
        items = {
            { buttons = {
                { text = layout == "stack" and _("✓ 堆叠") or _("堆叠"), callback = function()
                    if M.layout() == "stack" then return end
                    M.saveLayout("stack")
                    refresh()
                end },
                { text = layout == "stereo" and _("✓ 立体") or _("立体"), callback = function()
                    if M.layout() == "stereo" then return end
                    M.saveLayout("stereo")
                    refresh()
                end },
            } },
            { text = M.showFirst() and _("✓ 显示第一本") or _("显示第一本"), callback = function()
                local home = MoonSettings.get("desktop.pages.home")
                home.home_recent_cards_show_first = not M.showFirst()
                MoonSettings.save("desktop.pages.home", home)
                refresh()
            end },
            { text = M.hideFinished() and _("✓ 隐藏已读完") or _("隐藏已读完"), callback = function()
                M.saveHideFinished(not M.hideFinished())
                refresh()
            end },
        },
    }:show()
end

---@return BookHomeHeightSpec
function M:heightRange()
    if M.layout() == "stereo" then
        return { height = Theme.px(STEREO.preferred_h) }
    end
    return { height = PREFERRED_H }
end

---@param main_cw integer
---@param main_ch integer
---@param dist integer
---@return integer
---@return integer
local function stackSlotSize(main_cw, main_ch, dist)
    if dist == 0 then return main_cw, main_ch end
    local scale = STACK.scale[dist] or STACK.scale[#STACK.scale]
    return math.max(1, math.floor(main_cw * scale)), math.max(1, math.floor(main_ch * scale))
end

---@param slots table<integer, BookRecentCardSlot>
---@param main_cw integer
---@param main_ch integer
---@return table<integer, BookRecentCardPlacement>
---@return number
---@return number
local function stackFan(slots, main_cw, main_ch)
    local by_slot = {}
    for slot, entry in pairs(slots) do
        local dist = math.abs(slot - CENTER)
        local cw, ch = stackSlotSize(main_cw, main_ch, dist)
        by_slot[slot] = {
            slot = slot, book = entry.book, dist = dist,
            cw = cw, ch = ch, side = slot < CENTER and -1 or (slot > CENTER and 1 or 0), x = 0,
        }
    end
    local center = by_slot[CENTER]
    for ring = 1, STACK.rings do
        local left, right = CENTER - ring, CENTER + ring
        local inner_l, inner_r = by_slot[left + 1], by_slot[right - 1]
        if by_slot[left] and inner_l then
            by_slot[left].x = inner_l.x - math.floor(by_slot[left].cw * STACK.peek)
        end
        if by_slot[right] and inner_r then
            by_slot[right].x = inner_r.x + inner_r.cw - math.floor(by_slot[right].cw * (1 - STACK.peek))
        end
    end
    local min_x, max_x = center.x, center.x + center.cw
    for _slot, item in pairs(by_slot) do
        if item.x < min_x then min_x = item.x end
        if item.x + item.cw > max_x then max_x = item.x + item.cw end
    end
    return by_slot, min_x, max_x - min_x
end

---@param books Book[]
---@return table<integer, BookRecentCardSlot>
local function stackAssign(books)
    local slots = {}
    slots[CENTER] = { book = books[1] }
    local sides = math.min(STACK.rings * 2, #FILL, #books - 1)
    sides = sides - sides % 2
    for i = 1, sides do
        slots[FILL[i]] = { book = books[i + 1] }
    end
    return slots
end

--- 立体摆位：按 SimpleUI flow 的 offset 模型；返回从远到近的绘制列表（中间最后）。
---@param books Book[] 已旋转、焦点在首位
---@param main_cw integer
---@param main_ch integer
---@return BookRecentCardPlacement[]
---@return number min_x
---@return number width
local function stereoFan(books, main_cw, main_ch)
    local items = {}
    local half = math.floor(main_cw / 2)
    -- 焦点居中；其余按 左1、右1、左2、右2…（与 SimpleUI hasPeek 一致：两本时只露左）。
    local lefts, rights = {}, {}
    for i = 2, #books do
        if (#lefts + #rights) % 2 == 0 then
            lefts[#lefts + 1] = books[i]
        else
            rights[#rights + 1] = books[i]
        end
    end
    for depth = #STEREO.levels, 1, -1 do
        local level = STEREO.levels[depth]
        local cw = math.max(1, math.floor(main_cw * level.w))
        local ch = math.max(1, math.floor(main_ch * level.h))
        local offset = math.floor(main_cw * level.offset)
        -- 源图保持 2:3，再透视压进窄槽（同 SimpleUI flat_w）。
        local src_h = ch
        local src_w = math.max(2, math.ceil(src_h * 2 / 3))
        local function add(side, book)
            if not book then return end
            local x = side < 0 and (-half - offset) or (half + offset - cw)
            items[#items + 1] = {
                book = book, dist = depth, side = side,
                cw = cw, ch = ch, src_w = src_w, src_h = src_h,
                rho = STEREO.rho, x = x,
            }
        end
        add(-1, lefts[depth])
        add(1, rights[depth])
    end
    items[#items + 1] = {
        book = books[1], dist = 0, side = 0,
        cw = main_cw, ch = main_ch, src_w = main_cw, src_h = main_ch,
        rho = 1, x = -half,
    }
    local min_x, max_x = items[#items].x, items[#items].x + main_cw
    for _idx, item in ipairs(items) do
        if item.x < min_x then min_x = item.x end
        if item.x + item.cw > max_x then max_x = item.x + item.cw end
    end
    return items, min_x, max_x - min_x
end

---@param ctx BookDesktopCtx
---@param item BookRecentCardPlacement
---@param on_tap fun()
---@param stereo boolean
---@return table
local function coverCard(ctx, item, on_tap, stereo)
    local src_w = item.src_w or item.cw
    local src_h = item.src_h or item.ch
    local body = (Book.cover(ctx.plugin, ctx.source, item.book, src_w, src_h, {
        badge = false,
        shadow = item.dist == 0,
        show_parent = ctx.desktop,
    }))
    if item.dist > 0 then
        if stereo then
            local book = item.book
            body = Stereo:new{
                dimen = Geom:new{ w = item.cw, h = item.ch },
                src_w = src_w,
                src_h = src_h,
                side = item.side,
                rho = item.rho or STEREO.rho,
                book_key = tostring(book.source_id or "") .. "\0"
                    .. tostring(book.stable_id or book.title or ""),
                body,
            }
        else
            body = Perspective:new{ dimen = Geom:new{ w = item.cw, h = item.ch }, body }
        end
    end
    return Tap.wrap(body, on_tap)
end

---@param book Book
---@param width integer
---@param on_tap fun()
---@return table
---@return number
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
        Text.line("caption", author ~= "" and author or _("未知作者"),
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

---@param books Book[]
---@param focus integer
---@return Book[]
local function rotateBooks(books, focus)
    if #books <= 1 then return books end
    focus = ((focus - 1) % #books) + 1
    local out = { books[focus] }
    for i = 1, #books do
        if i ~= focus then out[#out + 1] = books[i] end
    end
    return out
end

---@param self BookHomeRecentCards
---@param delta integer
local function shiftFocus(self, delta)
    local n = self._book_n or 0
    if n <= 1 then return end
    self.focus = (self.focus - 1 + delta) % n + 1
    self:refresh()
end

---@return table
function M:createWidget()
    local ctx, opts = self.ctx, self.opts
    local w = opts.width
    local h = opts.height
    local stereo = M.layout() == "stereo"
    local previous_key = self.shelf_key
    local recent, reading, err = self:shelf()
    if self.shelf_key ~= previous_key then self.focus = 1 end
    recent, reading = M.withoutFinished(recent, reading)
    local books = {}
    if recent and M.showFirst() then books[1] = recent end
    if #books == 0 and #reading == 0 then return M.libraryPrompt(ctx, w, h, err) end

    for _idx, book in ipairs(reading) do
        if #books < MAX_BOOKS then books[#books + 1] = book end
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
    local main_cap = stereo and STEREO.main_cap or 120
    local main_frac = stereo and STEREO.main_frac or 0.38
    local main_cw = math.max(1, math.floor(math.min(Theme.px(main_cap), fan_w * main_frac, avail_h * 2 / 3)))
    local main_ch = math.max(1, math.floor(main_cw * 3 / 2))

    ---@type BookRecentCardPlacement[]
    local paint_list
    local min_x, group_w
    if stereo then
        paint_list, min_x, group_w = stereoFan(books, main_cw, main_ch)
        while group_w > fan_w and main_cw > 1 do
            local next_w = math.max(1, math.floor(main_cw * fan_w / group_w))
            if next_w >= main_cw then break end
            main_cw, main_ch = CoverCell.coverDim(next_w)
            paint_list, min_x, group_w = stereoFan(books, main_cw, main_ch)
        end
    else
        local slots = stackAssign(books)
        local by_slot
        by_slot, min_x, group_w = stackFan(slots, main_cw, main_ch)
        while group_w > fan_w and main_cw > 1 do
            local next_w = math.max(1, math.floor(main_cw * fan_w / group_w))
            if next_w >= main_cw then break end
            main_cw, main_ch = CoverCell.coverDim(next_w)
            by_slot, min_x, group_w = stackFan(slots, main_cw, main_ch)
        end
        paint_list = {}
        for _idx, slot in ipairs(PAINT) do
            if by_slot[slot] then paint_list[#paint_list + 1] = by_slot[slot] end
        end
    end

    local origin = math.floor((avail_w - group_w) / 2) - min_x
    local row_bottom = avail_h
    local overlap = OverlapGroup:new{
        dimen = Geom:new{ w = avail_w, h = avail_h },
        overlap_offset = { 0, 0 },
    }
    for _idx, item in ipairs(paint_list) do
        local book = item.book
        local cell = coverCard(ctx, item, function()
            M.openBook(ctx, book)
        end, stereo)
        local x = origin + item.x
        cell.overlap_offset = {
            math.max(0, math.min(x, avail_w - item.cw)),
            row_bottom - item.ch,
        }
        table.insert(overlap, cell)
    end

    if #books > 1 then
        for _idx, delta in ipairs({ -1, 1 }) do
            local button = Tap.wrap(CenterContainer:new{
                dimen = Geom:new{ w = arrow_w, h = main_ch },
                Icon.widget{
                    name = delta < 0 and "chevron_left" or "chevron_right",
                    size = 20,
                    color = Blitbuffer.Color8(Theme.current().color.muted),
                },
            }, function() shiftFocus(self, delta) end)
            button.overlap_offset = { delta < 0 and 0 or avail_w - arrow_w, row_bottom - main_ch }
            table.insert(overlap, button)
        end
    end
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

--- 组件销毁时丢掉梯形缓存，别跨首页生命周期占着 BlitBuffer。
function M:onDestroy()
    warpClear()
end

--- 测试用：当前梯形缓存条数。
---@return integer
function M._warpCacheSize()
    local n = 0
    for _ in pairs(warp_cache) do n = n + 1 end
    return n
end

return M
