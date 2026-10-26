--[[--
统计页的页面与卡片目录、显隐设置、纵向排版。

目录是唯一真相：设置页遍历它列开关，各页面按 id 查显隐。显隐只存「被关掉的」
（settings/insight.lua 的 hidden_pages / hidden_cards），新增的页面和卡片默认显示。

排版 `Layout.stack`：每个块 `build(extra)` 可按给定的额外高度（可正可负）重建自己。
先按 extra = 0 量出自然高度；放得下就把余量依次分给能长高的块（hi），放不下就让能收缩的块
（lo）让出高度；还有余量就匀进块间距。块里没有内容时 build 返回 nil，直接跳过。

@module koplugin.book.desktop.pages.insight.layout
--]]

local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local MoonSettings = require("utils.settings")
local Theme = require("ui.themes")
local Text = require("ui.themes.widgets.text")
local _ = require("gettext")

---@class BookInsightLayout
local Layout = {}

---@class InsightCardSpec
---@field id string
---@field label string

---@class InsightPageSpec
---@field id string
---@field label string
---@field cards InsightCardSpec[]

--- 页面与卡片目录；顺序即翻页顺序、页内从上到下的顺序。
---@return InsightPageSpec[]
function Layout.catalog()
    return {
        { id = "day", label = _("今日"), cards = {
            { id = "rings", label = _("活动环") },
            { id = "hours", label = _("阅读时段") },
            { id = "runs", label = _("阅读记录") },
            { id = "books", label = _("当日书单") },
        } },
        { id = "month", label = _("本月"), cards = {
            { id = "kpi", label = _("月度指标") },
            { id = "calendar", label = _("月历") },
            { id = "hours", label = _("阅读时段") },
        } },
        { id = "year", label = _("本年"), cards = {
            { id = "kpi", label = _("年度指标") },
            { id = "monthly", label = _("每月阅读时长") },
            { id = "heatmap", label = _("阅读热力图") },
            { id = "wall", label = _("读完的书") },
        } },
        { id = "ranks", label = _("榜单"), cards = {
            { id = "longest", label = _("最长阅读") },
            { id = "authors", label = _("常读作者") },
            { id = "category", label = _("常读题材") },
        } },
        { id = "trends", label = _("趋势"), cards = {
            { id = "compare", label = _("近 90 天对比") },
            { id = "week", label = _("本周对比") },
        } },
        { id = "goals", label = _("进度"), cards = {
            { id = "challenge", label = _("本月挑战") },
            { id = "forecast", label = _("预计读完") },
            { id = "records", label = _("连续记录与里程碑") },
        } },
    }
end

---@return table
local function config()
    return MoonSettings.get("desktop.pages.insight")
end

--- 启用的页面（保持目录顺序）；用户全关时退回全部，翻页条不能没有页。
---@return InsightPageSpec[]
function Layout.pages()
    local hidden = config().hidden_pages
    local out = {}
    for _idx, page in ipairs(Layout.catalog()) do
        if not hidden[page.id] then out[#out + 1] = page end
    end
    return #out > 0 and out or Layout.catalog()
end

---@param page_id string
---@param card_id string
---@return boolean
function Layout.shown(page_id, card_id)
    return not config().hidden_cards[page_id .. "." .. card_id]
end

---@param page_id string
---@return boolean
function Layout.pageShown(page_id)
    return not config().hidden_pages[page_id]
end

--- 切换页面显隐；只剩一页时拒绝关闭。
---@param page_id string
---@return boolean ok
function Layout.togglePage(page_id)
    local cfg = config()
    if cfg.hidden_pages[page_id] then
        cfg.hidden_pages[page_id] = nil
    else
        local shown = 0
        for _idx, page in ipairs(Layout.catalog()) do
            if not cfg.hidden_pages[page.id] then shown = shown + 1 end
        end
        if shown <= 1 then return false end
        cfg.hidden_pages[page_id] = true
    end
    MoonSettings.save("desktop.pages.insight", cfg)
    return true
end

---@param page_id string
---@param card_id string
function Layout.toggleCard(page_id, card_id)
    local cfg = config()
    local key = page_id .. "." .. card_id
    cfg.hidden_cards[key] = (not cfg.hidden_cards[key]) or nil
    MoonSettings.save("desktop.pages.insight", cfg)
end

---@class InsightBlock
---@field id string|nil 卡片 id；nil = 页面自带、不可隐藏
---@field build fun(extra: number): table|nil
---@field lo number|nil 最多收缩的高度（负数）
---@field hi number|nil 最多拉长的高度（math.huge = 不限）

--- 把一页的块排成纵向一列，填满 avail_h；被隐藏的卡片不 build。
---@param page_id string
---@param blocks InsightBlock[]
---@param width number
---@param avail_h number
---@return table
function Layout.stack(page_id, blocks, width, avail_h)
    local t = Theme.current()
    local gap = Theme.px(t.space.md)
    local items, total = {}, 0
    for _idx, block in ipairs(blocks) do
        if not block.id or Layout.shown(page_id, block.id) then
            local widget = block.build(0)
            if widget then
                local h = widget:getSize().h
                items[#items + 1] = { block = block, widget = widget, h = h }
                total = total + h
            end
        end
    end
    if #items == 0 then
        return Text.box("body", _("这一页的内容都已隐藏，可在设置里重新打开"), width,
            { align = "center", color = t.color.muted, transparent = true })
    end
    total = total + gap * (#items - 1)
    local left = avail_h - total
    for _idx, item in ipairs(items) do
        local extra
        if left > 0 and (item.block.hi or 0) > 0 then
            extra = math.min(left, item.block.hi)
        elseif left < 0 and (item.block.lo or 0) < 0 then
            extra = math.max(left, item.block.lo)
        end
        if extra then
            local widget = item.block.build(extra)
            if widget then
                local h = widget:getSize().h
                left = left - (h - item.h)
                item.widget, item.h = widget, h
            end
        end
    end
    -- 余量匀进块间距；上限两倍，免得内容少时被撕得很散。
    if left > 0 and #items > 1 then gap = gap + math.min(math.floor(left / (#items - 1)), gap * 2) end
    local col = VerticalGroup:new{ align = "left" }
    for i, item in ipairs(items) do
        if i > 1 then col[#col + 1] = VerticalSpan:new{ width = gap } end
        col[#col + 1] = item.widget
    end
    return col
end

return Layout
