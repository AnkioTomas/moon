--[[--
刮削搜索结果选择页。

复用 bookhero 画卡片；全屏列表 + Pager 分页，禁止 ScrollableContainer。

@module koplugin.book.desktop.detail.scrape.results
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LineWidget = require("ui/widget/linewidget")
local TitleBar = require("ui.themes.widgets.titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TopContainer = require("ui/widget/container/topcontainer")
local Hero = require("ui.widgets.bookhero")
local Box = require("ui.themes.widgets.box")
local Modal = require("ui.themes.widgets.modal")
local Pager = require("ui.themes.widgets.pager")
local Theme = require("ui.themes")
local _ = require("gettext")
local T = require("ffi/util").template

local Screen = Device.screen

--- 按可用高度把卡片切成多页。单件超高仍占一页，空列表也留一页。
---@param widgets table[]
---@param avail_h number
---@return table[]
local function pack(widgets, avail_h)
    local pages = {}
    local cur = { align = "left" }
    local used = 0
    local function flush()
        if used > 0 or #pages == 0 then
            pages[#pages + 1] = cur
        end
        cur = { align = "left" }
        used = 0
    end
    for _idx, w in ipairs(widgets) do
        local wh = w:getSize().h
        if used > 0 and used + wh > avail_h then flush() end
        cur[#cur + 1] = w
        used = used + wh
    end
    flush()
    return pages
end

local function clamp(page, pages)
    return math.max(1, math.min(page, pages)), pages
end

local Results = Modal:extend{
    name = "book_scrape_results",
    covers_fullscreen = true,
    results = nil,
    source = nil,
    on_pick = nil,
    page = 1,
}

--- 出版信息一行：出版社 · 年份 · 评分，全空则返回 nil。
---@param result table
---@return string|nil
local function factsLine(result)
    local parts = {}
    if result.publisher and result.publisher ~= "" then
        parts[#parts + 1] = result.publisher
    end
    if result.year and result.year ~= "" then
        parts[#parts + 1] = result.year
    end
    if result.rating and result.rating ~= "" then
        parts[#parts + 1] = T(_("评分 %1"), result.rating)
    end
    if #parts == 0 then
        return nil
    end
    return table.concat(parts, " · ")
end

--- 单条结果卡：hero + 底部分隔线。
---@param self table
---@param result table
---@param width number
---@return table
local function buildCard(self, result, width)
    local t = Theme.current()
    local gap = Theme.px(t.space.md)
    local row = select(1, Hero.widget(nil, nil, {
        title = result.title,
        authors = result.author,
        intro = result.intro,
        cover_url = result.cover_url,
        cover_headers = result.cover_headers,
        percent = 0,
    }, {
        width = width,
        pad = 0,
        show_parent = self,
        show_progress = false,
        subtitle = factsLine(result),
        src = result.cover_url ~= "" and result.cover_url or nil,
        headers = result.cover_headers,
        on_tap = function()
            self:pick(result)
        end,
    }))
    return VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = gap },
        row,
        VerticalSpan:new{ width = gap },
        LineWidget:new{
            background = Blitbuffer.Color8(t.color.rule),
            dimen = Geom:new{ w = width, h = math.max(1, Theme.px(t.row.divider)) },
        },
    }
end

function Results:init()
    Modal.init(self)
    self:updateView()
end

--- 关闭结果页并强制重绘下层。
---@return boolean
function Results:onClose()
    UIManager:close(self)
    UIManager:nextTick(function()
        UIManager:setDirty("all", "full")
    end)
    return true
end

--- 选中一条结果：先关页面，再交给调用方落库。
--- 选中路径的刷新由 on_pick 完成后自己发起，这里不能再走 close_callback。
---@param result table
function Results:pick(result)
    local pick = self.on_pick
    self.close_callback = nil
    self:onClose()
    pick(result)
end

--- 重建标题栏、当前页卡片与分页带。
function Results:updateView()
    local w, h = Screen:getWidth(), Screen:getHeight()
    local t = Theme.current()
    local pad = Theme.px(t.space.lg)
    local content_w = w - pad * 2
    local source_name = require("desktop.detail.scrape.search").name(self.source)

    local title_bar = TitleBar.widget({
        width = w,
        title = _("选择匹配的书籍"),
        subtitle = T(_("%1 · %2 条结果"), source_name, #self.results),
        right_icon = "close",
        right_callback = function()
            self:onClose()
        end,
    })

    local pager_h = Theme.px(t.control.height)
    local body_h = math.max(Theme.px(80), h - TitleBar.height() - pager_h)
    if not self._pages then
        local cards = {}
        for i = 1, #self.results do
            cards[i] = buildCard(self, self.results[i], content_w)
        end
        self._pages = pack(cards, body_h)
    end

    local page, pages = clamp(self.page, #self._pages)
    self.page = page

    --- 翻页并重绘。
    ---@param n number
    local function turn(n)
        self.page = n
        self:updateView()
        UIManager:setDirty(self, "full")
    end

    self:setPanel(Box:new{
        style = { bg = t.color.page },
        width = w,
        height = h,
        VerticalGroup:new{
            align = "left",
            title_bar,
            TopContainer:new{
                dimen = Geom:new{ w = w, h = body_h },
                HorizontalGroup:new{
                    HorizontalSpan:new{ width = pad },
                    VerticalGroup:new(self._pages[page]),
                },
            },
            Pager.widget({
                width = w,
                page = page,
                pages = pages,
                range = self.dimen,
                on_page = turn,
            }),
        },
    })
end

Results.pack = pack

return Results
