--[[--
刮削搜索结果选择页。

复用 BookInfo.hero 画卡片；全屏列表 + Pager 分页，禁止 ScrollableContainer。

@module koplugin.book.scrape.results
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local BookInfo = require("ui.components.bookinfo")
local Pager = require("ui.components.pager")
local UI = require("ui.components.bookui")
local _ = require("gettext")
local T = require("ffi/util").template

local Screen = Device.screen

local Results = InputContainer:extend{
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

--- 搜索结果 → BookInfo.hero 能吃的 book 形。
---@param result table
---@return table
local function asBook(result)
    return {
        title = result.title,
        authors = result.author,
        intro = result.intro,
        cover_url = result.cover_url,
        cover_headers = result.cover_headers,
        percent = 0,
    }
end

--- 单条结果卡：hero + 底部分隔线。
---@param self table
---@param result table
---@param width number
---@return table
local function buildCard(self, result, width)
    local row = select(1, BookInfo.hero(nil, nil, asBook(result), {
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
        row,
        LineWidget:new{
            background = UI.rule(),
            dimen = Geom:new{ w = width, h = UI.line() },
        },
    }
end

--- 初始化全屏尺寸与返回键。
function Results:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end
    self:rebuild()
end

--- 返回结果页尺寸。
---@return table
function Results:getSize()
    return self.dimen
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

--- Widget 关闭时触发 close_callback。
function Results:onCloseWidget()
    local cb = self.close_callback
    self.close_callback = nil
    if cb then
        cb()
    end
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
function Results:rebuild()
    local w, h = Screen:getWidth(), Screen:getHeight()
    local pad = UI.pagePad()
    local content_w = w - pad * 2
    local source_name = self.source == "douban" and _("豆瓣") or _("微信读书")

    local title_bar = TitleBar:new{
        fullscreen = true,
        width = w,
        align = "center",
        with_bottom_line = true,
        title = _("选择匹配的书籍"),
        title_face = UI.face("cfont", 18),
        subtitle = T(_("%1 · %2 条结果"), source_name, #self.results),
        subtitle_face = UI.face("xx_smallinfofont", 12),
        button_padding = UI.sz(11),
        right_icon_size_ratio = UI.titleIconRatio(0.6),
        close_callback = function()
            self:onClose()
        end,
        show_parent = self,
    }

    local body_h = math.max(UI.sz(80), h - title_bar:getHeight() - Pager.bandH())
    if not self._pages then
        local cards = {}
        for i = 1, #self.results do
            cards[i] = buildCard(self, self.results[i], content_w)
        end
        self._pages = Pager.pack(cards, body_h)
    end

    local page, pages = Pager.clamp(self.page, #self._pages)
    self.page = page

    --- 翻页并重绘。
    ---@param n number
    local function turn(n)
        self.page = n
        self:rebuild()
        UIManager:setDirty(self, "full")
    end

    self[1] = Pager.frame(w, h, {
        top = title_bar,
        body = FrameContainer:new{
            bordersize = 0,
            padding = 0,
            padding_left = pad,
            padding_right = pad,
            margin = 0,
            background = Blitbuffer.COLOR_WHITE,
            dimen = Geom:new{ w = w, h = body_h },
            VerticalGroup:new(self._pages[page]),
        },
        page = page,
        pages = pages,
        handlers = {
            on_first = function() turn(1) end,
            on_prev = function() turn(page - 1) end,
            on_next = function() turn(page + 1) end,
            on_last = function() turn(pages) end,
        },
    })
end

return Results
