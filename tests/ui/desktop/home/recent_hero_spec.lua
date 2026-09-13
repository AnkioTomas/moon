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

local shelf_recent = { stable_id = "book" }
local shelf_err
package.preload["book.catalog"] = function()
    return {
        recentShelf = function()
            return shelf_recent, {}, shelf_err
        end,
    }
end

local Hero = require("ui.desktop.home.views.recent_hero")
local hero = Hero:new()
local range = hero:heightRange()
Assert.eq(range.height, 148)
Assert.eq(range.fill, true)

local opened
local book = shelf_recent
local part = hero:build({
    plugin = { openBook = function(_, value) opened = value end },
    source = { id = "local" },
}, { width = 600, height = 160 })
Assert.eq(part:getSize().h, 160)
Assert.eq(hero_cover_width, 98)
hero:build({
    plugin = { openBook = function(_, value) opened = value end },
    source = { id = "local" },
}, { width = 600, height = 300 })
Assert.eq(hero_cover_width, 192)
hero_tap()
Assert.eq(opened, book)

local switched
shelf_recent, shelf_err = nil, nil
hero:build({
    desktop = {
        switchTab = function(_, tab) switched = tab end,
    },
}, { width = 600, height = 160 })
empty_tap()
Assert.eq(switched, "library")

return true
