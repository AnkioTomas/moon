--[[-- recent_cards 不得向共享 Lua 环境泄漏布局变量。 --]]

local Assert = require("support.assert")
local texts = {}

local function widget()
    return { new = function(_, opts) return opts or {} end }
end

package.preload["ui/widget/container/centercontainer"] = widget
package.preload["ui/widget/container/framecontainer"] = widget
package.preload["ui/widget/overlapgroup"] = widget
package.preload["ui/widget/textwidget"] = function()
    return {
        new = function(_, opts)
            texts[#texts + 1] = opts.text
            return opts
        end,
    }
end
package.preload["ui/geometry"] = widget
package.preload["gettext"] = function() return function(text) return text end end
package.preload["ui.components.bookinfo"] = function()
    return {
        cover = function() return {} end,
        pct = function(book) return book.percent end,
        tappable = function() return {} end,
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

_G.main_ch = nil
local Cards = require("ui.desktop.home.components.recent_cards")
local part = Cards.build({}, {
    recent = { stable_id = "book", percent = 25 },
    reading = {},
}, {
    width = 600,
    budget = 200,
})

Assert.eq(part.height, 200)
Assert.is_nil(_G.main_ch)

local opened
Cards.build({
    desktop = {
        showDetail = function(_, book) opened = book end,
    },
}, {}, {
    width = 600,
    budget = 200,
})
Assert.is_nil(opened)
Assert.eq(texts[#texts], "去图书馆挑一本 ›")

return true
