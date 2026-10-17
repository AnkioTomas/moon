--[[--
features.sidebar.stats 离线用例：统计插件可用判定、先落库再取书籍统计、
去掉书名作者两行与展开箭头、插件报错时返回空。

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

local session
package.loaded["reader.session"] = { current = function() return session end }
local Stats = require("features.sidebar.stats")

Assert.eq(Stats.available({}), false, "未加载统计插件")
local calls = {}
local stat = {
    enabled = true,
    id_curr_book = 7,
    isEnabled = function(self) return self.enabled end,
    insertDB = function() calls[#calls + 1] = "insert" end,
    getBookStat = function(_self, id)
        calls[#calls + 1] = "get" .. id
        return {
            { "Title", "T" }, { "Author(s)", "A", separator = true },
            { "Total time", "11:47:54" },
            { "Days reading ▸", 10, callback = function() end, separator = true },
        }
    end,
}
local ui = { statistics = stat }
Assert.is_true(Stats.available(ui))
local rows = Stats.rows(ui)
Assert.eq(table.concat(calls, ","), "insert,get7", "先落库再查")
Assert.len(rows, 2)
Assert.eq(rows[1][1], "Total time")
Assert.eq(rows[2][1], "Days reading")
Assert.eq(rows[2][2], "10")
Assert.is_true(rows[2][3])
Assert.not_nil(Stats.build(ui, 400))

stat.getBookStat = function() error("boom") end
Assert.len(Stats.rows(ui), 0, "插件报错不抛")
stat.enabled = false
Assert.eq(Stats.available(ui), false, "统计已关闭")
stat.enabled, stat.id_curr_book = true, nil
Assert.eq(Stats.available(ui), false, "本书未入库")
stat.id_curr_book = 7
session = { identity = { ephemeral = true } }
Assert.eq(Stats.available(ui), false, "订阅文章不显示统计页")
session = nil
Assert.not_nil(Stats.build(ui, 400))
package.loaded["reader.session"] = nil
