--[[--
library_filter：排序、筛选两个下拉都是贴着按钮的主题 List 居中面板（带遮罩）；
当前项选中，点选回调新值，不改调用方的筛选表。

@module tests.desktop.pages.library.filter_spec
--]]

local Assert = require("support.assert")
require("support.widget_stubs").install("paper")
local Themed = require("support.theme_stubs")
Themed.install()

local Filter = require("desktop.pages.library.filter")

local function texts(list)
    local out = {}
    for i, item in ipairs(list.items) do out[i] = item.text end
    return out
end

local function checked(list)
    local out = {}
    for _idx, item in ipairs(list.items) do
        if item.checked then out[#out + 1] = item.text end
    end
    return out
end

-- 排序：贴按钮弹出的窄面板，当前项选中，点选回调 id。
local anchor = { x = 10, y = 20, w = 100, h = 40 }
local picked
local list = Filter.openSort(anchor, "title", function(id) picked = id end)
Assert.is_true(list.shown)
Assert.is_true(list.centered, "居中面板才有遮罩")
Assert.eq(list.anchor, anchor)
Assert.is_true(list.inner_width > 0)
Assert.eq(table.concat(texts(list), ","), "最近添加,最近阅读,书名,作者")
Assert.eq(table.concat(checked(list), ","), "书名")
Themed.choose(list, 4)
Assert.eq(picked, "author")
Assert.is_true(list.closed)
Assert.eq(Filter.sortText("recent_read"), "最近阅读")
Assert.eq(Filter.sortText("bogus"), "最近添加", "未知排序回退第一项")

-- 状态：计数、当前项、互斥单选；回调拿副本，保留搜索与下钻条件。
local data = {
    read_counts = { { status = "read", count = 4 }, { status = "unread", count = 7 } },
    downloaded_count = 2,
    hidden_count = 3,
}
local current = { search = "三体", author = "刘慈欣", read_status = "read" }
local got
list = Filter.openStatus(anchor, data, current, function(f) got = f end)
Assert.eq(table.concat(texts(list), ","), "全部,未读（7）,已读（4）,已下载（2）,软删除（3）")
Assert.eq(table.concat(checked(list), ","), "已读（4）")
Themed.choose(list, 4)
Assert.is_nil(got.read_status)
Assert.is_true(got.downloaded)
Assert.eq(got.search, "三体")
Assert.eq(got.author, "刘慈欣")
Assert.eq(current.read_status, "read", "不改调用方的筛选表")
Themed.choose(list, 5)
Assert.is_true(got.hidden)
Assert.is_nil(got.downloaded)
Assert.eq(Filter.status(got).id, "hidden")
Themed.choose(list, 1)
Assert.is_nil(got.read_status)
Assert.is_nil(got.downloaded)
Assert.is_nil(got.hidden)
Assert.eq(Filter.status({ downloaded = true }).id, "downloaded")
Assert.eq(Filter.status({}).id, "all")

-- 单一源没有数据源项；混合源接着列出（带源图标），已选源再点取消。
Assert.is_nil(list.items[6])
data.source_counts = {
    { source_id = "local", name = "本地书籍", count = 3 },
    { source_id = "wechat", name = "微信读书", count = 5 },
}
list = Filter.openStatus(anchor, data, { source_id = "wechat" }, function(f) got = f end)
Assert.eq(list.items[6].icon, "source")
Assert.eq(table.concat(checked(list), ","), "全部,微信读书（5）")
Themed.choose(list, 6)
Assert.eq(got.source_id, "local")
Themed.choose(list, 7)
Assert.is_nil(got.source_id)
