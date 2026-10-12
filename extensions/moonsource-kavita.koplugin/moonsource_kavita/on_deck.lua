--[[--
首页组件：Kavita「继续阅读」（On Deck）。在线且已配置时拉一次，5 分钟内复用；
封面横排，点开走月读开书流程（多卷 series 会先选卷）。

@module moonsource_kavita.on_deck
--]]

local Base = require("desktop.pages.home.base")
local Book = require("ui.widgets.book")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes")
local Tap = require("ui.themes.widgets.tap")
local Text = require("ui.themes.widgets.text")
local _ = require("gettext")

local ID = "ext.kavita"
local MAX_BOOKS = 10
local TTL = 300

---@class KavitaOnDeck : BookHomeComponent
---@field job { cancel: fun() }|nil
---@field loaded_at integer|nil
---@field err string|nil
local M = {
    id = "ext.kavita.on_deck",
    label = _("Kavita 继续阅读"),
    icon = "collections_bookmark",
}
setmetatable(M, Base)
M.__index = M

function M:heightRange()
    return { height = Theme.px(200) }
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
    local gap = Theme.px(Theme.current().space.sm)
    local caption_h = Text.line("caption", "Kavita"):getSize().h
    local ch = math.max(1, h - caption_h - gap)
    local cw = math.max(1, math.floor(ch * 2 / 3))
    local count = math.min(#books, math.max(1, math.floor((w + gap) / (cw + gap))))
    local row = HorizontalGroup:new{ align = "top" }
    for i = 1, count do
        local book = books[i]
        if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        row[#row + 1] = Tap.wrap(VerticalGroup:new{
            align = "center",
            (Book.cover(ctx.plugin, nil, book, cw, ch, { show_parent = ctx.desktop })),
            VerticalSpan:new{ width = gap },
            Text.line("caption", book.title or "", { width = cw }),
        }, function() Base.openBook(ctx, book) end)
    end
    return CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, row }
end

return M
