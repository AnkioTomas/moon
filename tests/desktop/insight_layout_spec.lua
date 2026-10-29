--[[--
desktop.pages.insight.layout：卡片显隐开关，以及剩余块拉伸 / 收缩填满可用高度。

@module tests.desktop.pages.insight_layout_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
local Themed = require("support.theme_stubs")
Themed.install()

Kit.sections.insight = { hidden_pages = {}, hidden_cards = {} }
local Layout = require("desktop.pages.insight.layout")

--- 高度 = base + extra 的假块。
local function block(id, base, extra_range)
    local built = { calls = 0 }
    return setmetatable(built, { __index = {
        id = id, lo = extra_range and extra_range[1], hi = extra_range and extra_range[2],
        build = function(extra)
            built.calls = built.calls + 1
            built.last = extra
            return { getSize = function() return { w = 10, h = base + extra } end }
        end,
    } })
end

-- 关掉的卡片不 build；开关落盘。
local a, b = block("a", 100, { 0, math.huge }), block("b", 100)
Layout.toggleCard("p", "b")
Assert.is_false(Layout.shown("p", "b"))
Layout.stack("p", { a, b }, 100, 1000)
Assert.eq(b.calls, 0)
Layout.toggleCard("p", "b")
Assert.is_true(Layout.shown("p", "b"))

-- 余量先给能长的块；够不着的块不动。
local grow, fixed = block("a", 100, { 0, math.huge }), block("b", 100)
Layout.stack("p", { grow, fixed }, 100, 500)
Assert.is_true(grow.last > 0, "可拉伸块拿到余量")
Assert.eq(fixed.last, 0)

-- 放不下时让能收缩的块让出。
local shrink = block("a", 300, { -120, 0 })
local other = block("b", 300)
Layout.stack("p", { shrink, other }, 100, 500)
Assert.is_true(shrink.last < 0 and shrink.last >= -120)

-- 最后一页不许关。
local cfg = Kit.sections.insight
for _, page in ipairs(Layout.catalog()) do
    if page.id ~= "day" then Assert.is_true(Layout.togglePage(page.id)) end
end
Assert.is_false(Layout.togglePage("day"))
Assert.eq(#Layout.pages(), 1)
cfg.hidden_pages = {}

-- 残缺配置：hidden_* 缺失时不当崩，当成全显示。
cfg.hidden_pages, cfg.hidden_cards = nil, nil
Assert.is_true(#Layout.pages() >= 1)
Assert.is_true(Layout.shown("day", "rings"))
Assert.is_true(Layout.pageShown("day"))
Assert.eq(type(cfg.hidden_pages), "table", "读路径写回空表")
Assert.eq(type(cfg.hidden_cards), "table")

-- 统计页总开关只控制桌面入口，不改各页和卡片的显隐配置。
Kit.sections.desktop = {}
package.preload["ui.themes.widgets.row"] = function()
    return { widget = function(opts) return opts end }
end
package.loaded["ui.themes.widgets.row"] = nil
local InsightSettings = require("desktop.pages.setting.insight")
local updates = 0
local desktop = { updateView = function() updates = updates + 1 end }
local hidden_pages, hidden_cards = cfg.hidden_pages, cfg.hidden_cards
local function toggleRow()
    return InsightSettings:sections(desktop)[1].rows[1](600)
end
Assert.is_true(toggleRow().toggle, "旧配置默认显示统计入口")
local saved = Kit.saved or 0
toggleRow().callback()
Assert.eq(Kit.sections.desktop.insight_enabled, false)
Assert.is_false(toggleRow().toggle)
Assert.eq(Kit.saved, saved + 1, "开关持久化")
Assert.eq(updates, 1, "切换后立即刷新桌面")
toggleRow().callback()
Assert.is_true(toggleRow().toggle)
Assert.eq(updates, 2)
Assert.eq(cfg.hidden_pages, hidden_pages)
Assert.eq(cfg.hidden_cards, hidden_cards)

return true
