--[[-- 首页弹性布局：范围分配、末尾裁剪和准确高度传递。 --]]

local Assert = require("support.assert")

local home_settings = {
    home_layout = { "recent_hero", "recent_list" },
    home_excerpt_index = 0,
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
    return { sz = function(n) return n end }
end

local function stubComponent(id)
    return {
        id = id,
        label = id,
        heightRange = function()
            return ranges[id] or { min = 10, preferred = 10, max = 10, grow = 1 }
        end,
        build = function(_ctx, _state, opts)
            build_log[#build_log + 1] = { id = id, height = opts.height }
            local part = { widget = { _id = id }, height = opts.height }
            if id == "clock" then part.refresh = function() end end
            return part
        end,
    }
end

for _, id in ipairs({
    "clock", "stats", "hitokoto", "excerpt",
    "recent_hero", "recent_list", "recent_cards",
}) do
    package.preload["ui.desktop.home.components." .. id] = function()
        return stubComponent(id)
    end
end

local Base = require("ui.desktop.home.components.base")
local Layout = require("ui.desktop.home.layout")

local defaults = Base.enabledLayout()
Assert.len(defaults, 2)
Assert.eq(defaults[1], "recent_hero")
Assert.eq(defaults[2], "recent_list")

-- 最小值放不下时，当前项及其后的组件全部隐藏。
local selected, heights, unused = Layout.allocate({
    { id = "a", min = 30, preferred = 40, max = 50, grow = 1 },
    { id = "b", min = 30, preferred = 40, max = 60, grow = 2 },
    { id = "c", min = 20, preferred = 20, max = 20, grow = 1 },
}, 75, 8)
Assert.len(selected, 2)
Assert.eq(selected[2].id, "b")
Assert.eq(heights[1] + heights[2] + 8 + unused, 75)

-- 先公平扩到理想值，再按 grow 消耗最大值空间。
selected, heights, unused = Layout.allocate({
    { id = "a", min = 20, preferred = 30, max = 50, grow = 1 },
    { id = "b", min = 20, preferred = 30, max = 70, grow = 3 },
}, 100, 0)
Assert.eq(heights[1], 40)
Assert.eq(heights[2], 60)
Assert.eq(unused, 0)

-- 所有组件达到最大值后，剩余空间留在页面底部。
selected, heights, unused = Layout.allocate({
    { id = "a", min = 10, preferred = 20, max = 25, grow = 1 },
}, 40, 0)
Assert.eq(heights[1], 25)
Assert.eq(unused, 15)

-- 不足完整第二行时，书架保持一行，零碎高度交给连续伸缩组件。
selected, heights = Layout.allocate({
    { id = "hero", min = 30, preferred = 40, max = 80, grow = 2 },
    { id = "list", min = 50, preferred = 80, max = 110, grow = 6, step = 30 },
}, 100, 0)
Assert.eq(heights[1], 50)
Assert.eq(heights[2], 50)

-- 空间达到整行步长时，书架优先恢复默认两行。
selected, heights = Layout.allocate({
    { id = "hero", min = 30, preferred = 40, max = 80, grow = 2 },
    { id = "list", min = 50, preferred = 80, max = 110, grow = 6, step = 30 },
}, 110, 0)
Assert.eq(heights[1], 30)
Assert.eq(heights[2], 80)

-- build 必须把分配高度原样交给组件，并维护时钟刷新区域。
home_settings.home_layout = { "clock", "stats", "recent_list" }
ranges.clock = { min = 20, preferred = 30, max = 40, grow = 1 }
ranges.stats = { min = 20, preferred = 30, max = 40, grow = 1 }
ranges.recent_list = { min = 40, preferred = 60, max = 100, grow = 4 }
build_log = {}
layout_kids = {}
local desktop = {}
local frame = Layout.build({ width = 320, height = 120, desktop = desktop }, {})
Assert.len(build_log, 3)
Assert.eq(build_log[1].height + build_log[2].height + build_log[3].height + 16, 120)
Assert.is_true(build_log[3].height > build_log[1].height)
Assert.eq(desktop._home_clock_region.h, build_log[1].height)
Assert.eq(frame.width, 320)
Assert.eq(frame.height, 120)

-- 页面太矮时严格按顺序保留前缀。
build_log = {}
Layout.build({ width = 320, height = 70 }, {})
Assert.len(build_log, 2)
Assert.eq(build_log[1].id, "clock")
Assert.eq(build_log[2].id, "stats")

return true
