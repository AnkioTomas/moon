--[[-- 统计页只读取 Source 已落库的本地聚合，不负责远端同步。 --]]

local Assert = require("support.assert")

local function emptyModule() return {} end
for _, name in ipairs({
    "ffi/blitbuffer",
    "ui.components.bookinfo",
    "ui/widget/container/centercontainer",
    "ui/widget/container/framecontainer",
    "ui/geometry",
    "ui/widget/infomessage",
    "ui/network/manager",
    "ui.components.pagestrip",
    "book.store",
    "db.book",
    "ui.components.bookui",
    "ui/widget/textwidget",
    "ui/widget/verticalgroup",
    "ui/widget/verticalspan",
}) do
    package.preload[name] = emptyModule
end
package.preload["ui/uimanager"] = emptyModule
package.preload["utils.log"] = function()
    return { err = function() end, dbg = function() end }
end
package.preload["gettext"] = function()
    return function(text) return text end
end

package.preload["book.stats"] = function()
    error("统计页面不得直接同步远端")
end
for _, name in ipairs({
    "ui.desktop.insight.overview",
    "ui.desktop.insight.day",
    "ui.desktop.insight.records",
}) do
    package.preload[name] = function()
        return { new = function() return {} end }
    end
end

package.loaded["ui.desktop.insight"] = nil
local Insight = require("ui.desktop.insight")

local insight_reads, view_updates = 0, 0
local source = {
    id = "wechat",
    capabilities = function() return { insight = true, stats_pull = true } end,
    configured = function() return true end,
    readingInsightAsync = function(_, cb)
        insight_reads = insight_reads + 1
        cb({
            has_data = true,
            total = {},
            calendar = { days = {}, initial_ym = "2026-09" },
        })
    end,
}
local desktop = {
    lifecycle = { state = "Resume" },
    tab = "stats",
    source = source,
    source_generation = 1,
    updateView = function() view_updates = view_updates + 1 end,
}

local insight = Insight.new(desktop)
desktop.insight = insight
Assert.eq(insight.lifecycle.state, "new")
insight:onCreate()
Assert.eq(insight.lifecycle.state, "Create")
insight:fetch()
Assert.eq(insight_reads, 1)
Assert.is_true(insight.loaded)
Assert.is_false(insight.fetching)
Assert.eq(view_updates, 1)

return true
