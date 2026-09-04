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
    "ui.components.pager",
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
    return { err = function() end }
end
package.preload["gettext"] = function()
    return function(text) return text end
end

package.preload["book.stats"] = function()
    error("统计页面不得直接同步远端")
end

package.loaded["ui.desktop.insight"] = nil
local Insight = require("ui.desktop.insight")

local insight_reads, rebuilds = 0, 0
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
    tab = "stats",
    source = source,
    source_generation = 1,
    rebuild = function() rebuilds = rebuilds + 1 end,
}

Insight.fetch(desktop)
Assert.eq(insight_reads, 1)
Assert.is_true(desktop._insight_loaded)
Assert.is_false(desktop._insight_fetching)
Assert.eq(rebuilds, 1)

