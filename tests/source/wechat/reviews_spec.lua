--[[--
source.wechat.reviews 离线用例：热点定位、批量请求与分页映射。

@module tests.source.wechat.reviews_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
package.preload["json"] = function() return require("support.json_stub") end
package.loaded["json"] = nil
local Reviews = require("source.wechat.reviews")
os.execute("rm -rf '" .. require("utils.paths").sourceCacheDir("wechat") .. "/reviews'")

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
    local hotspots = Reviews.hotspots({ reviews = {
        entry("386-407", "我在森崎书店的日子，是从夏初到翌年的初春。", 83),
        -- 重复原句无法消歧：不画错位置，直接丢。
        entry("500-504", "重复句。", 5),
        -- 跨段原句带换行：按段落边界规范化后仍能定位。
        entry("600-611", "第一段结尾\n第二段开头", 7),
        entry("700-710", "正文里没有的句子", 3),
        -- 没有段评的热点不标。
        entry("800-810", "我在森崎书店的日子", 0),
    } })
    Assert.len(hotspots, 4)
    Assert.is_nil(rawget(hotspots[1], "pos0"), "拉取不定位")
    local spots = Reviews.locate(hotspots, html)
    Assert.len(spots, 2)
    Assert.eq(spots[1].range, "386-407")
    Assert.eq(spots[1].total, 83)
    Assert.eq(spots[1].pos0, "/html/body/p[1]/text().0")
    Assert.eq(spots[1].pos1, "/html/body/p[1]/text().21")
    Assert.eq(spots[2].range, "600-611")
    Assert.eq(spots[2].pos0, "/html/body/p[4]/text().0")
    Assert.eq(spots[2].pos1, "/html/body/p[5]/text().5")
    Assert.len(Reviews.hotspots({}), 0)
    Assert.len(Reviews.locate({}, html), 0)
    -- 同一批热点可在另一份 HTML 上重新定位（整本 EPUB 的各分片）。
    local other = Reviews.locate(hotspots, "<DocFragment><body><p>前文。我在森崎书店的日子，是从夏初到翌年的初春。</p></body></DocFragment>")
    Assert.len(other, 1)
    Assert.eq(other[1].pos0, "/docfragment/body/p/text().3")
end

do
    local item = Reviews.item(entry("1-2", "x", 1).pageReviews[1])
    Assert.eq(item.id, "r-1-2")
    Assert.eq(item.author, "橘枳")
    Assert.eq(item.content, "点评")
    Assert.eq(item.likes, 21)
    Assert.eq(item.time, 1788166709)
end

--- 回调由测试手动触发的假 client：每个请求的回调按发出顺序留在 calls 里。
local function fakeClient()
    local client = { calls = {}, cancelled = {} }
    function client:underlinesAsync(book_id, chapter_uid, cb)
        self.calls[#self.calls + 1] = { "underlines", book_id, chapter_uid, cb = cb }
        self.underlines_cb = cb
        return { cancel = function() self.cancelled[#self.cancelled + 1] = "underlines" end }
    end
    function client:readReviewsAsync(book_id, chapter_uid, reviews, cb)
        local n = #self.calls + 1
        self.calls[n] = { "readReviews", book_id, chapter_uid, reviews, cb = cb }
        self.reviews_cb = cb
        return { cancel = function() self.cancelled[#self.cancelled + 1] = n end }
    end
    return client
end

local hit_entry = entry("386-407", "我在森崎书店的日子，是从夏初到翌年的初春。", 83)

do
    -- underlines → 批量 readReviews（每句 1 条）。
    local client = fakeClient()
    local got
    Reviews.hotspotsAsync(client, "b", "c1", function(spots) got = spots end)
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
    client.reviews_cb({ reviews = { hit_entry } })
    Assert.len(got, 1)

    -- 落盘缓存：同章再拉不发请求，下一 tick 回调。
    client = fakeClient()
    got = nil
    Reviews.hotspotsAsync(client, "b", "c1", function(spots) got = spots end)
    Assert.len(client.calls, 0)
    Assert.is_nil(got, "缓存命中也异步回调")
    Stubs.flush()
    Assert.len(got, 1)
    Assert.eq(got[1].range, "386-407")
    Assert.eq(got[1].total, 83)
    -- 回调前取消：不再回调。
    got = nil
    Reviews.hotspotsAsync(client, "b", "c1", function(spots) got = spots end).cancel()
    Stubs.flush()
    Assert.is_nil(got)
    -- 过期缓存重拉。
    local real_time = os.time
    os.time = function() return real_time() + 8 * 24 * 3600 end
    Reviews.hotspotsAsync(client, "b", "c1", function() end)
    os.time = real_time
    Assert.len(client.calls, 1)

    -- 空结果只缓存 5 分钟：一次抖动不至于锁一周
    client = fakeClient()
    Reviews.hotspotsAsync(client, "b", "empty", function() end)
    client.underlines_cb({ underlines = {} })
    client = fakeClient()
    Reviews.hotspotsAsync(client, "b", "empty", function() end)
    Assert.len(client.calls, 0, "5 分钟内走缓存")
    os.time = function() return real_time() + 301 end
    Reviews.hotspotsAsync(client, "b", "empty", function() end)
    os.time = real_time
    Assert.len(client.calls, 1, "过 5 分钟重拉")

    -- 热点多时分批（整批过大服务端 3 秒超时）：40/40/40/5，同时最多 3 批在飞，结果按批次顺序合并。
    client = fakeClient()
    got = nil
    Reviews.hotspotsAsync(client, "b", "c2", function(spots) got = spots end)
    local many = {}
    for i = 1, 125 do many[i] = { range = i .. "-" .. (i + 1) } end
    client.underlines_cb({ underlines = many })
    Assert.len(client.calls, 4, "3 批并发")
    Assert.eq(client.calls[2][4][1].range, "1-2")
    Assert.eq(client.calls[3][4][1].range, "41-42")
    Assert.len(client.calls[4][4], 40)
    client.calls[3].cb({ reviews = { entry("41-42", "第二批", 1) } })
    Assert.len(client.calls, 5, "回来一批补一批")
    Assert.len(client.calls[5][4], 5)
    client.calls[5].cb({ reviews = { entry("121-122", "第四批", 1) } })
    client.calls[4].cb({ reviews = {} })
    Assert.is_nil(got)
    client.calls[2].cb({ reviews = { entry("1-2", "第一批", 1) } })
    Assert.len(got, 3)
    Assert.eq(got[1].range, "1-2")
    Assert.eq(got[2].range, "41-42")
    Assert.eq(got[3].range, "121-122")

    -- 一批失败：取消其余在飞批次，整章报错、不落盘，迟到的回包不再回调。
    client = fakeClient()
    local batch_err, calls = nil, 0
    got = nil
    Reviews.hotspotsAsync(client, "b", "c3", function(spots, e)
        calls, got, batch_err = calls + 1, spots, e
    end)
    client.underlines_cb({ underlines = many })
    client.calls[3].cb(nil, "timeout of 3000ms exceeded")
    Assert.len(client.calls, 4, "失败后不再发新批")
    Assert.len(client.cancelled, 2)
    Assert.is_nil(got)
    Assert.eq(batch_err, "timeout of 3000ms exceeded")
    client.calls[2].cb({ reviews = {} })
    Assert.eq(calls, 1)
    client = fakeClient()
    Reviews.hotspotsAsync(client, "b", "c3", function() end)
    Assert.len(client.calls, 1, "失败不落盘")

    -- 本章没有热点：不发 readReviews。
    client = fakeClient()
    got = nil
    Reviews.hotspotsAsync(client, "b", "c4", function(spots) got = spots end)
    client.underlines_cb({ underlines = {} })
    Assert.len(client.calls, 1)
    Assert.len(got, 0)

    -- 失败原样回传错误。
    client = fakeClient()
    local err
    Reviews.hotspotsAsync(client, "b", "c5", function(spots, e) got, err = spots, e end)
    client.underlines_cb(nil, "boom")
    Assert.is_nil(got)
    Assert.eq(err, "boom")

    -- 取消：取消在飞的批次，迟到的回包不再回调。
    client = fakeClient()
    local called = false
    local job = Reviews.hotspotsAsync(client, "b", "c6", function() called = true end)
    client.underlines_cb({ underlines = { { range = "386-407" } } })
    job.cancel()
    Assert.eq(client.cancelled[1], 2)
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
