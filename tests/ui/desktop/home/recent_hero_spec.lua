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
local hero_builds = 0
package.preload["ui.components.bookinfo"] = function()
    return {
        hero = function(_, _, _, opts)
            hero_builds = hero_builds + 1
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
local shelf_calls = 0
package.preload["book.catalog"] = function()
    return {
        recentShelf = function()
            shelf_calls = shelf_calls + 1
            return shelf_recent, {}, shelf_err
        end,
    }
end

local Hero = require("ui.desktop.home.views.recent_hero")
local hero = Hero:new()
local range = hero:heightRange()
Assert.eq(range.height, 148)
Assert.is_nil(range.fill)

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

local before_resume = shelf_calls
hero:onResume()
Assert.eq(shelf_calls, before_resume + 1, "resume must refresh the current-reading card")

-- 书架同步：全量对账返回同内容的新表时不重建（封面不再走占位→出图）；内容变了才重建。
local builds = hero_builds
shelf_recent = { stable_id = "book" }
hero:onEvent("shelf_changed")
Assert.eq(hero_builds, builds, "显示数据未变不得重建")
shelf_recent = { stable_id = "book", percent = 42 }
hero:onEvent("shelf_changed")
Assert.eq(hero_builds, builds + 1, "进度变化必须重建")
hero:onPause()
shelf_recent = { stable_id = "other" }
hero:onEvent("shelf_changed")
Assert.eq(hero_builds, builds + 1, "暂停中不重建，恢复时 onResume 自会重读")

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
