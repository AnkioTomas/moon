--[[--
主体：随机一本。英雄卡显示一本在架书（优先未读），点按开书，右上骰子换一本。
每次回到可见换一本，同一次可见期内重建不换；只查计数和一行，不读整库。

@module koplugin.book.desktop.pages.home.random
--]]

local Hero = require("ui.widgets.bookhero")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local Theme = require("ui.themes")
local Button = require("ui.themes.widgets.button")
local _ = require("gettext")

---@class BookHomeRandom : BookHomeComponent
---@field book Book|nil 本次可见期抽到的书；暂停后清空
---@field last string|nil 上一次抽到的 stable_id，换一本时避开
local M = {
    id = "random",
    label = _("随机一本"),
    icon = "casino",
}
setmetatable(M, require("desktop.pages.home.base"))
M.__index = M

---@return BookHomeHeightSpec
function M:heightRange()
    return { height = Theme.px(148) }
end

--- 随机一本在架书，优先未读；只做计数加按偏移取一行，不读整库。库里不止一本时避开 exclude。
---@param source_id string|nil
---@param exclude string|nil
---@return Book|nil
function M.randomBook(source_id, exclude)
    local Catalog = require("book.catalog")
    local scope = Catalog.libraryScope(source_id)
    if not (type(scope) == "string" and scope ~= "" or type(scope) == "table" and #scope > 0) then return nil end
    for _idx, status in ipairs({ "unread", "any" }) do
        local opts = { read_status = status ~= "any" and status or nil, limit = 1 }
        local rows, count = Catalog.listBooks(scope, opts)
        if count > 0 then
            opts.offset = math.random(count) - 1
            rows = Catalog.listBooks(scope, opts)
            if rows[1] and rows[1].stable_id == exclude and count > 1 then
                opts.offset = (opts.offset + 1) % count
                rows = Catalog.listBooks(scope, opts)
            end
            return Catalog.toList(rows, 1, type(scope) == "string" and scope or nil).data[1]
        end
    end
end

--- 抽一本并记下 id。
function M:pick()
    local ctx = self.ctx
    local source = ctx.source or (ctx.desktop and ctx.desktop.source)
    self.book = M.randomBook(source and source.id, self.last)
    self.last = self.book and self.book.stable_id or self.last
end

---@return table
function M:createWidget()
    local ctx, opts = self.ctx, self.opts
    local w, h = opts.width, opts.height
    if not self.book then self:pick() end
    local book = self.book
    if not book then return M.libraryPrompt(ctx, w, h) end
    local dice = Button:new{
        icon = "casino", variant = "ghost", size = "small",
        callback = function()
            self:pick()
            self:refresh()
        end,
    }
    local dice_w = dice:getSize().w
    local card = Hero.widget(ctx.plugin, ctx.source, book, {
        width = w - dice_w,
        pad = Theme.px(10),
        cover_width = math.floor(math.max(1, h - Theme.px(12)) * 2 / 3),
        show_progress = false,
        show_parent = ctx.desktop,
        on_tap = function() M.openBook(ctx, book) end,
    })
    return HorizontalGroup:new{ align = "top", card, dice }
end

function M:onDeactivate()
    self.book = nil
end

return M
