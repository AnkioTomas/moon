--[[-- 京东书评：匿名请求、字段语义、坏响应与离线缓存。 @module tests.source.jdread.reviews_spec --]]
local Assert = require("support.assert")
local Stubs = require("support.stubs")
local JSON = require("support.json_stub")
package.loaded.json = JSON
local connected, requests, fail = true, {}, false
package.loaded["ui/network/manager"] = { isConnected = function() return connected end }
package.loaded["http.request"] = {
    get = function(url, opts, cb)
        requests[#requests + 1] = { url = url, opts = opts }
        if fail then cb(nil, "network failed")
        else cb(JSON.encode({ result_code = 0, data = { total = 21, ebook_comment_infos = {
            { id = 1, nickname = "Reader", comment = "Review", created = 1735732800000,
                like_count = 4, comment_rate = 5 },
        } } })) end
        return { cancel = function() end }
    end,
}
local Source = require("source.jdread").new()
Source._client.cookie, Source._client.uuid = "test-cookie", "test-uuid"
local Mapper = require("source.jdread.mapper")
local identity = { source_id = "jdread", stable_id = "review-test", chapter_idx = 1 }
---@type table|nil
local page
local err
Source:bookReviewsAsync(identity, function(value, reason) page, err = value, reason end)
Assert.is_nil(err)
Assert.len(page.items, 1)
Assert.eq(page.items[1].id, "1")
Assert.eq(page.items[1].text, "Review")
Assert.eq(page.items[1].grade, 5)
Assert.eq(page.items[1].likes, 4)
Assert.eq(page.items[1].time, os.date("%Y-%m-%d", 1735732800))
Assert.eq(page.total, 21)
Assert.eq(page.title, "书评预览")
Assert.is_nil(requests[1].opts.headers.Cookie)
Assert.eq(Source._client.cookie, "test-cookie")
Assert.matches(requests[1].url, "/ebook/review%-test/comment%?")
connected = false
identity.chapter_idx = 9
---@type table|nil
local cached_page
Source:bookReviewsAsync(identity, function(value, reason) cached_page, err = value, reason end)
Stubs.flush()
Assert.is_nil(err)
Assert.eq(cached_page.items[1].text, "Review", "整书缓存不随章节复制")
Assert.len(requests, 1)
connected, fail = true, true
Source:bookReviewsAsync(identity, function(value, reason) page, err = value, reason end)
Assert.is_nil(page)
Assert.eq(err, "network failed", "联网失败不伪装成旧书评成功")
local empty = Mapper.bookReviewPage({ data = { total = 0, ebook_comment_infos = {} } })
Assert.len(empty.items, 0)
for _idx, wire in ipairs({
    {}, { data = { total = "bad", ebook_comment_infos = {} } },
    { data = { total = 1, ebook_comment_infos = { { comment = "missing id" } } } },
}) do
    local value, reason = Mapper.bookReviewPage(wire)
    Assert.is_nil(value)
    Assert.eq(reason, "京东读书响应无效")
end
