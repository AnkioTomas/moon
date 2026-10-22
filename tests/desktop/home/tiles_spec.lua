--[[--
首页阅读小卡：四张半宽卡（连续阅读、近 7 天、本月挑战、今年读完）；
数值没变不重建；点按进统计页。

@module tests.desktop.home.tiles_spec
--]]
local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local date = os.date("*t")
Kit.sections.insight = { month_goal_hours = 0, year_goal_books = 5 }
Kit.sections.home = Kit.sections.home or {}
Kit.sections.home.home_stats_opacity = 40
local noon = os.time{ year = date.year, month = date.month, day = date.day, hour = 12 }
local daily, finished = {}, {}
package.preload["book.stats_db"] = function()
    return {
        dailyBySource = function() return daily end,
        progressBooks = function() return finished end,
    }
end
package.preload["book.catalog"] = function()
    return {
        formatDuration = function(n) return "d" .. n end,
        libraryScope = function(id) return id end,
    }
end

for i = 0, 2 do
    daily[#daily + 1] = { ymd = os.date("%Y-%m-%d", noon - i * 86400), seconds = 600, pages = 5 }
end
finished[1] = { last_time = os.time(), fraction = 1 }

local switched
local comp = require("desktop.pages.home.tiles"):new()
local slot = comp:build({ desktop = { switchTab = function(_, id) switched = id end }, source = { id = "owner" } },
    { width = 500, height = 300 })
comp:activate()

local text = table.concat(Kit.texts(slot), "|")
Assert.matches(text, "3天", "连续阅读 3 天")
Assert.matches(text, "d1800", "近 7 天合计")
Assert.matches(text, "1 / 5本", "今年读完带目标")
local cards = Kit.find(slot, function(w) return w.bg_alpha ~= nil end)
Assert.len(cards, 4, "四张卡都带底色透明度")
Assert.eq(cards[1].bg_alpha, 40)

local first = slot[1]
comp:onEvent("stats_changed")
Assert.eq(slot[1], first, "数据没变不重建")
finished[2] = { last_time = os.time(), fraction = 1 }
comp:onEvent("stats_changed")
Assert.is_true(slot[1] ~= first, "读完数变了要重建")

Kit.taps(slot)[1]:onTapThemeArea(nil, Kit.tap(0, 0))
Assert.eq(switched, "insight")
comp:destroy()

return true
