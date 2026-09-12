--[[-- recent_cards：扇形堆叠，最多 9 本，下方标题进度，不泄漏布局变量。 --]]

local Assert = require("support.assert")
local texts = {}
local cover_n = 0
local taps = {}
local buffers = {}
local fail_scale = false

local function widget()
    local Class = {}
    Class.__index = Class
    function Class:new(opts) return setmetatable(opts or {}, self) end
    function Class:extend(opts)
        opts = opts or {}
        opts.__index = opts
        return setmetatable(opts, self)
    end
    function Class:getSize() return self.dimen or { w = 1, h = 1 } end
    return Class
end

package.preload["ui/widget/container/widgetcontainer"] = widget
package.preload["ui.components.icon"] = function()
    return { widget = function(opts) return opts end }
end

package.preload["ui/widget/container/centercontainer"] = widget
package.preload["ui/widget/container/framecontainer"] = widget
package.preload["ui/widget/container/inputcontainer"] = widget
package.preload["ui/widget/overlapgroup"] = widget
package.preload["ui/widget/horizontalgroup"] = widget
package.preload["ui/widget/horizontalspan"] = widget
package.preload["ui/gesturerange"] = widget
package.preload["ui/widget/verticalgroup"] = function()
    return {
        new = function(_, opts)
            opts = opts or {}
            opts.getSize = function()
                return { w = 120, h = 48 }
            end
            return opts
        end,
    }
end
package.preload["ui/widget/verticalspan"] = widget
package.preload["ui/widget/widget"] = widget
package.preload["ui/uimanager"] = function()
    return { setDirty = function() end }
end
package.preload["ui/widget/textwidget"] = function()
    return {
        new = function(_, opts)
            texts[#texts + 1] = opts.text
            opts.getSize = function()
                return { w = 40, h = 14 }
            end
            return opts
        end,
    }
end
package.preload["ui/geometry"] = widget
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = 0, COLOR_WHITE = 255, TYPE_BBRGB32 = 1,
        new = function(w, h)
            local buffer = { w = w, h = h, freed = 0 }
            function buffer:fill() end
            function buffer:free() self.freed = self.freed + 1 end
            function buffer:scale(width, height)
                if fail_scale then error("scale failed") end
                return require("ffi/blitbuffer").new(width, height)
            end
            buffers[#buffers + 1] = buffer
            return buffer
        end,
    }
end
package.preload["ffi/util"] = function()
    return {
        template = function(fmt, ...)
            local args = { ... }
            return (tostring(fmt):gsub("%%(%d+)", function(i)
                return tostring(args[tonumber(i)] or "")
            end))
        end,
    }
end
package.preload["gettext"] = function() return function(text) return text end end
local empty_tap
package.preload["ui.components.bookinfo"] = function()
    return {
        cover = function()
            cover_n = cover_n + 1
            return { paintTo = function() end }
        end,
        title = function(book) return book.title or book.stable_id or "?" end,
        author = function(book) return book.authors or "" end,
        pct = function(book) return book.percent or 0 end,
        tappable = function(w, h, callback)
            empty_tap = callback
            taps[#taps + 1] = callback
            return { dimen = { w = w, h = h }, getSize = function() return { w = w, h = h } end }
        end,
    }
end
package.preload["ui.components.bookui"] = function()
    return {
        sz = function(value) return value end,
        coverDim = function(width) return width, math.floor(width * 3 / 2) end,
        progressBar = function() return {} end,
        muted = function() return 0 end,
        face = function() return {} end,
    }
end

local shelf_recent = { stable_id = "book", title = "心挣", authors = "初禾", percent = 25 }
local shelf_reading = {}
package.preload["book.catalog"] = function()
    return {
        recentShelf = function()
            return shelf_recent, shelf_reading, nil
        end,
    }
end

_G.main_ch = nil
local Cards = require("ui.desktop.home.views.recent_cards")
local cards = Cards:new()
local part = cards:build({ source = { id = "local" } }, {
    width = 600,
    height = 220,
    budget = 220,
})

Assert.eq(part:getSize().h, 220)
Assert.eq(cover_n, 1)
Assert.is_nil(_G.main_ch)
Assert.contains(texts, "心挣")
Assert.contains(texts, "作者：初禾")
Assert.contains(texts, "已读 25%")

cover_n = 0
taps = {}
local extras = {}
for i = 1, 12 do extras[i] = { stable_id = "b" .. i } end
shelf_reading = extras
cards:build({ source = { id = "local" } }, { width = 600, height = 220, budget = 220 })
cards:rebuild()
Assert.eq(cover_n, 9)
Assert.eq(#taps, 12, "caption, nine covers, two arrows")
local function fan()
    return cards.content_widget[1][1][1][1][1]
end
local stack = fan()
Assert.eq(#stack, 11)
local bottom
for i = 1, 9 do
    local card = stack[i]
    local edge = card.overlap_offset[2] + card.dimen.h
    bottom = bottom or edge
    Assert.eq(edge, bottom, "all covers share one baseline")
    Assert.is_true(card.overlap_offset[1] >= 0)
    Assert.is_true(card.overlap_offset[1] + card.dimen.w <= stack.dimen.w)
    Assert.is_true(card.overlap_offset[2] >= 0)
end
Assert.is_true(stack[1][1].side < 0)
Assert.is_true(stack[2][1].side > 0)
fail_scale = false

local previous, next_ = taps[#taps - 1], taps[#taps]
next_()
Assert.eq(cards.focus, 2)
previous()
Assert.eq(cards.focus, 1)
previous()
Assert.eq(cards.focus, 9, "left arrow wraps to final cover")

shelf_recent = nil
local switched
cards:build({
    desktop = { switchTab = function(_, tab) switched = tab end, library = {} },
}, {
    width = 600,
    height = 220,
    budget = 220,
})
cards:rebuild()
Assert.eq(texts[#texts], "去图书馆挑一本 ›")
empty_tap()
Assert.eq(switched, "library")

local pauses = 0
cards.content_widget = { handleEvent = function(_, event)
    Assert.eq(event.handler, "onHomePause")
    pauses = pauses + 1
end }
cards:onPause()
cards:onDestroy()
Assert.eq(pauses, 1)
Assert.is_nil(cards.widget)

return true
