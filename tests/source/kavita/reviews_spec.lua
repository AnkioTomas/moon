--[[-- Kavita 系列书评：章节过滤、归属校验与卷共用缓存。 @module tests.source.kavita.reviews_spec --]]
local Assert = require("support.assert")
local Stubs = require("support.stubs")
package.loaded.json = require("support.json_stub")
local Mapper = require("source.kavita.mapper")
local wire = { reviews = {
    { body = "<p>Book review</p>", tagline = "Title", chapterId = 0, seriesId = 5,
        username = "Reader", rating = 4, totalVotes = 3, isExternal = false },
    { body = "Chapter review", chapterId = 8, seriesId = 5, username = "Reader" },
    { body = "External book review", chapterId = 0, seriesId = 0,
        username = "External", isExternal = true },
} }
local page, err = Mapper.bookReviewPage(wire, "5")
Assert.is_nil(err)
Assert.len(page.items, 2)
Assert.eq(page.items[1].text, "Title\nBook review")
Assert.eq(page.items[1].grade, 4)
Assert.eq(page.items[1].likes, 3)
Assert.eq(page.items[1].time, "", "协议无日期，不编造日期")
Assert.eq(page.items[2].text, "External book review")
Assert.len(Mapper.bookReviewPage({ reviews = {} }, "5").items, 0)
for _idx, bad in ipairs({
    {}, { reviews = { { body = "Bad", username = "Reader", chapterId = 0, seriesId = 99 } } },
    { reviews = { { body = false } } },
}) do
    local value, reason = Mapper.bookReviewPage(bad, "5")
    Assert.is_nil(value)
    Assert.eq(reason, "响应无效")
end
local source = require("source.kavita").new()
local connected, requests, failed = true, 0, false
package.loaded["ui/network/manager"] = { isConnected = function() return connected end }
source.client.json = function(_self, method, path, query, _body, cb)
    requests = requests + 1
    Assert.eq(method, "GET")
    Assert.eq(path, "/api/Metadata/series-detail-plus")
    Assert.eq(query.seriesId, 5)
    if failed then cb(nil, "server failed") else cb(wire) end
    return { cancel = function() end }
end
source:bookReviewsAsync({ source_id = "kavita", stable_id = "5:8" }, function(value, reason)
    page, err = value, reason
end)
Assert.is_nil(err)
Assert.len(page.items, 2)
connected = false
source:bookReviewsAsync({ source_id = "kavita", stable_id = "5:9" }, function(value, reason)
    page, err = value, reason
end)
Stubs.flush()
Assert.is_nil(err)
Assert.len(page.items, 2)
Assert.eq(requests, 1, "两个卷使用所属系列的整书缓存")
connected, failed = true, true
source:bookReviewsAsync({ source_id = "kavita", stable_id = "5" }, function(value, reason)
    page, err = value, reason
end)
Assert.is_nil(page)
Assert.eq(err, "server failed")
