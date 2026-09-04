--[[-- 当前阅读大卡片与列表分离后的行为。 --]]

local Assert = require("support.assert")

local function widget()
    return { new = function(_, opts) return opts or {} end }
end

for _, name in ipairs({
    "ui/widget/container/centercontainer",
    "ui/widget/container/framecontainer",
    "ui/widget/textwidget",
    "ui/geometry",
}) do
    package.preload[name] = widget
end
package.preload["gettext"] = function() return function(text) return text end end

local hero_tap
local hero_cover_width
local empty_tap
package.preload["ui.components.bookinfo"] = function()
    return {
        hero = function(_, _, _, opts)
            hero_tap = opts.on_tap
            hero_cover_width = opts.cover_width
            return { hero = true }, 150
        end,
        tappable = function(_, _, callback)
            empty_tap = callback
            return {}
        end,
    }
end
package.preload["ui.components.bookui"] = function()
    return {
        sz = function(value) return value end,
        face = function() return {} end,
        muted = function() return 0 end,
    }
end

local Hero = require("ui.desktop.home.components.recent_hero")
local range = Hero.heightRange({}, {}, { height = 500 })
Assert.eq(range.min, 132)
Assert.eq(range.max, 500)

local opened
local book = { stable_id = "book" }
local part = Hero.build({
    plugin = { openBook = function(_, value) opened = value end },
}, { recent = book }, { width = 600, height = 160 })
Assert.eq(part.height, 160)
Assert.eq(hero_cover_width, 98)
Hero.build({
    plugin = { openBook = function(_, value) opened = value end },
}, { recent = book }, { width = 600, height = 300 })
Assert.eq(hero_cover_width, 192)
hero_tap()
Assert.eq(opened, book)

local switched
Hero.build({
    desktop = {
        switchTab = function(_, tab) switched = tab end,
    },
}, {}, { width = 600, height = 160 })
empty_tap()
Assert.eq(switched, "library")

return true
