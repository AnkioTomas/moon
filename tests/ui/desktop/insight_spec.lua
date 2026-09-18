--[[-- 统计页经源读本地洞察；不联网、不同步远端。 --]]

local Assert = require("support.assert")

local function emptyModule() return {} end
for _, name in ipairs({
    "ffi/blitbuffer",
    "ui/widget/container/centercontainer",
    "ui/widget/container/framecontainer",
    "ui/geometry",
    "ui.components.pagestrip",
    "ui.components.bookui",
    "ui/widget/textwidget",
    "ui/widget/verticalgroup",
    "ui/widget/verticalspan",
}) do
    package.preload[name] = emptyModule
end

local shown
package.preload["ui/widget/infomessage"] = function()
    return {
        new = function(_, opts) return opts end,
    }
end
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, msg) shown = msg end,
        nextTick = function(fn) fn() end,
    }
end
package.preload["utils.log"] = function()
    return { err = function() end, dbg = function() end }
end
package.preload["gettext"] = function()
    return function(text) return text end
end

package.preload["book.stats"] = function()
    error("统计页面不得直接同步远端")
end
package.preload["book.catalog"] = function()
    error("统计页面不得绕过源直接读 catalog")
end
package.preload["ui/network/manager"] = function()
    error("统计页面不得依赖 NetworkMgr")
end
package.preload["book.store"] = function()
    error("统计页面不得经 Store 拉远端")
end

local books = {
    ["wechat\0book-1"] = {
        title = "本地书",
        source_id = "wechat",
        stable_id = "book-1",
        percent = 0,
    },
}
package.preload["db.book"] = function()
    return {
        get = function(source_id, stable_id)
            return books[source_id .. "\0" .. stable_id]
        end,
    }
end

local opened
package.preload["ui.desktop.detail"] = function()
    return {
        open = function(desk, tab, book)
            opened = { desk = desk, tab = tab, book = book }
        end,
    }
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
    readingInsightAsync = function(_, cb)
        insight_reads = insight_reads + 1
        cb({
            data = {
                has_data = true,
                total = {},
                calendar = { days = {}, initial_ym = "2026-09" },
            },
        })
        return { cancel = function() end }
    end,
}
local desktop = {
    lifecycle = { state = "Resume" },
    tab = "insight",
    source = source,
    source_generation = 1,
    updateView = function() view_updates = view_updates + 1 end,
}

local insight = Insight:new{ desktop = desktop, name = "insight" }
desktop.insight = insight
Assert.eq(insight.lifecycle.state, "new")
insight:onCreate()
Assert.eq(insight.lifecycle.state, "Create")
insight:fetch()
Assert.eq(insight_reads, 1)
Assert.is_true(insight.loaded)
Assert.is_false(insight.fetching)
Assert.eq(view_updates, 1)
Assert.is_true(insight.state.has_data)

shown, opened = nil, nil
insight:openBookDetail({ source_id = "wechat", stable_id = "missing" })
Assert.is_nil(opened)
Assert.eq(shown.text, "没有这本书")

shown, opened = nil, nil
insight:openBookDetail({ source_id = "wechat", stable_id = "book-1", percent = 42 })
Assert.is_nil(shown)
Assert.eq(opened.tab, "library")
Assert.eq(opened.book.title, "本地书")
Assert.eq(opened.book.percent, 42)

return true
