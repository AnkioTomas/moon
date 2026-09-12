--[[-- 首页钉页布局：default / fill / 自定义，页边界由 widgets 钉死。 --]]

local Assert = require("support.assert")

local home_settings = {
    home_widgets = {
        { id = "recent_hero", page = 1, order = 1, height = "default" },
        { id = "recent_list", page = 1, order = 2, height = "default" },
    },
}
package.preload["utils.settings"] = function()
    return {
        get = function() return home_settings end,
        saveSection = function(_, _, values) home_settings = values end,
    }
end
package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(s) return s end end

local layout_kids = {}
local build_log = {}
local ranges = {}

local function widgetStub()
    return {
        new = function(_, opts)
            if opts and opts.align then layout_kids = opts end
            return opts or {}
        end,
    }
end

package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE = 255 } end
package.preload["ui/widget/container/framecontainer"] = widgetStub
package.preload["ui/geometry"] = widgetStub
package.preload["ui/widget/verticalgroup"] = widgetStub
package.preload["ui/widget/verticalspan"] = widgetStub
package.preload["ui.components.bookui"] = function()
    return { sz = function(n) return n end, topBarH = function() return 30 end }
end

local function stubComponent(id)
    local M = { id = id, label = id }
    function M.new()
        return setmetatable({}, { __index = M })
    end
    function M:heightRange(_ctx, opts)
        return ranges[id] or { min = 10, preferred = 10, max = 10, grow = 1 }
    end
    function M:build(_ctx, opts)
        build_log[#build_log + 1] = { id = id, height = opts.height }
        return { widget = { _id = id }, height = opts.height }
    end
    return M
end

for _, id in ipairs({
    "clock", "weather", "clock_weather", "stats", "hitokoto", "excerpt",
    "history", "news",
    "recent_hero", "recent_list", "recent_cards",
}) do
    package.preload["ui.desktop.home.views." .. id] = function()
        return stubComponent(id)
    end
end

local Base = require("ui.desktop.home.registry")
local Layout = require("ui.desktop.home.layout")
local Widgets = require("ui.desktop.home.widgets")

Assert.len(Base.components, 11)
local defaults = Base.enabledLayout()
Assert.len(defaults, 2)
Assert.eq(defaults[1], "recent_hero")
Assert.eq(defaults[2], "recent_list")

local layout = Layout.new()
local components = {}
for _, class in ipairs(Base.components) do components[class.id] = class.new() end

-- fill 吃剩余；default 用 preferred。
local selected, heights, unused = layout:allocate({
    { id = "a", min = 20, preferred = 30, max = 50, grow = 1, placement = { height = "default" } },
    { id = "b", min = 20, preferred = 30, max = 100, grow = 2, placement = { height = "fill" } },
}, 100, 0)
Assert.eq(heights[1], 30)
Assert.eq(heights[2], 70)
Assert.eq(unused, 0)

-- 自定义高度夹在 min/max。
selected, heights = layout:allocate({
    { id = "a", min = 10, preferred = 20, max = 40, grow = 0, placement = { height = 99 } },
}, 50, 0)
Assert.eq(heights[1], 40)

-- 超高不跨页，整体压回 available。
selected, heights, unused = layout:allocate({
    { id = "a", min = 40, preferred = 40, max = 40, grow = 0, placement = { height = "default" } },
    { id = "b", min = 40, preferred = 40, max = 40, grow = 0, placement = { height = "default" } },
}, 50, 0)
Assert.is_true(heights[1] + heights[2] <= 50)
Assert.eq(unused, 0)

-- 钉在第 2 页的组件不会出现在第 1 页。
home_settings.home_widgets = {
    { id = "clock", page = 1, order = 1, height = "default" },
    { id = "stats", page = 2, order = 1, height = "default" },
    { id = "recent_list", page = 2, order = 2, height = "fill" },
}
ranges.clock = { min = 20, preferred = 30, max = 40, grow = 1 }
ranges.stats = { min = 20, preferred = 30, max = 40, grow = 1 }
ranges.recent_list = { min = 40, preferred = 60, max = 100, grow = 4 }
build_log = {}
local _, page, pages, visible = layout:build({ width = 320, height = 140 }, components, 1, { body_height = 140 })
Assert.eq(page, 1)
Assert.eq(pages, 2)
Assert.len(build_log, 1)
Assert.eq(build_log[1].id, "clock")
Assert.is_true(visible.clock)
Assert.is_nil(visible.stats)

build_log = {}
_, page, pages, visible = layout:build({ width = 320, height = 140 }, components, 2, { body_height = 140 })
Assert.eq(page, 2)
Assert.len(build_log, 2)
Assert.is_true(visible.stats)
Assert.is_true(visible.recent_list)
Assert.is_true(build_log[2].height > build_log[1].height)

-- 迁移用 paginate 仍可用。
local packs = layout:paginate({
    { id = "a", min = 20, preferred = 30, grow = 0 },
    { id = "b", min = 30, preferred = 50, grow = 0 },
}, 50, 8)
Assert.len(packs, 2)

Assert.is_true(Widgets.canFit({ 20 }, 20, 50, 8))
Assert.is_false(Widgets.canFit({ 20, 20 }, 20, 50, 8))

return true
