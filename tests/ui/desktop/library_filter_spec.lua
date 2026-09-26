--[[-- library_filter：底栏面板、分组标题与清除动作。 --]]

local Assert = require("support.assert")
local shown
package.preload["ui/widget/container/inputcontainer"] = function()
    return { new = function(_, opts) opts = opts or {}; return opts end }
end
package.preload["ui/widget/container/bottomcontainer"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ui/widget/container/framecontainer"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ui/widget/container/leftcontainer"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ui/widget/container/rightcontainer"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ui/widget/overlapgroup"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ui/gesturerange"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["device"] = function()
    return {
        hasKeys = function() return false end,
        screen = {
            getSize = function() return { w = 600, h = 800 } end,
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
        },
    }
end
package.preload["ui.components.meshmask"] = function()
    return { widget = function(opts) return { mesh = true, dimen = { w = opts.width, h = opts.height } } end }
end
package.preload["ui.components.pagecontainer"] = function()
    return {
        sideW = function() return 28 end,
        contentWidth = function(w, pages) return (pages or 1) <= 1 and w or w - 56 end,
        clamp = function(page, pages) return math.min(page or 1, math.max(1, pages or 1)), math.max(1, pages or 1) end,
        wrap = function(opts) return opts.child end,
    }
end
package.preload["ui.components.bookui"] = function() return {
    sz = function(v) return v end, face = function() return {} end,
    muted = function() return 90 end, surface = function() return 220 end,
    rule = function() return 85 end, line = function() return 1 end,
} end
package.preload["ui.components.bookinfo"] = function()
    return { tappable = function(w, h, cb) return {
        dimen = { w=w,h=h }, callback=cb, getSize = function() return { w=w,h=h } end,
    } end }
end
package.preload["ui.components.surface"] = function()
    return { build = function(opts) return opts.child end }
end
local function widgetStub()
    return { new = function(_, opts) opts=opts or {}; opts.getSize=opts.getSize or function() return {w=10,h=10} end; return opts end }
end
for _, name in ipairs({"ui/widget/horizontalgroup","ui/widget/horizontalspan","ui/widget/verticalgroup","ui/widget/verticalspan"}) do
    package.preload[name] = widgetStub
end
package.preload["ui/widget/linewidget"] = widgetStub
package.preload["ui/geometry"] = function() return { new = function(_, opts) return opts end } end
package.preload["ui/widget/textwidget"] = function()
    return { new = function(_, opts) opts.getSize=function() return {w=40,h=14} end; return opts end }
end
package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE=255, COLOR_BLACK=0 } end
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, w) shown = w end,
        close = function() end,
    }
end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["ffi/util"] = function()
    return { template = function(s, a, b)
        return s:gsub("%%1", tostring(a), 1):gsub("%%2", tostring(b), 1)
    end }
end

package.loaded["ui.desktop.library_filter"] = nil
local Filter = require("ui.desktop.library_filter")
local applied, applied_sort
Filter.open{
    data = {
        source_counts = {
            { source_id = "local", name = "本地书籍", count = 3 },
            { source_id = "wechat", name = "微信读书", count = 5 },
        },
        category_counts = { { category = "科幻", count = 2 } },
        series_counts = { { series = "系列一", count = 1 }, { series = "", count = 3 } },
        read_counts = { { status = "read", count = 4 } },
        downloaded_count = 2,
    },
    current = {},
    on_apply = function(value, sort) applied, applied_sort = value, sort end,
}
Assert.not_nil(shown)
Assert.eq(shown.dimen.w, 600)
Assert.eq(shown.dimen.h, 800)
local stack = shown[1]
Assert.is_true(stack[1].mesh)
local panel = stack[2][1]
Assert.eq(panel[1].dimen.h, 3)
local frame = panel[2]
Assert.eq(frame.padding, 16)
Assert.eq(frame.width, 600)
local body = frame[1]
-- 标题行：OverlapGroup 左右同排
Assert.eq(body[1][1][1].text, "筛选")
Assert.eq(body[1][2][1][1].text, "全部清除")
Assert.eq(body[5][1].text, "数据源")
Assert.eq(body[7][1].text, "分类")
Assert.eq(body[9][1].text, "系列")
Assert.eq(body[11][1].text, "阅读状态")
Assert.eq(body[13][1].text, "本地")
Assert.eq(body[15][1].text, "排序")
-- 已下载：单个开关，点一次选中、再点取消
local downloaded_pill = body[13][3][1][1]
Assert.eq(downloaded_pill[1].text, "已下载（2）")
downloaded_pill.callback()
Assert.is_true(applied.downloaded)
body = shown[1][2][1][2][1]
body[13][3][1][1].callback()
Assert.is_nil(applied.downloaded)
body[1][2][1].callback()
Assert.not_nil(applied)
Assert.eq(applied_sort, "recent_added")

-- 无 source_counts：不出现数据源组
shown = nil
Filter.open{
    data = {
        category_counts = { { category = "科幻", count = 2 } },
        series_counts = { { series = "系列一", count = 1 } },
        read_counts = {},
    },
    current = {},
    on_apply = function() end,
}
Assert.eq(shown[1][2][1][2][1][5][1].text, "分类")
