--[[--
features.sidebar.stats 离线用例：读月读本地统计库、订阅文章不出现、无记录时为空。

@module tests.features.sidebar.stats_spec
--]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["ffi/blitbuffer"] = function() return { Color8 = function(c) return c end } end
package.preload["ui/geometry"] = function() return { new = function(_, o) return o end } end
for _, name in ipairs({ "ui/widget/horizontalgroup", "ui/widget/horizontalspan", "ui/widget/linewidget",
    "ui/widget/verticalgroup", "ui/widget/verticalspan" }) do
    package.preload[name] = function() return { new = function(_, o) return o or {} end } end
end
package.loaded["ui.themes"], package.loaded["ui.themes.widgets.text"] = nil, nil
package.loaded["ui.themes.widgets.icon"] = nil
package.preload["ui.themes.widgets.icon"] = function() return { widget = function(o) return o end } end
package.preload["ui.themes"] = function()
    local theme = { space = { sm = 4 }, row = { divider = 1 }, color = { muted = 1 }, font = { body = 14 } }
    return { current = function() return theme end, px = function(v) return v end }
end
package.preload["ui.themes.widgets.text"] = function()
    local function w(...) return { ... } end
    local function line(role, text, opts)
        return { role, text, opts, getSize = function() return { w = #text * 5 } end, free = function() end }
    end
    return { line = line, box = w }
end

local session = { identity = { source_id = "local", stable_id = "b1" } }
package.loaded["reader.session"] = { current = function() return session end }
package.loaded["book.catalog"] = { formatDuration = function(sec) return sec .. "s" end }
local sum = { total_seconds = 600, pages = 12, first_read = 1790000000, last_read = 1790100000 }
local days = { { ymd = "a" }, { ymd = "b" } }
package.loaded["book.stats_db"] = {
    summaryByBook = function() return sum end,
    dailyByBook = function() return days end,
}
local Stats = require("features.sidebar.stats")

Assert.is_true(Stats.available())
local rows = Stats.rows()
Assert.len(rows, 6)
Assert.eq(rows[1][2], "600s")
Assert.eq(rows[2][2], "2", "阅读天数")
Assert.eq(rows[3][2], "300s", "日均 = 总时长 / 天数")
Assert.eq(rows[4][2], "12")
Assert.matches(rows[5][2], "^%d%d%d%d%-%d%d%-%d%d$")
Assert.not_nil(Stats.build(400))

sum = { total_seconds = 0, pages = 0, first_read = 0, last_read = 0 }
Assert.len(Stats.rows(), 0, "没有记录")
session = { identity = { ephemeral = true } }
Assert.eq(Stats.available(), false, "订阅文章不显示统计页")
Assert.len(Stats.rows(), 0)
session = nil
Assert.eq(Stats.available(), false)
package.loaded["reader.session"], package.loaded["book.stats_db"], package.loaded["book.catalog"] = nil, nil, nil
