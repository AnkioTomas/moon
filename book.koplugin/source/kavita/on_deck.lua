--[[--
首页组件：Kavita「继续阅读」（On Deck）。在线且已配置时拉一次，5 分钟内复用；
跟首页「最近阅读列表」同一套封面网格（CoverCell.denseCoverMetrics + Book.widget）：
每页 4 本，多了分页；点开走月读开书流程（多卷 series 会先选卷）。

@module source.kavita.on_deck
--]]

local Base = require("desktop.pages.home.base")
local Book = require("ui.widgets.book")
local CenterContainer = require("ui/widget/container/centercontainer")
local CoverCell = require("ui.widgets.cover")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Pager = require("ui.themes.widgets.pager")
local Theme = require("ui.themes")
local Tap = require("ui.themes.widgets.tap")
local Text = require("ui.themes.widgets.text")
local _ = require("gettext")

local ID = "kavita"
local MAX_BOOKS = 10
local TTL = 300
-- 跟首页「最近阅读」一页一样：一行 4 本（封面大），多的分页。
local COLS = 4
local ROWS = 1

---@class KavitaOnDeck : BookHomeComponent
---@field job { cancel: fun() }|nil
---@field loaded_at integer|nil
---@field err string|nil
local M = {
    id = "kavita.on_deck",
    label = _("Kavita 继续阅读"),
    icon = "collections_bookmark",
}
setmetatable(M, Base)
M.__index = M

--- 网格尺寸：跟首页「最近阅读列表」共用 CoverCell.denseCoverMetrics，封面与槽位口径一致
---（封面在固定宽的槽里居中，标题按槽宽居中，不会一本书看着变小/错位）。
--- 列数固定 4（一页 4 本，封面才够大）；area_h 有值时再收到放得下。
---@param width integer
---@param area_h integer|nil 分配到的可用高度
---@return integer slot_w
---@return integer cw
---@return integer ch
---@return integer gap
---@return integer row_gap
---@return integer cell_h
local function gridMetrics(width, area_h)
    local extra = Book.captionExtra(true, false)
    local max_h = CoverCell.gridCoverMaxH(area_h)
    local slot_w, cw, ch, _cols, gap, row_gap, cell_h = CoverCell.denseCoverMetrics(
        math.max(1, math.floor(tonumber(width) or 1)), 0, {
            title_extra = extra,
            max_h = max_h,
            min_cols = COLS,
            max_cols = COLS,
        })
    if ch > max_h then
        ch = max_h
        cw = math.max(1, math.min(slot_w, math.floor(ch * 2 / 3)))
        cell_h = ch + extra
    end
    area_h = math.floor(tonumber(area_h) or 0)
    if area_h > 0 then
        local gaps = row_gap * (ROWS - 1)
        if cell_h * ROWS + gaps > area_h then
            local fit_cell = math.max(1, math.floor((area_h - gaps) / ROWS))
            ch = math.max(1, math.min(ch, fit_cell - extra))
            cw = math.max(1, math.min(slot_w, math.floor(ch * 2 / 3)))
            cell_h = math.min(ch + extra, fit_cell)
        end
    end
    return slot_w, cw, ch, gap, row_gap, cell_h
end

--- 分页条高度：On Deck 最多 10 本 > 一页 4 本，恒有分页。
---@return integer
local function pagerHeight()
    return MAX_BOOKS > COLS * ROWS and Theme.px(Theme.current().control.height) or 0
end

function M:heightRange(_ctx, opts)
    local _slot_w, _cw, _ch, _gap, row_gap, cell_h = gridMetrics(tonumber(opts and opts.width) or 0)
    return { height = cell_h * ROWS + row_gap * (ROWS - 1) + pagerHeight() }
end

function M:onActivate()
    if self.job or (self.loaded_at and os.time() - self.loaded_at < TTL) then return end
    local source = require("source.registry").resolve(ID) --[[@as KavitaSource|nil]]
    if not (source and source:configured() and require("ui/network/manager"):isConnected()) then return end
    self.job = source.client:json("POST", "/api/Series/on-deck", { pageNumber = 1, pageSize = MAX_BOOKS }, {},
        function(list, err)
            self.job = nil
            self.loaded_at, self.err = os.time(), err
            if list then
                local books = {}
                for idx, series in ipairs(list) do
                    local pages = tonumber(series.pages) or 0
                    books[idx] = {
                        source_id = ID,
                        stable_id = tostring(series.id),
                        title = series.name,
                        percent = pages > 0 and math.min(100, (tonumber(series.pagesRead) or 0) * 100 / pages) or 0,
                    }
                end
                self.data = books
            end
            self:refresh()
        end)
end

function M:onDeactivate()
    if self.job then
        self.job:cancel()
        self.job = nil
    end
end

---@param w integer
---@param h integer
---@param text string
---@return table
local function hint(w, h, text)
    return CenterContainer:new{
        dimen = Geom:new{ w = w, h = h },
        Text.line("body", text, { width = w, color = Theme.current().color.muted }),
    }
end

function M:createWidget()
    local ctx, w, h = self.ctx, self.opts.width, self.opts.height
    local books = self.data
    if not books then return hint(w, h, self.err or _("联网后显示 Kavita 上在读的书")) end
    if #books == 0 then return hint(w, h, _("Kavita 上没有在读的书")) end
    local page_size = COLS * ROWS
    local pages = math.max(1, math.ceil(#books / page_size))
    local pager_h = pages > 1 and Theme.px(Theme.current().control.height) or 0
    local grid_h = math.max(1, h - pager_h)
    local slot_w, cw, ch, gap, row_gap = gridMetrics(w, grid_h)
    local page = math.max(1, math.min(self.page or 1, pages))
    self.page = page
    local first = (page - 1) * page_size + 1
    local last = math.min(#books, first + page_size - 1)
    local grid = VerticalGroup:new{ align = "center" }
    local row, col = nil, 0
    for i = first, last do
        if not row or col == COLS then
            if row then grid[#grid + 1] = VerticalSpan:new{ width = row_gap } end
            row, col = HorizontalGroup:new{ align = "top" }, 0
            grid[#grid + 1] = row
        end
        col = col + 1
        if col > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        local book = books[i]
        -- 跟最近阅读列表同一条路：Book.widget 居中封面 + 标题，槽宽用 slot_w。
        local cell = Book.widget(ctx.plugin, nil, book, cw, ch, {
            slot_w = slot_w,
            badge = false,
            ribbon = false,
            download = false,
            show_parent = ctx.desktop,
        })
        row[#row + 1] = Tap.wrap(cell, function() Base.openBook(ctx, book) end)
    end
    local out = VerticalGroup:new{
        align = "center",
        CenterContainer:new{ dimen = Geom:new{ w = w, h = grid_h }, grid },
    }
    if pages > 1 then
        out[#out + 1] = Pager.widget({
            width = w,
            page = page,
            pages = pages,
            on_prev = function() self.page = page - 1; self:refresh() end,
            on_next = function() self.page = page + 1; self:refresh() end,
        })
    end
    return out
end

return M
