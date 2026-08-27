--[[--
ui.desktop.home 离线用例：布局默认、裁剪与 enrich。

@module tests.ui.desktop.home.layout_spec
--]]

local Assert = require("support.assert")

local home_settings = {
    home_layout = { "recent_list" },
    home_recent_list_mode = "hero_grid",
    home_excerpt_index = 0,
}
package.preload["utils.settings"] = function()
    return {
        get = function(section)
            if section == "home" then return home_settings end
            return home_settings
        end,
        saveSection = function(_, section, values)
            if section == "home" then home_settings = values end
        end,
    }
end

package.preload["l10n"] = function()
    return { apply = function() end }
end
package.preload["gettext"] = function()
    return function(s) return s end
end

for _, name in ipairs({
    "clock", "stats", "hitokoto", "excerpt", "recent_list", "recent_cards",
}) do
    package.preload["ui.desktop.home.components." .. name] = function()
        return { id = name, label = name }
    end
end

local progress_rows = {}
package.preload["utils.db.progress"] = function()
    return {
        get = function(source_id, stable_id)
            return progress_rows[source_id .. "\0" .. stable_id]
        end,
    }
end

local Base = require("ui.desktop.home.components.base")
local Enrich = require("ui.desktop.home.enrich")
local HomeStats = require("ui.desktop.home.stats")

Assert.eq(#Base.enabledLayout(), 1)
Assert.eq(Base.enabledLayout()[1], "recent_list")
Assert.is_true(Base.hasComponent("recent_list"))
Assert.is_false(Base.hasComponent("clock"))

home_settings.home_layout = { "clock", "stats", "unknown", "recent_list" }
local layout = Base.enabledLayout()
Assert.eq(#layout, 3)
Assert.eq(layout[1], "clock")
Assert.eq(layout[3], "recent_list")

progress_rows["moon\0book-1"] = {
    chapter_title = "第一章 开端",
    chapter_idx = 2,
    fraction = 0.42,
}
local book = Enrich.book({
    source_id = "moon",
    stable_id = "book-1",
    title = "测试书",
    percent = 10,
})
Assert.eq(book.chapter_title, "第一章 开端")
Assert.eq(book.chapter_idx, 2)
Assert.eq(book.percent, 42)

local daily = {
    { ymd = os.date("%Y-%m-%d"), seconds = 600 },
    { ymd = os.date("%Y-%m-%d", os.time() - 86400), seconds = 300 },
    { ymd = os.date("%Y-%m-%d", os.time() - 2 * 86400), seconds = 0 },
}
Assert.eq(HomeStats.currentStreak(daily), 2)

local broken = {
    { ymd = os.date("%Y-%m-%d"), seconds = 0 },
    { ymd = os.date("%Y-%m-%d", os.time() - 86400), seconds = 100 },
}
Assert.eq(HomeStats.currentStreak(broken), 1)

return true
