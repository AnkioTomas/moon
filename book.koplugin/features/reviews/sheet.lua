--[[--
段评列表：全屏，标题栏 + 原句引用 + 段评卡片，按卡片实际高度分页；翻到已加载内容末页时自动续拉。
标题栏左侧 [✦] 是「AI 归纳」（已加载到段评且 AI 已配置才有，见 digest.lua）。

  +-------------------------------+
  | [✦]  段评 · 共 321 条    [×]  |
  |-------------------------------|
  | ❝ 圣人对节帅的品位……          |
  |                               |
  | 👤 悠闲        👍 992 2025-… |
  | 学习了，先说别人想听的……      |
  | ----------------------------- |
  | 👤 包子铺      👍 403 2024-… |
  | ……                            |
  | [<]          2 / 5+       [>] |
  +-------------------------------+

@module koplugin.book.features.reviews.sheet
--]]

require("l10n").apply()

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LineWidget = require("ui/widget/linewidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Icon = require("ui.themes.widgets.icon")
local Image = require("ui.themes.widgets.image")
local Modal = require("ui.themes.widgets.modal")
local Pager = require("ui.themes.widgets.pager")
local Text = require("ui.themes.widgets.text")
local TitleBar = require("ui.themes.widgets.titlebar")
local T = require("ffi/util").template
local _ = require("gettext")

local QUOTE_LINES = 6
local MAX_THUMBS = 3
local IMAGE_HEADERS = { Referer = "https://fanqienovel.com/" }

--- 全屏查看段评配图；按比例缩进屏幕（不拉变形），点任意处或返回键退出。
---@param url string
local function showImage(url)
    local viewer = Modal:new{ covers_fullscreen = true, close_on_tap = true }
    local image = Image.widget{
        src = url,
        headers = IMAGE_HEADERS,
        width = viewer.dimen.w,
        height = viewer.dimen.h,
        stretch = true,
    }
    viewer.close_callback = function() image[1]:cancel() end
    viewer:setPanel(Box:new{
        style = { bg = viewer.theme.color.page },
        width = viewer.dimen.w,
        height = viewer.dimen.h,
        image,
    })
    viewer:show()
end

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
    covers_fullscreen = true,
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
    local gap = Theme.px(t.space.sm)
    local mark = Icon.widget{ name = "format_quote", size = t.control.icon, color = Blitbuffer.Color8(t.color.faint) }
    local text = Text.box("body", self.spot.text, self.inner_w - mark:getSize().w - gap,
        { color = t.color.muted, max_lines = QUOTE_LINES })
    self.quote_widget = VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{
            align = "top",
            mark,
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

--- 第 i 条段评的卡片；正文过长截到一页内，点按卡片分页查看完整正文。
---@param i integer
---@return table
function Sheet:card(i)
    if self.cards[i] then return self.cards[i] end
    local t, w = self.theme, self.inner_w
    local item = self.items[i]
    local faint = Blitbuffer.Color8(t.color.faint)
    local gap = Theme.px(t.space.sm)
    local meta = HorizontalGroup:new{
        align = "center",
        Icon.label{ name = "thumb_up", text = tostring(item.likes), size = t.font.body,
            color = faint, font_size = t.font.caption },
        HorizontalSpan:new{ width = gap },
        Text.line("caption", os.date("%Y-%m-%d", item.time) --[[@as string]], { color = t.color.faint }),
    }
    local avatar = Icon.widget{ name = "account_circle", size = t.font.title + 3,
        color = Blitbuffer.Color8(t.color.muted) }
    local fixed = avatar:getSize().w + gap + meta:getSize().w + gap
    local author = Text.line("body", item.author, { bold = true, width = w - fixed })
    local head = HorizontalGroup:new{
        align = "center",
        avatar,
        HorizontalSpan:new{ width = gap },
        author,
        HorizontalSpan:new{ width = w - fixed + gap - author:getSize().w },
        meta,
    }
    local space = Theme.px(t.space.xs)
    local pics = self:thumbs(item.images or {})
    local pics_h = pics and pics:getSize().h + space or 0
    local content = Text.box("body", item.content, w)
    local room = self.body_h - head:getSize().h - space - pics_h
    local truncated = content:getSize().h > room
    if truncated then
        local lines = math.max(1, math.floor(room / content:getLineHeight()))
        content:free()
        content = Text.box("body", item.content, w, { max_lines = lines })
    end
    local card = VerticalGroup:new{ align = "left", head, VerticalSpan:new{ width = space }, content }
    if pics then
        card[#card + 1] = VerticalSpan:new{ width = space }
        card[#card + 1] = pics
    end
    self.cards[i] = require("ui.themes.widgets.tap").wrap(card, truncated and function()
        require("ui.themes.widgets.text_viewer"):new{
            title = _("段评") .. " · " .. item.author,
            text = item.content,
        }:show()
    end or nil)
    return self.cards[i]
end

--- 评论配图缩略图一行（固定方块，保证分页高度可算）；至多 MAX_THUMBS 张，多出的在末尾标张数。
---@param images { url: string }[]
---@return table|nil
function Sheet:thumbs(images)
    if #images == 0 then return nil end
    local t = self.theme
    local gap = Theme.px(t.space.sm)
    local size = math.min(math.floor((self.inner_w - gap * (MAX_THUMBS - 1)) / MAX_THUMBS), math.floor(self.body_h / 5))
    local row = HorizontalGroup:new{ align = "center" }
    for n = 1, math.min(#images, MAX_THUMBS) do
        if n > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        local image = images[n]
        row[#row + 1] = require("ui.themes.widgets.tap").wrap(
            Image.widget{ src = image.url, headers = IMAGE_HEADERS, width = size, height = size },
            function() showImage(image.url) end)
    end
    if #images > MAX_THUMBS then
        row[#row + 1] = HorizontalSpan:new{ width = gap }
        row[#row + 1] = Text.line("caption", T(_("共 %1 张"), #images), { color = t.color.faint })
    end
    return row
end

--- 按卡片高度贪心分页；首页先放原句。没有段评时也保留一页。
function Sheet:paginate()
    local pages, first, used = {}, 1, self:quote():getSize().h
    for i = 1, #self.items do
        local h = self:card(i):getSize().h
        if i > first then h = h + self:gap() end
        if used > 0 and used + h > self.body_h then
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
        body[#body + 1] = Icon.label{ name = "forum", text = self.loaded and _("暂无段评") or _("正在加载段评…"),
            size = t.control.icon, color = Blitbuffer.Color8(t.color.faint),
            face = "cfont", font_size = t.font.body, gap = Theme.px(t.space.sm) }
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
    local can_digest = #self.items > 0 and require("ai").isConfigured()
    local bar = TitleBar.widget({
        width = w,
        title = self.loaded and T(_("段评 · 共 %1 条"), self.total) or _("段评"),
        left_icon = can_digest and "auto_awesome" or nil,
        left_callback = can_digest and function()
            require("features.reviews.digest").run(self.spot.text, self.items)
        end or nil,
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
                cycle = not self.more,
                title = string.format("%d / %d%s", self.page, pages, self.more and "+" or ""),
                range = self.dimen,
                on_page = function(page) self:turn(page - self.page) end,
            }),
        },
    })
end

function Sheet:refresh()
    self:rebuild()
    UIManager:setDirty(self, "ui")
end

--- 拉下一批并追加；在线取最新、离线读缓存，没缓存又没网时源立即回错。
function Sheet:load()
    if self.job or not self.more then return end
    local Toast = require("ui.themes.widgets.toast")
    local source = self.identity.source --[[@as ParagraphReviewSource]]
    local done = false
    local job = source:paragraphReviewPageAsync(self.identity, self.spot.range, self.max_idx, function(page, err)
        done, self.job = true, nil
        if not page then
            Toast:new{ text = err or _("无法获取段评"), timeout = 2 }:show()
            self.turn_after_load = false
            if not self.loaded then self:close() end
            return
        end
        if not self.loaded then self.spot.total = page.total end
        for _idx, item in ipairs(page.items) do self.items[#self.items + 1] = item end
        self.loaded, self.total, self.max_idx = true, page.total, page.max_idx
        self.more = page.more and #page.items > 0
        self:paginate()
        if self.turn_after_load and self.page < #self.pages then self.page = self.page + 1 end
        self.turn_after_load = false
        self:refresh()
    end)
    if not done then self.job = job end
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

--- 打开某句的段评；在线取最新，离线且没缓存由源立即回错。
---@param identity BookIdentity 章会话身份（属主源提供 paragraphReviewPageAsync）
---@param spot { range: string, text: string, total: integer }
function Sheet.open(identity, spot)
    Sheet:new{ identity = identity, spot = spot }:show()
end

return Sheet
