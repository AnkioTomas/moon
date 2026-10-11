--[[--
段评列表：全屏，标题栏 + 原句引用 + 段评卡片，按卡片实际高度分页；翻到已加载内容末页时自动续拉。

  +-------------------------------+
  |      段评 · 共 321 条    [×]  |
  |-------------------------------|
  | ┃ 圣人对节帅的品位……          |
  |                               |
  | 悠闲               赞 992 · … |
  | 学习了，先说别人想听的……      |
  | ----------------------------- |
  | 包子铺             赞 403 · … |
  | ……                            |
  | [<]          2 / 5+       [>] |
  +-------------------------------+

@module koplugin.book.features.reviews.sheet
--]]

require("l10n").apply()

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LineWidget = require("ui/widget/linewidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Modal = require("ui.themes.widgets.modal")
local Pager = require("ui.themes.widgets.pager")
local Text = require("ui.themes.widgets.text")
local TitleBar = require("ui.themes.widgets.titlebar")
local T = require("ffi/util").template
local _ = require("gettext")

local QUOTE_LINES = 6

---@class ReviewSheet : BookThemeModal
---@field identity BookIdentity
---@field spot { range: string, text: string, total: integer }
---@field items WechatReview[]
---@field cards table[] 按 items 下标缓存的卡片
---@field pages { [1]: integer, [2]: integer }[] 每页的 items 起止下标
---@field page integer
---@field max_idx integer
---@field more boolean
---@field loaded boolean 首批已到
---@field job { cancel: fun() }|nil
---@field turn_after_load boolean 用户在末页点了下一页，续拉回来后翻过去
local Sheet = Modal:extend{
    mask = false,
    identity = nil,
    spot = nil,
}

function Sheet:init()
    Modal.init(self)
    local t = self.theme
    self.pad = Theme.px(t.space.lg)
    self.inner_w = self.dimen.w - self.pad * 2
    self.body_h = self.dimen.h - TitleBar.height() - Theme.px(t.control.height) - self.pad * 2
    self.items, self.cards, self.page, self.max_idx, self.more = {}, {}, 1, 0, true
    self.ges_events.SwipeSheet = { GestureRange:new{ ges = "swipe", range = self.dimen } }
    self.close_callback = function()
        if self.job then self.job.cancel() end
        self.job = nil
    end
    self:paginate()
    self:rebuild()
    self:load()
end

--- 横线分隔（引用竖条也用它）。
---@param w number
---@param h number
---@param color integer 灰度令牌
---@return table
local function rule(w, h, color)
    return LineWidget:new{ background = Blitbuffer.Color8(color), dimen = Geom:new{ w = w, h = h } }
end

---@return table
function Sheet:quote()
    if self.quote_widget then return self.quote_widget end
    local t = self.theme
    local bar_w, gap = Theme.px(t.space.xs) - 1, Theme.px(t.space.md)
    local text = Text.box("body", self.spot.text, self.inner_w - bar_w - gap,
        { color = t.color.muted, max_lines = QUOTE_LINES })
    self.quote_widget = VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{
            align = "top",
            rule(bar_w, text:getSize().h, t.color.rule),
            HorizontalSpan:new{ width = gap },
            text,
        },
        VerticalSpan:new{ width = Theme.px(t.space.lg) },
    }
    return self.quote_widget
end

--- 卡片之间的分隔高度。
---@return number
function Sheet:gap()
    local t = self.theme
    return Theme.px(t.space.md) * 2 + Theme.px(t.row.divider)
end

--- 第 i 条段评的卡片：作者（粗）+ 右侧「赞 · 日期」+ 正文；正文过长截到一页内。
---@param i integer
---@return table
function Sheet:card(i)
    if self.cards[i] then return self.cards[i] end
    local t, w = self.theme, self.inner_w
    local item = self.items[i]
    local meta = Text.line("caption", T(_("赞 %1 · %2"), item.likes, os.date("%Y-%m-%d", item.time)),
        { color = t.color.faint })
    local gap = Theme.px(t.space.sm)
    local author = Text.line("body", item.author, { bold = true, width = w - meta:getSize().w - gap })
    local head = HorizontalGroup:new{
        align = "center",
        author,
        HorizontalSpan:new{ width = w - author:getSize().w - meta:getSize().w },
        meta,
    }
    local space = Theme.px(t.space.xs)
    local content = Text.box("body", item.content, w)
    local room = self.body_h - head:getSize().h - space
    if content:getSize().h > room then
        local lines = math.max(1, math.floor(room / content:getLineHeight()))
        content:free()
        content = Text.box("body", item.content, w, { max_lines = lines })
    end
    self.cards[i] = VerticalGroup:new{ align = "left", head, VerticalSpan:new{ width = space }, content }
    return self.cards[i]
end

--- 按卡片高度贪心分页；首页先放原句。没有段评时也保留一页。
function Sheet:paginate()
    local pages, first, used = {}, 1, self:quote():getSize().h
    for i = 1, #self.items do
        local h = self:card(i):getSize().h
        if i > first then h = h + self:gap() end
        if i > first and used + h > self.body_h then
            pages[#pages + 1] = { first, i - 1 }
            first, used = i, 0
            h = self:card(i):getSize().h
        end
        used = used + h
    end
    pages[#pages + 1] = { first, #self.items }
    self.pages = pages
end

function Sheet:rebuild()
    local t = self.theme
    local w, pad = self.dimen.w, self.pad
    local body = VerticalGroup:new{ align = "left" }
    if self.page == 1 then body[#body + 1] = self:quote() end
    local range = self.pages[self.page]
    if #self.items == 0 then
        body[#body + 1] = Text.line("body", self.loaded and _("暂无段评") or _("正在加载段评…"),
            { color = t.color.faint })
    end
    for i = range[1], range[2] do
        if i > range[1] then
            body[#body + 1] = VerticalSpan:new{ width = Theme.px(t.space.md) }
            body[#body + 1] = rule(self.inner_w, Theme.px(t.row.divider), t.color.rule)
            body[#body + 1] = VerticalSpan:new{ width = Theme.px(t.space.md) }
        end
        body[#body + 1] = self:card(i)
    end
    local pages = #self.pages
    local bar = TitleBar.widget({
        width = w,
        title = self.loaded and T(_("段评 · 共 %1 条"), self.total) or _("段评"),
        right_icon = "close",
        right_callback = function() self:dismiss() end,
    })
    local content = HorizontalGroup:new{
        HorizontalSpan:new{ width = pad },
        VerticalGroup:new{ align = "left", VerticalSpan:new{ width = pad }, body },
    }
    self:setPanel(Box:new{
        style = { bg = t.color.page },
        width = w,
        height = self.dimen.h,
        VerticalGroup:new{
            align = "left",
            bar,
            content,
            VerticalSpan:new{ width = math.max(0, self.dimen.h - bar:getSize().h - content:getSize().h
                - Theme.px(t.control.height)) },
            Pager.widget({
                width = w,
                page = self.page,
                pages = pages + (self.more and self.loaded and 1 or 0),
                title = string.format("%d / %d%s", self.page, pages, self.more and "+" or ""),
                on_prev = function() self:turn(-1) end,
                on_next = function() self:turn(1) end,
            }),
        },
    })
end

function Sheet:refresh()
    self:rebuild()
    UIManager:setDirty(self, "ui")
end

--- 拉下一批并追加；未联网立即提示，不留悬挂状态。
function Sheet:load()
    if self.job or not self.more then return end
    local Toast = require("ui.themes.widgets.toast")
    if not require("ui/network/manager"):isConnected() then
        Toast:new{ text = _("未联网，无法加载段评"), timeout = 2 }:show()
        self.turn_after_load = false
        return
    end
    local source = self.identity.source --[[@as ParagraphReviewSource]]
    self.job = source:paragraphReviewPageAsync(self.identity, self.spot.range, self.max_idx, function(page, err)
        self.job = nil
        if not page then
            Toast:new{ text = err or _("无法获取段评"), timeout = 2 }:show()
            self.turn_after_load = false
            if not self.loaded then self:close() end
            return
        end
        for _idx, item in ipairs(page.items) do self.items[#self.items + 1] = item end
        self.loaded, self.total, self.max_idx = true, page.total, page.max_idx
        self.more = page.more and #page.items > 0
        self:paginate()
        if self.turn_after_load and self.page < #self.pages then self.page = self.page + 1 end
        self.turn_after_load = false
        self:refresh()
    end)
end

--- 翻页；到末页时预取下一批，越过末页则等续拉回来再翻。
---@param dir integer 1 或 -1
function Sheet:turn(dir)
    local target = self.page + dir
    if target < 1 then return end
    if target > #self.pages then
        if not self.more then return end
        self.turn_after_load = true
        self:load()
        return
    end
    self.page = target
    if self.page == #self.pages then self:load() end
    self:refresh()
end

---@param _arg any
---@param ges table
---@return boolean
function Sheet:onSwipeSheet(_arg, ges)
    local dir = require("ui/bidi").flipDirectionIfMirroredUILayout(ges.direction)
    if dir == "west" then
        self:turn(1)
    elseif dir == "east" then
        self:turn(-1)
    else
        return false
    end
    return true
end

--- 打开某句的段评；未联网立即提示。
---@param identity BookIdentity 章会话身份（属主源提供 paragraphReviewPageAsync）
---@param spot { range: string, text: string, total: integer }
function Sheet.open(identity, spot)
    if not require("ui/network/manager"):isConnected() then
        require("ui.themes.widgets.toast"):new{ text = _("未联网，无法加载段评"), timeout = 2 }:show()
        return
    end
    Sheet:new{ identity = identity, spot = spot }:show()
end

return Sheet
