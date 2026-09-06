--[[-- ui.components.bookinfo：封面状态（已读 / 进度 / 本地下载）与长按入口。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

local function widgetModule()
    return {
        new = function(_, opts)
            opts.getSize = opts.getSize or function(self)
                return self.dimen or { w = 10, h = 10 }
            end
            opts.paintTo = opts.paintTo or function() end
            opts.free = opts.free or function() end
            opts.handleEvent = opts.handleEvent or function() return false end
            return opts
        end,
    }
end
for _, name in ipairs({
    "ui/widget/horizontalgroup",
    "ui/widget/horizontalspan",
    "ui/widget/container/inputcontainer",
    "ui/widget/container/leftcontainer",
    "ui/widget/overlapgroup",
    "ui/widget/textboxwidget",
    "ui/widget/verticalgroup",
    "ui/widget/verticalspan",
    "ui/widget/textwidget",
    "ui/widget/widget",
}) do
    package.preload[name] = widgetModule
    package.loaded[name] = nil
end
package.preload["ui/geometry"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ui/gesturerange"] = widgetModule
package.preload["ui.components.image"] = function() return { widget = function(opts) return opts end } end
package.preload["ui.components.icon"] = function()
    return {
        widget = function()
            return {
                getSize = function() return { w = 10, h = 10 } end,
                paintTo = function() end,
                free = function() end,
            }
        end,
    }
end
package.preload["ui.components.bookui"] = function()
    return { face = function() return {} end, sz = function(v) return v end }
end
package.preload["ui.components.surface"] = function()
    return { card = function(child) return child end, pill = function(child) return child end }
end
package.preload["utils.paths"] = function() return {} end
package.preload["book.store"] = function()
    return {
        isDownloaded = function(book)
            return type(book) == "table" and type(book.path) == "string" and book.path ~= ""
        end,
    }
end
package.preload["libs/libkoreader-lfs"] = function() return {} end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = 0, COLOR_BLACK = 1, COLOR_GRAY_3 = 2 }
end
package.preload["gettext"] = function() return function(s) return s end end

package.loaded["ui.components.bookinfo"] = nil
local BookInfo = require("ui.components.bookinfo")

Assert.is_true(BookInfo.isRead({ read_state = 1 }))
Assert.is_false(BookInfo.isRead({ read_state = 0 }))
Assert.is_false(BookInfo.isRead({ read_state = 2 }))
Assert.is_false(BookInfo.isRead(nil))

local unread = BookInfo.statusOverlays({ read_state = 0, percent = 12, path = "/a" })
Assert.is_false(unread.read)
Assert.is_true(unread.percent)
Assert.is_true(unread.downloaded)

local finished = BookInfo.statusOverlays({ read_state = 1, percent = 100, path = "/a" })
Assert.is_true(finished.read)
Assert.is_false(finished.percent)
Assert.is_true(finished.downloaded)

local fresh = BookInfo.statusOverlays({ read_state = 0, percent = 0 })
Assert.is_false(fresh.read)
Assert.is_false(fresh.percent)
Assert.is_false(fresh.downloaded)

Assert.is_nil(BookInfo.progressBadge(80, 0))
Assert.not_nil(BookInfo.progressBadge(80, 12))

local rects = {}
local ribbon = BookInfo.readRibbon(80)
ribbon:paintTo({
    paintRect = function(_, x, y, w, h)
        rects[#rects + 1] = { x = x, y = y, w = w, h = h }
    end,
}, 0, 0)
Assert.is_true(#rects > 0)
Assert.eq(rects[1].x, 0)
Assert.eq(rects[1].w, ribbon.band)
Assert.eq(rects[2].x, 1)
Assert.eq(ribbon.overlap_offset[1], 80 - ribbon:getSize().w)
Assert.eq(ribbon.overlap_offset[2], 0)

local marks = {}
local mark = BookInfo.downloadMark(120)
mark:paintTo({
    paintRect = function(_, x, y, w, h)
        marks[#marks + 1] = { x = x, y = y, w = w, h = h }
    end,
}, 0, 0)
Assert.is_true(#marks > 0)
Assert.eq(mark.overlap_offset[1], 4)
Assert.eq(mark.overlap_offset[2], 120 - 18 - 4)

local tapped, held = 0, 0
local widget = BookInfo.tappable(100, 150, function()
    tapped = tapped + 1
end, function()
    held = held + 1
end)
Assert.not_nil(widget.ges_events.TapBookInfo)
Assert.not_nil(widget.ges_events.HoldBookInfo)
Assert.is_true(widget:onTapBookInfo())
Assert.is_true(widget:onHoldBookInfo())
Assert.eq(tapped, 1)
Assert.eq(held, 1)

package.loaded["ui.components.bookinfo"] = nil
