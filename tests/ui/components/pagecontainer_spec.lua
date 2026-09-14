--[[-- pagecontainer：单页不包箭头，多页内容宽扣掉两侧。 --]]

local Assert = require("support.assert")
package.preload["ui.components.bookui"] = function()
    return { sz = function(v) return v end }
end
package.preload["ui.components.icon"] = function()
    return {
        widget = function(opts)
            return { opts = opts, getSize = function() return { w = 18, h = 18 } end }
        end,
    }
end
local function stub()
    return { new = function(_, opts)
        opts = opts or {}
        opts.getSize = opts.getSize or function() return { w = opts.dimen and opts.dimen.w or 10, h = opts.dimen and opts.dimen.h or 10 } end
        return opts
    end }
end
for _, name in ipairs({
    "ui/widget/container/centercontainer",
    "ui/widget/container/inputcontainer",
    "ui/widget/horizontalgroup",
    "ui/gesturerange",
    "ui/geometry",
}) do
    package.preload[name] = stub
end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = 0, COLOR_GRAY_9 = 9 }
end

package.loaded["ui.components.pagecontainer"] = nil
local PageContainer = require("ui.components.pagecontainer")
Assert.eq(PageContainer.sideW(), 28)
Assert.eq(PageContainer.contentWidth(200, 1), 200)
Assert.eq(PageContainer.contentWidth(200, 3), 144)
local child = { getSize = function() return { w = 100, h = 20 } end }
Assert.eq(PageContainer.wrap{ child = child, width = 200, page = 1, pages = 1 }, child)
local multi = PageContainer.wrap{
    child = child, width = 200, page = 2, pages = 3,
    on_prev = function() end, on_next = function() end,
}
Assert.eq(#multi, 3)
