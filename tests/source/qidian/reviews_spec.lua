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

-- 统计：保留章末总评，0 评论不标，按段序排；没开段评的书当没有
do
    package.enabled = true
    local hot
    Reviews.hotspotsAsync("1", "2", function(list) hot = list end)
    Assert.eq(asked.chapter, "2")
    Assert.len(hot, 3)
    Assert.eq(hot[1].range, "-1")
    Assert.eq(hot[2].range, "1")
    Assert.eq(hot[3].range, "3")
    Assert.eq(hot[3].total, 7)

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
    Assert.is_false(Reviews.page({ total = 25, isEnd = 1, list = { { reviewId = "1" } } }, 2).more)
    Assert.is_true(Reviews.page({ total = 25, isEnd = 0, list = { { reviewId = "1" } } }, 3).more,
        "不等长的页不能用页码乘本页条数猜末页")
    local primary = Reviews.item({ content = "原评", rootReviewReplyCount = 65,
        replyList = {
            { reviewId = "r1", nickName = "乙", content = "回复[fn=3]", createTime = "1725596312000",
                quoteNickName = "丙", rootReviewReplyCount = 4,
                replyList = { { content = "不递归生成三级列表" } } },
            { reviewId = "r2", nickName = "丁", content = "另一条", likeCount = 2 },
        } })
    Assert.eq(primary.content, "原评", "不能把内嵌的两条回复预览拼进主评论")
    Assert.eq(primary.replies, 65)
    Assert.len(primary.reply_preview, 2)
    Assert.eq(primary.reply_preview[1].id, "r1")
    Assert.eq(primary.reply_preview[1].content, "回复")
    Assert.eq(primary.reply_preview[1].author, "乙")
    Assert.eq(primary.reply_preview[1].reply_to, "丙")
    Assert.eq(primary.reply_preview[1].time, 1725596312)
    Assert.is_nil(primary.reply_preview[1].reply_preview, "二级预览不继续生成三级列表")
    Assert.eq(primary.reply_preview[2].likes, 2)
    Assert.is_nil(Reviews.item({ rootReviewReplyCount = 65, replyList = {} }).reply_preview)
    Assert.is_nil(Reviews.item({ rootReviewReplyCount = 65 }).reply_preview)
    Assert.eq(Reviews.item({ replyList = { { content = "已有回复" } } }).replies, 1,
        "未给总数时至少显示实际预览数")
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

do
    local page, err = Reviews.bookPage({
        bookCirclePostCount = 9, bookCirclePostList = {
            { title = "帖子标题", circleReviewDesc = "<p>正文 &amp; 预览</p>", userName = "测试作者" },
        },
    })
    Assert.is_nil(err)
    Assert.len(page.items, 1)
    Assert.eq(page.items[1].text, "帖子标题\n正文 & 预览")
    Assert.eq(page.items[1].author, "测试作者")
    Assert.eq(page.total, 9)
    Assert.eq(page.title, "书友圈预览（1/9）")
    Assert.is_nil(page.pages, "不捏造官网未提供的整书帖子分页")
    page, err = Reviews.bookPage({ bookCirclePostCount = 0, bookCirclePostList = {} })
    Assert.is_nil(err)
    Assert.len(page.items, 0)
    page, err = Reviews.bookPage({ bookCirclePostCount = 9,
        bookCirclePostList = { { title = "坏帖" } } })
    Assert.is_nil(page)
    Assert.eq(err, "起点书友圈响应无效")
end

return true
