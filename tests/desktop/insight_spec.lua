--[[--
desktop.pages.insight：经源读本地洞察（不联网、不同步远端）；主题翻页条按页名切三页；
日历点日期跳当日书单；书单点书进详情，缺行 Toast 提示。

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
-- 只放行纯格式化函数，其余 catalog 访问（读库）一律报错。
package.preload["book.catalog"] = function()
    return setmetatable({ formatDuration = function(s) return s .. "s" end }, {
        __index = function(_, key) error("统计页面不得绕过源直接读 catalog: " .. key) end,
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
package.preload["db.book"] = function()
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

local Insight = require("desktop.pages.insight")

--- 按文案找按钮 / 点击区所在子树。
local function has(root, text)
    for _, s in ipairs(Kit.texts(root)) do if s == text then return true end end
    return false
end

local today = os.date("%Y-%m-%d")
local insight_reads, view_updates = 0, 0
local payload = {
    has_data = true,
    total = { has_data = true, total_text = "12小时", last7_text = "3小时" },
    calendar = {
        days = {
            [today] = {
                duration_seconds = 600,
                duration_text = "10分钟",
                books = { { source_id = "wechat", stable_id = "book-1", title = "本地书", percent = 42 } },
            },
        },
    },
}
local source = {
    id = "wechat",
    capabilities = function() return { insight = true } end,
    readingInsightAsync = function(_, cb)
        insight_reads = insight_reads + 1
        cb({ data = payload })
        return { cancel = function() end }
    end,
}
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

-- 首帧是加载占位；nextTick 里经源读洞察并重建（Kit 的 nextTick 同步，重建先于占位返回）。
Assert.is_true(has(insight:updateView(), "加载统计…"))
Assert.eq(insight_reads, 1)
Assert.is_true(insight.loaded)
Assert.is_false(insight.fetching)
Assert.eq(view_updates, 1)
Assert.eq(insight.state.selected, today, "有记录的今天默认选中")

-- 第 1 页：页名作翻页标题；首页左键置灰。
local view = desktop.view
Assert.is_true(has(view, "概览"))
Assert.is_true(has(view, "12小时"))
Assert.is_true(has(view, "3小时"))
local nav = Kit.buttons(view)
Assert.is_false(nav[#nav - 1].enabled, "底部翻页条首页不可左翻")
-- 月份翻页无界：两侧都亮，翻完回来仍是本月。
Assert.is_true(nav[1].enabled and nav[2].enabled)
nav[1].callback()
Assert.is_true(insight.state.ym ~= today:sub(1, 7))
Kit.buttons(desktop.view)[2].callback()
Assert.eq(insight.state.ym, today:sub(1, 7))

-- 日历格：点今天跳到第 2 页书单。
local cells = Kit.taps(desktop.view)
Assert.is_true(#cells >= 28)
local picked
for _, cell in ipairs(cells) do
    if has(cell, tostring(tonumber(today:sub(9, 10)))) and #Kit.find(cell, function(w)
        return w.style and w.style.border == 2
    end) > 0 then
        picked = cell
    end
end
Assert.is_true(picked ~= nil, "选中日描边")
picked:onTapThemeArea(nil, Kit.tap(0, 0))
Assert.eq(insight.ui_page, 2)
view = desktop.view
Assert.is_true(has(view, "今日总览"))
Assert.is_true(has(view, "本地书"))

-- 书单点书：books 表有行 → 进详情，进度用洞察里的值补。
opened = nil
Kit.taps(view)[1]:onTapThemeArea(nil, Kit.tap(0, 0))
Assert.eq(opened.tab, "library")
Assert.eq(opened.book.title, "本地书")
Assert.eq(opened.book.percent, 42)

-- 缺行不开详情，Toast 提示。
opened = nil
insight:openBookDetail({ source_id = "wechat", stable_id = "missing" })
Assert.is_nil(opened)
Assert.eq(Themed.last("toast").text, "没有这本书")
Assert.is_true(Themed.last("toast").shown)

-- 第 3 页：指标卡 + 月度图；末页右键置灰。
nav = Kit.buttons(view)
nav[#nav].callback()
Assert.eq(insight.ui_page, 3)
view = desktop.view
Assert.is_true(has(view, "连续记录"))
Assert.is_true(has(view, "今年总阅读时长"))
Assert.is_true(has(view, "600s"))
Assert.len(chart_opts.points, 12)
nav = Kit.buttons(view)
Assert.is_false(nav[#nav].enabled)

-- 源不支持统计：只剩一页错误提示；换源重置回未加载。
insight:onEvent("source_changed")
Assert.is_false(insight.loaded)
Assert.eq(insight.ui_page, 1)
desktop.source = { capabilities = function() return { insight = false } end }
insight:updateView()
view = desktop.view
Assert.eq(#Kit.find(view, function(w) return w.text == "当前数据源不支持统计" end), 1)
nav = Kit.buttons(view)
Assert.is_false(nav[1].enabled or nav[2].enabled, "单页两侧置灰")

return true
