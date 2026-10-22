--[[--
desktop.pages.insight：按当前源读本地洞察（不联网、不同步远端）；主题翻页条按页名切六页；
日历点日期跳今日页；书单点书进详情，缺行 Toast 提示。

@module tests.desktop.pages.insight_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
local Themed = require("support.theme_stubs")
Themed.install()

local Container = require("ui/widget/container/widgetcontainer")
local Geom = require("ui/geometry")

package.preload["book.stats"] = function() error("统计页面不得直接同步远端") end
package.preload["ui/network/manager"] = function() error("统计页面不得依赖 NetworkMgr") end
package.preload["book.store"] = function() error("统计页面不得经 Store 拉远端") end
-- 只放行格式化与本地洞察聚合，其余 catalog 访问一律报错。
local insight_reads, insight_source_id = 0, nil
local payload
package.preload["book.catalog"] = function()
    return setmetatable({
        formatDuration = function(s) return s .. "s" end,
        readingInsightAsync = function(source_id, cb)
            insight_reads, insight_source_id = insight_reads + 1, source_id
            cb({ data = payload })
            return { cancel = function() end }
        end,
    }, {
        __index = function(_, key) error("统计页面只读本地洞察聚合，不得访问 catalog." .. key) end,
    })
end
local chart_opts
package.preload["ui.widgets.chart"] = function()
    return {
        bars = function(opts)
            chart_opts = opts
            return Container:new{ dimen = Geom:new{ w = opts.width, h = opts.height } }
        end,
    }
end
package.preload["ui.widgets.book"] = function()
    return {
        cover = function(_, _, _, cw, ch) return Container:new{ dimen = Geom:new{ w = cw, h = ch } } end,
    }
end
package.preload["book.books_db"] = function()
    return {
        get = function(source_id, stable_id)
            if source_id == "wechat" and stable_id == "book-1" then
                return { title = "本地书", percent = 0 }
            end
        end,
    }
end
local opened
package.preload["desktop.detail"] = function()
    return { open = function(desk, tab, book) opened = { desk = desk, tab = tab, book = book } end }
end

Kit.sections.insight = { hidden_pages = {}, hidden_cards = {}, month_goal_hours = 0, year_goal_books = 0 }
local Insight = require("desktop.pages.insight")

--- 按文案找按钮 / 点击区所在子树。
local function has(root, text)
    for _, s in ipairs(Kit.texts(root)) do if s == text then return true end end
    return false
end

local today = os.date("%Y-%m-%d")
local view_updates = 0
local hours = {}
for h = 1, 24 do hours[h] = h == 22 and 600 or 0 end
payload = {
    has_data = true,
    total = { has_data = true, total_seconds = 30 * 3600, total_text = "12小时", last7_text = "3小时" },
    calendar = {
        days = {
            [today] = {
                duration_seconds = 600,
                duration_text = "10分钟",
                pages = 7,
                hours = hours,
                books = { { source_id = "wechat", stable_id = "book-1", title = "本地书", percent = 42 } },
            },
        },
    },
}
local source = { id = "wechat" }
local desktop = {
    tab = "insight",
    source = source,
    source_generation = 1,
    dimen = { w = 600 },
    contentHeight = function() return 700 end,
}
local insight = Insight:new{ desktop = desktop, name = "insight" }
desktop.insight = insight
function desktop:updateView()
    view_updates = view_updates + 1
    self.view = insight:updateView()
end

-- 首帧是加载占位；nextTick 里按当前源读本地洞察并重建（Kit 的 nextTick 同步，重建先于占位返回）。
Assert.is_true(has(insight:updateView(), "加载统计…"))
Assert.eq(insight_reads, 1)
Assert.eq(insight_source_id, "wechat")
Assert.is_true(insight.state ~= nil)
Assert.is_nil(insight.fetch_cancel, "同步回调不留句柄")
Assert.eq(view_updates, 1)
Assert.eq(insight.state.selected, today, "有记录的今天默认选中")

-- 第 1 页「今日」：选中日是今天；首页左键置灰。
local view = desktop.view
Assert.is_true(has(view, "今日"))
Assert.is_true(has(view, "本地书"), "当日书单")
local nav = Kit.buttons(view)
Assert.is_false(nav[#nav - 1].enabled, "底部翻页条首页不可左翻")

-- 书单点书：books 表有行 → 进详情，进度用洞察里的值补。
opened = nil
local book_tap
for _, tap in ipairs(Kit.taps(view)) do
    if has(tap, "本地书") then book_tap = tap end
end
Assert.is_true(book_tap ~= nil)
book_tap:onTapThemeArea(nil, Kit.tap(0, 0))
Assert.eq(opened.tab, "library")
Assert.eq(opened.book.title, "本地书")
Assert.eq(opened.book.percent, 42)

-- 缺行不开详情，Toast 提示。
opened = nil
insight:openBookDetail({ source_id = "wechat", stable_id = "missing" })
Assert.is_nil(opened)
Assert.eq(Themed.last("toast").text, "没有这本书")
Assert.is_true(Themed.last("toast").shown)

-- 逐页翻到末页：页名依次是 本月 本年 榜单 趋势 进度，每页都能构建。
for _, name in ipairs({ "本月", "本年", "榜单", "趋势", "进度" }) do
    nav = Kit.buttons(desktop.view)
    nav[#nav].callback()
    Assert.is_true(has(desktop.view, name), name)
end
Assert.eq(insight.ui_page, 6)
nav = Kit.buttons(desktop.view)
Assert.is_false(nav[#nav].enabled, "末页右键置灰")
Assert.is_true(has(desktop.view, "距下一里程碑 72000s"))

-- 本月页日历：点今天跳回第 1 页。
insight.ui_page = 2
desktop:updateView()
local picked
for _, cell in ipairs(Kit.taps(desktop.view)) do
    if has(cell, tostring(tonumber(today:sub(9, 10)))) then picked = cell end
end
Assert.is_true(picked ~= nil, "日历有今天")
picked:onTapThemeArea(nil, Kit.tap(0, 0))
Assert.eq(insight.ui_page, 1)

-- 左右滑 / 物理翻页键：首页再往前不动，往后翻一页。
insight:onEvent("swipe", { direction = "east" })
Assert.eq(insight.ui_page, 1)
insight:onEvent("swipe", { direction = "west" })
Assert.eq(insight.ui_page, 2)
insight.ui_page = 6
insight:onEvent("swipe", { direction = "west" })
Assert.eq(insight.ui_page, 6)

-- 换源重置回未加载。
insight:onEvent("source_changed")
Assert.is_nil(insight.state)
Assert.eq(insight.ui_page, 1)

-- 统计变化：作废缓存，下次进页重读。
insight.state = { has_data = true }
insight:onEvent("stats_changed")
Assert.is_nil(insight.state)
local reads_before = insight_reads
insight:updateView()
Assert.eq(insight_reads, reads_before + 1, "作废后进页重读")

-- 设置：关掉页面后翻页条只剩开着的页；关掉卡片后该卡不出现，其余卡片仍在。
Kit.sections.insight.hidden_pages = { month = true, trends = true }
insight.ui_page = 1
desktop:updateView()
Assert.eq(insight.ui_pages, 4)
Kit.sections.insight.hidden_cards = { ["day.books"] = true }
desktop:updateView()
Assert.is_false(has(desktop.view, "本地书"), "关掉当日书单")
Assert.is_true(has(desktop.view, "页数 7 / 45") or has(desktop.view, "今日"), "其余仍显示")
Kit.sections.insight.hidden_pages, Kit.sections.insight.hidden_cards = {}, {}

return true
