---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[-- 首页钉页布局：累加内容高 / fill 吃剩余 / 自定义像素，页边界由 widgets 钉死。 --]]

local Assert = require("support.assert")

local Kit = require("support.widget_stubs")
Kit.install("paper")

Kit.sections.home = {
    home_widgets = {
        { id = "recent_hero", page = 1, order = 1, height = "default" },
        { id = "recent_list", page = 1, order = 2, height = "default" },
    },
}
local home_settings = Kit.sections.home
local build_log = {}
local ranges = {}

local function stubComponent(id)
    local M = { id = id, label = id }
    function M.new()
        return setmetatable({}, { __index = M })
    end
    function M:heightRange(_ctx, opts)
        return ranges[id] or { height = 10 }
    end
    function M:build(_ctx, opts)
        build_log[#build_log + 1] = { id = id, height = opts.height }
        return require("ui/widget/widget"):new{ dimen = { w = opts.width, h = opts.height }, _id = id }
    end
    return M
end

for _, id in ipairs({
    "clock", "weather", "clock_weather", "weather_forecast", "stats", "tiles", "heatmap", "hitokoto", "excerpt",
    "history", "news",
    "recent_hero", "recent_list", "recent_cards", "random", "shelf",
}) do
    package.preload["desktop.pages.home." .. id] = function()
        return stubComponent(id)
    end
end

local Base = require("desktop.pages.home.registry")
local Layout = require("desktop.pages.home.layout")
local Widgets = require("desktop.pages.home.placements")

Assert.len(Base.list(), 16)
local defaults = Base.enabledLayout()
Assert.len(defaults, 2)
Assert.eq(defaults[1], "recent_hero")
Assert.eq(defaults[2], "recent_list")

local components = {}
for _, class in ipairs(Base.list()) do components[class.id] = class.new() end

-- fill 吃剩余；default 用内容高度。
local selected, heights, unused = Layout.allocate({
    { id = "a", height = 30, placement = { height = "default" } },
    { id = "b", height = 30, fill = true, placement = { height = "fill" } },
}, 100, 0)
Assert.eq(heights[1], 30)
Assert.eq(heights[2], 70)
Assert.eq(unused, 0)

-- default 只用内容高；组件声明 fill 不能偷偷吃剩余。
selected, heights, unused = Layout.allocate({
    { id = "a", height = 20, placement = { height = "default" } },
    { id = "b", height = 40, fill = true, placement = { height = "default" } },
}, 100, 0)
Assert.eq(heights[1], 20)
Assert.eq(heights[2], 40)
Assert.eq(unused, 40)

-- 自定义高度不夹内容高，也不吃剩余。
selected, heights, unused = Layout.allocate({
    { id = "a", height = 20, fill = true, placement = { height = 99 } },
}, 120, 0)
Assert.eq(heights[1], 99)
Assert.eq(unused, 21)

-- 超高不跨页，整体压回 available。
selected, heights, unused = Layout.allocate({
    { id = "a", height = 40, placement = { height = "default" } },
    { id = "b", height = 40, placement = { height = "default" } },
}, 50, 0)
Assert.is_true(heights[1] + heights[2] <= 50)
Assert.eq(unused, 0)

-- 钉在第 2 页的组件不会出现在第 1 页。
home_settings.home_widgets = {
    { id = "clock", page = 1, order = 1, height = "default" },
    { id = "stats", page = 2, order = 1, height = "default" },
    { id = "recent_list", page = 2, order = 2, height = "fill" },
}
ranges.clock = { height = 30 }
ranges.stats = { height = 30 }
ranges.recent_list = { height = 60, fill = true }
build_log = {}
local _, page, pages, visible = Layout.build({ width = 320, height = 140 }, components, 1, { body_height = 140 })
Assert.eq(page, 1)
Assert.eq(pages, 2)
Assert.len(build_log, 1)
Assert.eq(build_log[1].id, "clock")
Assert.is_true(visible.clock)
Assert.is_nil(visible.stats)

build_log = {}
_, page, pages, visible = Layout.build({ width = 320, height = 140 }, components, 2, { body_height = 140 })
Assert.eq(page, 2)
Assert.len(build_log, 2)
Assert.is_true(visible.stats)
Assert.is_true(visible.recent_list)
Assert.is_true(build_log[2].height > build_log[1].height)

-- 屏幕变矮放不下（超出 25% 以上，略超由压缩消化）的钉页顺延成多页，钉页记录不动；编辑态仍按钉页。
ranges.clock = { height = 80 }
ranges.stats = { height = 80 }
ranges.recent_list = { height = 80 }
build_log = {}
_, page, pages = Layout.build({ width = 320, height = 140 }, components, 2, { body_height = 140 })
Assert.eq(pages, 3)
Assert.eq(page, 2)
Assert.eq(build_log[1].id, "stats")
Assert.len(build_log, 1)
_, _, pages = Layout.build({ width = 320, height = 140 }, components, 1, {
    body_height = 140, wrap = function(widget) return widget end,
})
Assert.eq(pages, 2)

-- 浏览态第 3 页（stats 之后拆出的 recent_list）切到编辑态时，focus 按组件定位到钉页 2，而不是页码 3 → 越界。
page = select(2, Layout.build({ width = 320, height = 140 }, components, 1, {
    body_height = 140, wrap = function(widget) return widget end, focus = "recent_list",
}))
Assert.eq(page, 2)
page = select(2, Layout.build({ width = 320, height = 140 }, components, 1, { body_height = 140, focus = "recent_list" }))
Assert.eq(page, 3)

-- 正文内框：四周 space.md，组件间 space.sm。
local inner_w, inner_h, inner_gap = Layout.metrics(320, 140)
Assert.eq(inner_w, 296)
Assert.eq(inner_h, 116)
Assert.eq(inner_gap, 8)

-- 迁移用 paginate 仍可用。
local packs = Layout.paginate({
    { id = "a", height = 30 },
    { id = "b", height = 50 },
}, 50, 8)
Assert.len(packs, 2)

-- 自定义像素高与 allocate 一致：内容高放不下，但设定高放得下就不分页（编辑态与浏览态一致）。
Assert.len(Layout.paginate({
    { id = "a", height = 80, placement = { height = 20 } },
    { id = "b", height = 80, placement = { height = 20 } },
}, 50, 8), 1)
-- 自定义更高时按内容高切页，不拆开（放不下由 allocate 压缩）。
Assert.len(Layout.paginate({
    { id = "a", height = 20, placement = { height = 80 } },
    { id = "b", height = 20, placement = { height = 80 } },
}, 50, 8), 1)

Assert.is_true(Widgets.canFit({ 20 }, 20, 50, 8))
Assert.is_false(Widgets.canFit({ 20, 20 }, 20, 50, 8))

return true
