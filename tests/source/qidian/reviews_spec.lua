--[[--
起点段评：统计 → 热点、评论页 → 展示项（页码翻页）、段落按段序定位到章节 HTML。

@module tests.source.qidian.reviews_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")

local asked
package.preload["source.qidian.client"] = function()
    return {
        reviewSummaryAsync = function(book, chapter, cb)
            asked = { book = book, chapter = chapter }
            cb({ enableReview = package.enabled and 1 or 0, list = {
                { paragraphId = -1, textCount = 99 },
                { paragraphId = 3, textCount = 7 },
                { paragraphId = 1, textCount = 4942 },
                { paragraphId = 2, textCount = 0 },
            } })
            return { cancel = function() end }
        end,
        reviewListAsync = function(book, chapter, pid, page, cb)
            asked = { book = book, chapter = chapter, pid = pid, page = page }
            cb({ total = 25, list = { { reviewId = "9", nickName = "甲", content = "好[fn=47]看", likeCount = 6,
                createTimestamp = 1725596312, hasImage = 1, imagePre = "https://x/y.jpg", status = 1 } } })
            return { cancel = function() end }
        end,
    }
end
package.loaded["source.qidian.reviews"] = nil
local Reviews = require("source.qidian.reviews")

-- 统计：章末总评（-1）与 0 评论的段丢弃，按段序排；没开段评的书当没有
do
    package.enabled = true
    local hot
    Reviews.hotspotsAsync("1", "2", function(list) hot = list end)
    Assert.eq(asked.chapter, "2")
    Assert.len(hot, 2)
    Assert.eq(hot[1].range, "1")
    Assert.eq(hot[2].range, "3")
    Assert.eq(hot[2].total, 7)

    package.enabled = false
    Reviews.hotspotsAsync("1", "2", function(list) hot = list end)
    Assert.len(hot, 0)
end

-- 评论页：max_idx 是已取页数，请求页码 = max_idx + 1；表情码去掉；配图带上
do
    local page
    Reviews.pageAsync("1", "2", 3, 0, function(p) page = p end)
    Assert.eq(asked.page, 1)
    Assert.eq(asked.pid, 3)
    Assert.eq(page.max_idx, 1)
    Assert.eq(page.total, 25)
    Assert.is_true(page.more)
    Assert.eq(page.items[1].content, "好看")
    Assert.eq(page.items[1].author, "甲")
    Assert.eq(page.items[1].time, 1725596312)
    Assert.eq(page.items[1].images[1].url, "https://x/y.jpg")

    Assert.is_false(Reviews.page({ total = 1, list = { { reviewId = "1", content = "a" } } }, 1).more)
    Assert.is_false(Reviews.page({ total = 5, list = {} }, 2).more)
    Assert.is_nil((Reviews.page({}, 1)))
end

-- 定位：第 n 个非空 <p> 即 paragraphId = n，xpointer 覆盖整段
do
    local html = '<h1>标题</h1><p>开头一段话。</p>\n<p>第二段里有一句被很多人评论的话。</p>'
    local spots = Reviews.locate({
        { range = "2", text = "", total = 4 },
        { range = "9", text = "", total = 1 },
    }, html)
    Assert.len(spots, 1)
    Assert.eq(spots[1].range, "2")
    Assert.eq(spots[1].badge, "4")
    Assert.eq(spots[1].text, "第二段里有一句被很多人评论的话。")
end

return true
