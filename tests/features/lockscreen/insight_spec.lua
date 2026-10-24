--[[--
lockscreen 统计页面背景：页面选项来自统计页目录、每天随机、无数据空态。

@module tests.features.lockscreen.insight_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
require("support.theme_stubs").install()
Kit.sections.insight = { hidden_pages = {}, hidden_cards = {} }

package.preload["features.lockscreen.components.library"] = function()
    return { activeSourceId = function() return "moon" end }
end
package.preload["book.stats_db"] = function()
    return { summaryBySource = function() return { total_seconds = 3600 } end }
end
package.loaded["features.lockscreen.insight"] = nil

local Insight = require("features.lockscreen.insight")
Kit.sections.lockscreen = {}
local conf = require("utils.settings").get("features.lockscreen")

conf.lock_screen_insight_page = nil
Assert.eq(Insight.page(), "random", "未设置按每天随机")
Assert.is_true(Insight.validPage("year"))
Assert.eq(Insight.validPage("nope"), false)
Assert.eq(Insight.pageOptions()[2].value, "day", "第一页是统计页的今日")

conf.lock_screen_insight_page = "ranks"
Assert.eq(Insight.cache_key(), "ranks:3600")
conf.lock_screen_insight_page = "random"
Assert.matches(Insight.cache_key(), ":3600$")

-- 没有任何统计时只画空态文字，不构建页面。
package.loaded["book.catalog"] = {
    readingInsight = function() return { has_data = false, calendar = { days = {} } } end,
}
local blocks = Insight.blocks({ x = 0, y = 0, w = 540, h = 720 })
Assert.len(blocks, 1)
Assert.eq(blocks[1].kind, nil)
