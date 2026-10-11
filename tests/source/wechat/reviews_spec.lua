--[[--
source.wechat.reviews 离线用例：热点定位、批量请求与分页映射。

@module tests.source.wechat.reviews_spec
--]]

local Assert = require("support.assert")
local Reviews = require("source.wechat.reviews")

local html = table.concat({
    "<html><body><h1>一</h1>",
    "<p>我在森崎书店的日子，是从夏初到翌年的初春。</p>",
    "<p>重复句。</p><p>重复句。</p>",
    "<p>第一段结尾</p><p>第二段开头</p>",
    "</body></html>",
})

---@param range string
---@param abstract string
---@param total integer
local function entry(range, abstract, total)
    return {
        range = range,
        totalCount = total,
        maxIdx = 1,
        hasMore = 1,
        pageReviews = { {
            reviewId = "r-" .. range,
            likesCount = 21,
            review = { abstract = abstract, content = "点评", createTime = 1788166709, author = { name = "橘枳" } },
        } },
    }
end

do
    local spots = Reviews.spots({ reviews = {
        entry("386-407", "我在森崎书店的日子，是从夏初到翌年的初春。", 83),
        -- 重复原句无法消歧：不画错位置，直接丢。
        entry("500-504", "重复句。", 5),
        -- 跨段原句带换行：按段落边界规范化后仍能定位。
        entry("600-611", "第一段结尾\n第二段开头", 7),
        entry("700-710", "正文里没有的句子", 3),
        -- 没有段评的热点不标。
        entry("800-810", "我在森崎书店的日子", 0),
    } }, html)
    Assert.len(spots, 2)
    Assert.eq(spots[1].range, "386-407")
    Assert.eq(spots[1].total, 83)
    Assert.eq(spots[1].pos0, "/html/body/p[1]/text().0")
    Assert.eq(spots[1].pos1, "/html/body/p[1]/text().21")
    Assert.eq(spots[2].range, "600-611")
    Assert.eq(spots[2].pos0, "/html/body/p[4]/text().0")
    Assert.eq(spots[2].pos1, "/html/body/p[5]/text().5")
    Assert.len(Reviews.spots({}, html), 0)
end

do
    local item = Reviews.item(entry("1-2", "x", 1).pageReviews[1])
    Assert.eq(item.id, "r-1-2")
    Assert.eq(item.author, "橘枳")
    Assert.eq(item.content, "点评")
    Assert.eq(item.likes, 21)
    Assert.eq(item.time, 1788166709)
end

--- 回调由测试手动触发的假 client。
local function fakeClient()
    local client = { calls = {} }
    function client:underlinesAsync(book_id, chapter_uid, cb)
        self.calls[#self.calls + 1] = { "underlines", book_id, chapter_uid }
        self.underlines_cb = cb
        return { cancel = function() self.cancelled = "underlines" end }
    end
    function client:readReviewsAsync(book_id, chapter_uid, reviews, cb)
        self.calls[#self.calls + 1] = { "readReviews", book_id, chapter_uid, reviews }
        self.reviews_cb = cb
        return { cancel = function() self.cancelled = "readReviews" end }
    end
    return client
end

do
    -- underlines → 一次批量 readReviews（每句 1 条）→ 定位。
    local client = fakeClient()
    local got
    Reviews.spotsAsync(client, "b", "4", html, function(spots) got = spots end)
    client.underlines_cb({ underlines = {
        { range = "386-407", count = 935, type = 2 },
        { range = "740-758", count = 0, type = 0 },
    } })
    local reviews = client.calls[2][4]
    Assert.eq(client.calls[2][1], "readReviews")
    Assert.len(reviews, 2)
    Assert.eq(reviews[2].range, "740-758")
    Assert.eq(reviews[1].count, 1)
    Assert.eq(reviews[1].maxIdx, 0)
    client.reviews_cb({ reviews = { entry("386-407", "我在森崎书店的日子，是从夏初到翌年的初春。", 83) } })
    Assert.len(got, 1)

    -- 热点多时分批（整批过大服务端 3 秒超时）：依次 40/40/5，全部回来才定位。
    client = fakeClient()
    got = nil
    Reviews.spotsAsync(client, "b", "4", html, function(spots) got = spots end)
    local many = {}
    for i = 1, 85 do many[i] = { range = i .. "-" .. (i + 1) } end
    many[85] = { range = "386-407" }
    client.underlines_cb({ underlines = many })
    Assert.len(client.calls[2][4], 40)
    Assert.eq(client.calls[2][4][1].range, "1-2")
    client.reviews_cb({ reviews = {} })
    Assert.len(client.calls[3][4], 40)
    Assert.eq(client.calls[3][4][1].range, "41-42")
    client.reviews_cb({ reviews = {} })
    Assert.len(client.calls[4][4], 5)
    Assert.is_nil(got)
    client.reviews_cb({ reviews = { entry("386-407", "我在森崎书店的日子，是从夏初到翌年的初春。", 83) } })
    Assert.len(got, 1)

    -- 中途一批失败：整章报错，不再发后续批次。
    client = fakeClient()
    local batch_err
    Reviews.spotsAsync(client, "b", "4", html, function(spots, e) got, batch_err = spots, e end)
    client.underlines_cb({ underlines = many })
    client.reviews_cb(nil, "timeout of 3000ms exceeded")
    Assert.len(client.calls, 2)
    Assert.is_nil(got)
    Assert.eq(batch_err, "timeout of 3000ms exceeded")

    -- 本章没有热点：不发 readReviews。
    client = fakeClient()
    got = nil
    Reviews.spotsAsync(client, "b", "4", html, function(spots) got = spots end)
    client.underlines_cb({ underlines = {} })
    Assert.len(client.calls, 1)
    Assert.len(got, 0)

    -- 失败原样回传错误。
    client = fakeClient()
    local err
    Reviews.spotsAsync(client, "b", "4", html, function(spots, e) got, err = spots, e end)
    client.underlines_cb(nil, "boom")
    Assert.is_nil(got)
    Assert.eq(err, "boom")

    -- 取消：取消在飞的第二段请求，迟到的回包不再回调。
    client = fakeClient()
    local called = false
    local job = Reviews.spotsAsync(client, "b", "4", html, function() called = true end)
    client.underlines_cb({ underlines = { { range = "386-407" } } })
    job.cancel()
    Assert.eq(client.cancelled, "readReviews")
    client.reviews_cb({ reviews = {} })
    Assert.is_false(called)
end

do
    local client = fakeClient()
    local page, err
    Reviews.pageAsync(client, "b", "4", "386-407", 2, function(p, e) page, err = p, e end)
    local req = client.calls[1][4][1]
    Assert.eq(req.range, "386-407")
    Assert.eq(req.maxIdx, 2)
    Assert.eq(req.count, 30)
    client.reviews_cb({ reviews = { entry("386-407", "x", 83) } })
    Assert.is_nil(err)
    Assert.len(page.items, 1)
    Assert.eq(page.total, 83)
    Assert.eq(page.max_idx, 1)
    Assert.is_true(page.more)

    Reviews.pageAsync(client, "b", "4", "386-407", 0, function(p, e) page, err = p, e end)
    client.reviews_cb(nil, "offline")
    Assert.is_nil(page)
    Assert.eq(err, "offline")
end
