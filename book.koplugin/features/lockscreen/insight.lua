--[[--
锁屏背景：统计页面。把桌面「统计」页签里的整页（今日 / 本月 / 本年 / 榜单 / 趋势 / 进度）
直接构建成整屏 widget 铺底，页面与卡片显隐沿用统计页自己的设置。

设置项 lock_screen_insight_page 指定其一，或 random：按本地日期在统计页当前显示的页面里固定挑一页。
数据读当前源的本地洞察（Catalog.readingInsight），不触网；页面是静态快照，点按回调不会触发。

@module koplugin.book.features.lockscreen.insight
--]]

local Library = require("features.lockscreen.components.library")
local MoonSettings = require("utils.settings")
local StatsDB = require("book.stats_db")
local _ = require("gettext")

local M = {}

local DEFAULT_PAGE = "random"

--- 统计页目录（含被用户隐藏的页）。
---@return InsightPageSpec[]
local function catalog()
    return require("desktop.pages.insight.layout").catalog()
end

--- 页面设置是否合法（含 random）。
---@param id string|nil
---@return boolean
function M.validPage(id)
    if id == DEFAULT_PAGE then return true end
    for _idx, spec in ipairs(catalog()) do
        if spec.id == id then return true end
    end
    return false
end

--- 当前设置；未设置或非法按 random。
---@return string
function M.page()
    local id = MoonSettings.get("features.lockscreen").lock_screen_insight_page
    return M.validPage(id) and id or DEFAULT_PAGE
end

--- 实际要画的页 id：random 在统计页当前显示的页面里按本地日期固定挑一页。
---@return string
local function resolved()
    local id = M.page()
    if id ~= DEFAULT_PAGE then return id end
    local shown = require("desktop.pages.insight.layout").pages()
    return shown[math.floor(os.time() / 86400) % #shown + 1].id
end

--- 组合图缓存键：页面 + 当前源阅读总时长（读了书就更新）。
---@return string
function M.cache_key()
    local summary = StatsDB.summaryBySource(Library.activeSourceId())
    return resolved() .. ":" .. tostring(summary.total_seconds or 0)
end

---@return {text: string, value: string}[]
function M.pageOptions()
    local options = { { text = _("每天随机"), value = DEFAULT_PAGE } }
    for _idx, spec in ipairs(catalog()) do options[#options + 1] = { text = spec.label, value = spec.id } end
    return options
end

---@param id string|nil
---@return string
function M.pageLabel(id)
    for _idx, option in ipairs(M.pageOptions()) do
        if option.value == id then return option.text end
    end
    return _("每天随机")
end

--- 整屏统计页：页名 + 统计页同款页面；没有统计数据时给空态文字。
---@param rect table 全屏矩形
---@return table[]
function M.blocks(rect)
    local w, h = rect.w, rect.h
    local Theme = require("ui.themes")
    local Text = require("ui.themes.widgets.text")
    local Box = require("ui.themes.widgets.box")
    local Insight = require("desktop.pages.insight")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local t = Theme.current()
    local pad = Theme.px(t.space.md)
    local width = w - pad * 2

    local state = Insight.stateOf(require("book.catalog").readingInsight(Library.activeSourceId()))
    if not state.has_data then
        return {{
            text = _("暂无阅读统计"), x = math.floor(w * 0.1), y = math.floor(h * 0.47),
            width = math.floor(w * 0.8), size = 22, bold = true, align = "center", box = false,
        }}
    end

    local id = resolved()
    local label = Text.line("title", M.pageLabel(id), { width = width })
    local head_h = label:getSize().h + pad
    local inner_h = math.max(1, h - pad * 2 - head_h)
    local body = require(Insight.PAGE_MODULES[id]):build({
        desktop = {
            source = require("source.registry").current(),
            updateView = function() end,
            insight = { switchPage = function() end },
        },
        state = state, width = width, height = inner_h, open_book = function() end,
    })
    local page = Box:new{
        style = { bg = t.color.page }, width = w, height = h, padding = pad,
        VerticalGroup:new{
            align = "left",
            label,
            VerticalSpan:new{ width = pad },
            body,
            VerticalSpan:new{ width = math.max(0, inner_h - body:getSize().h) },
        },
    }
    return {{ kind = "widget", widget = page, x = 0, y = 0, width = w, height = h }}
end

return M
