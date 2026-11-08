--[[-- 快看每话章评：原始行游标、章节隔离、离线与取消。 @module tests.source.kuaikan.reviews_spec --]]
local Assert = require("support.assert")
local Stubs = require("support.stubs")
local JSON = require("support.json_stub")
package.loaded.json = JSON
local connected, requests, pending = true, {}, nil
package.loaded["ui/network/manager"] = { isConnected = function() return connected end }
---@type {code: integer, data: {total: integer, comments: {id: integer|string|table, content: string, replied_comment_id: integer, user?: table}[]}}
local result = { code = 200, data = { total = 4, comments = {
    { id = 1, content = "First", replied_comment_id = 0, user = { nickname = "Reader" } },
    { id = 2, content = "Reply", replied_comment_id = 1 },
    { id = 3, content = "Second", replied_comment_id = 0 },
} } }
package.loaded["http.request"] = {
    get = function(url, opts, cb)
        local request = { url = url, opts = opts }
        requests[#requests + 1] = request
        if pending then pending.cb, pending.request = cb, request
        elseif url:find("offset=3", 1, true) then
            cb(JSON.encode({ code = 200, data = { total = 4, comments = {
                { id = 4, content = "Last", replied_comment_id = 0 },
            } } }))
        else cb(JSON.encode(result)) end
        return { cancel = function() request.cancelled = true end }
    end,
}
local source = require("source.kuaikan").new()
function source:loadTocAsync(_identity, cb)
    cb({ { uid = "11", idx = 1, title = "One" }, { uid = "22", idx = 2, title = "Two" } })
    return { cancel = function() end }
end
local identity = { source_id = "kuaikan", stable_id = "review-test", chapter_idx = 1 }
local page, err
source:paragraphReviewPageAsync(identity, "chapter", 0, function(value, reason) page, err = value, reason end)
Assert.is_nil(err)
Assert.len(page.items, 2)
Assert.eq(page.items[1].id, "1")
Assert.eq(page.items[1].content, "First")
Assert.eq(page.max_idx, 3, "游标按原始三行推进，不按两个主楼推进")
Assert.is_true(page.more)
Assert.matches(requests[1].url, "/comic/11/")
Assert.is_nil(requests[1].opts.headers.Cookie)
source:paragraphReviewPageAsync(identity, "chapter", page.max_idx, function(value, reason) page, err = value, reason end)
Assert.is_nil(err)
Assert.eq(page.items[1].id, "4")
Assert.eq(page.max_idx, 4)
Assert.is_false(page.more)
connected = false
source:paragraphReviewPageAsync(identity, "chapter", 0, function(value, reason) page, err = value, reason end)
Stubs.flush()
Assert.is_nil(err)
Assert.len(page.items, 2)
identity.chapter_idx = 2
source:paragraphReviewPageAsync(identity, "chapter", 0, function(value, reason) page, err = value, reason end)
Stubs.flush()
Assert.is_nil(page)
Assert.eq(err, "未联网，无法加载段评")
connected, pending = true, {}
local called = false
local job = source:paragraphReviewPageAsync(identity, "chapter", 0, function() called = true end)
Assert.matches(pending.request.url, "/comic/22/")
job.cancel()
Assert.is_true(pending.request.cancelled)
pending.cb(JSON.encode(result))
Assert.is_false(called)
pending = nil
for _idx, invalid_id in ipairs({ {}, "" }) do
    result.data.comments[1].id = invalid_id
    source:paragraphReviewPageAsync(identity, "chapter", 0, function(value, reason) page, err = value, reason end)
    Assert.is_nil(page)
    Assert.eq(err, "响应无效", "坏 ID 不转换为 Lua 表地址或无身份评论")
end
