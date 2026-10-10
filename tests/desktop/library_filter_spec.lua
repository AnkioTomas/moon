--[[--
library_filter：主题全屏列表，每个维度一个分栏；点选即生效不关窗，再点取消；左上角全部清除。

@module tests.desktop.pages.library.filter_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local Filter = require("desktop.pages.library.filter")

--- 点文案所在的那一行。
local function tapText(root, text)
    for _, tap in ipairs(Kit.taps(root)) do
        for _, s in ipairs(Kit.texts(tap)) do
            if s == text then return tap:onTapThemeArea() end
        end
    end
    error("no row: " .. text)
end

local applied, applied_sort, applies = nil, nil, 0
local list = Filter.open{
    data = {
        source_counts = {
            { source_id = "local", name = "本地书籍", count = 3 },
            { source_id = "wechat", name = "微信读书", count = 5 },
        },
        category_counts = { { category = "科幻", count = 2 } },
        series_counts = { { series = "系列一", count = 1 }, { series = "", count = 3 } },
        read_counts = { { status = "read", count = 4 } },
        downloaded_count = 2,
    },
    current = { search = "三体" },
    sort = "title",
    on_apply = function(value, sort) applied, applied_sort, applies = value, sort, applies + 1 end,
}
Assert.eq(Kit.shown[#Kit.shown], list)
local texts = Kit.texts(list)
Assert.contains(texts, "筛选")
for _, tab in ipairs({ "数据源", "分类", "系列", "状态", "排序" }) do Assert.contains(texts, tab) end
Assert.contains(texts, "本地书籍（3）", "首栏是数据源")
Assert.contains(texts, "微信读书（5）")

-- 点选即生效：面板不关，搜索词保留，排序原样带回。
tapText(list, "微信读书（5）")
Assert.eq(applied.source_id, "wechat")
Assert.eq(applied.search, "三体")
Assert.eq(applied_sort, "title")
Assert.is_nil(applied.sort, "sort 单独回传，不混进筛选")
Assert.len(Kit.closed, 0)
Assert.is_true(list.items[2].checked)
-- 再点已选项取消。
tapText(list, "微信读书（5）")
Assert.is_nil(applied.source_id)

-- 空值项落到独立布尔字段；选具体系列清掉空值标记。
list:switchTab("series")
Assert.contains(Kit.texts(list), "无系列（3）")
tapText(list, "无系列（3）")
Assert.is_true(applied.unseries)
Assert.is_nil(applied.series)
tapText(list, "系列一（1）")
Assert.eq(applied.series, "系列一")
Assert.is_nil(applied.unseries)

-- 状态栏：阅读状态计数来自 read_counts；已下载是单个开关。
list:switchTab("status")
Assert.contains(Kit.texts(list), "已读（4）")
Assert.contains(Kit.texts(list), "未读（0）")
tapText(list, "已下载（2）")
Assert.is_true(applied.downloaded)
tapText(list, "已下载（2）")
Assert.is_nil(applied.downloaded)

-- 排序：单选，再点不取消。
list:switchTab("sort")
Assert.is_true(list.items[3].checked, "打开时的 sort 选中")
tapText(list, "作者")
Assert.eq(applied_sort, "author")
tapText(list, "作者")
Assert.eq(applied_sort, "author")

-- 全部清除：只留搜索词，排序回默认，当前栏重画。
list:switchTab("series")
local before = applies
Kit.buttons(list)[1]:onTapThemeButton()
Assert.eq(applies, before + 1)
Assert.eq(applied_sort, "recent_added")
Assert.eq(applied.search, "三体")
Assert.is_nil(applied.series)
Assert.is_false(list.items[2].checked)

-- 单源：没有 source_counts 就没有数据源栏，首栏是分类。
local single = Filter.open{
    data = {
        category_counts = { { category = "科幻", count = 2 } },
        series_counts = {},
        read_counts = {},
        downloaded_count = 0,
    },
    current = {},
    on_apply = function() end,
}
Assert.eq(single.tabs.active, "category")
for _, s in ipairs(Kit.texts(single)) do Assert.is_true(s ~= "数据源") end
Assert.contains(Kit.texts(single), "科幻（2）")
