--[[--
首页阅读热力图：最右一列是本周，按当天时长分 5 档着色，今天之后留空；
统计变化但档位与总时长都没变时不重建；点按进统计页。

@module tests.desktop.home.heatmap_spec
--]]
local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local now = os.date("*t")
local noon = os.time{ year = now.year, month = now.month, day = now.day, hour = 12 }
local today, yesterday = os.date("%Y-%m-%d", noon), os.date("%Y-%m-%d", noon - 86400)
local daily, scope = {}, nil
package.preload["book.stats_db"] = function()
    return { dailyBySource = function(id) scope = id; return daily end }
end
package.preload["book.catalog"] = function()
    return {
        formatDuration = function(n) return tostring(n) end,
        libraryScope = function(id) return "scope:" .. id end,
    }
end

local Theme = require("ui.themes")
local t = Theme.current()

local switched
local desktop = { switchTab = function(_, id) switched = id end }
local comp = require("desktop.pages.home.heatmap"):new()
daily = {
    { ymd = today, seconds = 600 },
    { ymd = yesterday, seconds = 300 },
    { ymd = "1999-01-01", seconds = 99999 },
}
local slot = comp:build({ desktop = desktop, source = { id = "owner" } }, { width = 400, height = 200 })
comp:activate()
Assert.eq(scope, "scope:owner", "混合模式按展示范围读")
Assert.is_true(comp.weeks >= 1)

local cells = Kit.find(slot, function(w) return w.style ~= nil and w.width ~= nil and w.width == w.height end)
Assert.len(cells, comp.weeks * 7)
local by_bg = {}
for _, cell in ipairs(cells) do
    local key = tostring(cell.style.bg)
    by_bg[key] = (by_bg[key] or 0) + 1
end
Assert.eq(by_bg[tostring(t.color.ink)], 1, "最长的一天（今天）最深")
Assert.eq(by_bg[tostring(math.floor(t.progress.track + (t.color.ink - t.progress.track) * 2 / 4 + 0.5))], 1,
    "一半时长落第 2 档")
Assert.eq(by_bg["nil"], 6 - (now.wday + 5) % 7, "本周今天之后留空")
Assert.matches(table.concat(Kit.texts(slot), "|"), "· 900", "标题只算显示区间内的时长")

local first = slot[1]
comp:onEvent("stats_changed")
Assert.eq(slot[1], first, "数据没变不重建")
daily[1].seconds = 601
comp:onEvent("stats_changed")
Assert.is_true(slot[1] ~= first, "总时长变了要重建")

Kit.taps(slot)[1]:onTapThemeArea(nil, Kit.tap(0, 0))
Assert.eq(switched, "insight")
comp:destroy()

return true
