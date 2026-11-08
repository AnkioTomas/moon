--[[-- 豆瓣书评和章评：真实归属、分页、取消和独立缓存。 @module tests.source.douban.community_spec --]]
local Assert = require("support.assert")
local Stubs = require("support.stubs")
local JSON = require("support.json_stub")
package.loaded.json = JSON
local cfg = { cookie = "sid=test-private-cookie", user_id = "test-user", logged_in = true }
package.loaded["utils.settings"] = {
    getSource = function() return cfg end, get = function() return {} end,
    saveSource = function() end,
}
local connected, requests, mode = true, {}, "ok"
---@type {cb: fun(res: table), request: table}|nil
local pending
package.loaded["ui/network/manager"] = { isConnected = function() return connected end }
local function wire(offset, chapter)
    local rows = {}
    for index = offset + 1, math.min(offset + 20, 21) do
        rows[#rows + 1] = { id = tostring(index), content = "<p>Review<br>text</p>",
            createTime = "2025-01-01T12:00:00Z", commentType = chapter and "Discussion" or "Review",
            works = { isChapter = chapter ~= nil, id = chapter or "101" },
            user = { name = "Reader" }, upvoteCount = 2 }
    end
    return { data = { works = { comments = { total = 21, list = rows } } } }
end
package.loaded["http.request"] = {
    header = function() return nil end,
    headerAll = function() return {} end,
    request = function(opts, cb)
        local request = { opts = opts }
        requests[#requests + 1] = request
        if opts.method == "GET" then
            cb({ code = 200, headers = {}, body = "CSRF_TOKEN = 'test-csrf'" })
            return { cancel = function() request.cancelled = true end }
        end
        local body = JSON.decode(opts.body)
        if body.extensions.persistedQuery.sha256Hash:find("bf9257", 1, true) then
            cb({ code = 200, headers = {}, body = JSON.encode({
                data = { works = { readerUrl = "/reader/column/777/chapter/11/" } },
            }) })
        elseif mode == "wait" then
            pending = { cb = cb, request = request }
        elseif mode == "fail" then cb(nil, "network failed")
        else
            local result = wire(body.variables.start, body.variables.chapterId)
            if mode == "wrong-chapter" then result.data.works.comments.list[1].works.id = "other" end
            cb({ code = 200, headers = {}, body = JSON.encode(result) })
        end
        return { cancel = function() request.cancelled = true end }
    end,
}
local Client = require("source.douban.client")
local Mapper = require("source.douban.mapper")
local source = require("source.douban").new()
function source:loadTocAsync(_identity, cb)
    cb({ { uid = "11", idx = 1, title = "One" }, { uid = "22", idx = 2, title = "Two" } })
    return { cancel = function() end }
end
local page, err
source:bookReviewsAsync({ source_id = "douban", stable_id = "101" }, function(value, reason)
    page, err = value, reason
end)
Assert.is_nil(err)
Assert.len(page.items, 20)
Assert.matches(page.items[1].text, "Review")
Assert.is_false(page.items[1].text:find("<p>", 1, true) ~= nil)
Assert.is_nil(requests[1].opts.headers.Cookie)
Assert.eq(JSON.decode(requests[1].opts.body).variables.worksId, "101")
local identity = { source_id = "douban", stable_id = "101", chapter_idx = 1 }
source:paragraphReviewPageAsync(identity, "chapter", 0, function(value, reason) page, err = value, reason end)
Assert.is_nil(err)
Assert.len(page.items, 20)
Assert.eq(page.max_idx, 20)
Assert.is_true(page.more)
local body = JSON.decode(requests[#requests].opts.body)
Assert.eq(body.variables.columnId, "777", "专栏 ID 不等于作品 ID")
Assert.eq(body.variables.chapterId, "11")
Assert.is_nil(body.variables.worksId)
Assert.is_nil(requests[#requests].opts.headers.Cookie)
source:paragraphReviewPageAsync(identity, "chapter", 20, function(value, reason) page, err = value, reason end)
Assert.is_nil(err)
Assert.len(page.items, 1)
Assert.eq(page.max_idx, 21)
Assert.is_false(page.more)
Assert.eq(requests[#requests].opts.headers.Cookie, "sid=test-private-cookie")
Assert.eq(requests[#requests].opts.headers["X-CSRF-Token"], "test-csrf")
cfg.logged_in = false
local request_count = #requests
Client.communityAsync("101", "11", 20, function(value, reason) page, err = value, reason end)
Stubs.flush()
Assert.is_nil(page)
Assert.eq(err, "请先登录豆瓣阅读")
Assert.eq(#requests, request_count, "未登录时后续页立即说明权限，不发无效请求")
cfg.logged_in = true
Client.communityAsync("101", "11", 40, function(value, reason) page, err = value, reason end)
Assert.is_nil(err)
Assert.len(page.items, 0)
Assert.is_false(page.more)
mode = "wrong-chapter"
source:paragraphReviewPageAsync(identity, "chapter", 0, function(value, reason) page, err = value, reason end)
Assert.is_nil(page)
Assert.eq(err, "响应无效")
connected = false
source:paragraphReviewPageAsync(identity, "chapter", 0, function(value, reason) page, err = value, reason end)
Stubs.flush()
Assert.is_nil(err)
Assert.len(page.items, 20, "坏响应没有覆盖本章缓存")
identity.chapter_idx = 2
source:paragraphReviewPageAsync(identity, "chapter", 0, function(value, reason) page, err = value, reason end)
Stubs.flush()
Assert.is_nil(page, "换章不读上一章缓存")
Assert.eq(err, "未联网，无法加载段评")
connected, mode = true, "wait"
local called = false
local job = Client.communityAsync("101", "22", 0, function() called = true end)
job.cancel()
Assert.is_true(pending.request.cancelled, "同步入口回调后取消的是评论请求")
pending.cb({ code = 200, headers = {}, body = JSON.encode(wire(0, "22")) })
Assert.is_false(called, "取消后忽略迟到评论")
mode = "fail"
Client.communityAsync("101", nil, 0, function(value, reason) page, err = value, reason end)
Assert.is_nil(page)
Assert.eq(err, "network failed")
for _idx, bad in ipairs({ {}, { errors = { { message = "bad" } } }, { errors = "bad" } }) do
    local value, reason = Mapper.communityPage(bad, 0)
    Assert.is_nil(value)
    Assert.eq(reason, "响应无效")
end
local denied, reason = Mapper.communityPage({ errors = { { message = "AnonymousError" } } }, 20, "11")
Assert.is_nil(denied)
Assert.eq(reason, "请先登录豆瓣阅读")
for _idx, invalid_id in ipairs({ {}, "" }) do
    local invalid = wire(0, "11")
    invalid.data.works.comments.list[1].id = invalid_id
    local value, id_err = Mapper.communityPage(invalid, 0, "11")
    Assert.is_nil(value)
    Assert.eq(id_err, "响应无效")
end

do
    local Chapter = require("source.chapter")
    local original_open, original_text = Chapter.openAsync, Client.textAsync
    local chapter = { uid = "11", content_url = "11" }
    local produced
    cfg.show_paragraph_reviews = true
    Client.textAsync = function(_aid, _start, _ending, cb)
        cb("Original text")
        return { cancel = function() end }
    end
    Chapter.openAsync = function(_source, ref, _book, _opts, ops, _cb)
        return ops.fetchContent(ref, chapter, function(value) produced = value end)
    end
    source:openBookAsync(identity, { chapter_idx = 1 }, function() end)
    Assert.matches(produced.html, 'id="moon%-chapter%-reviews"', "专栏正文给章評预留空间")
    Assert.matches(produced.html, "Original text")
    chapter.slice = true
    source:openBookAsync(identity, { chapter_idx = 1 }, function() end)
    Assert.is_nil(produced.html:find('id="moon-chapter-reviews"', 1, true),
        "出版书没有章评入口，不增加空白区域")
    Chapter.openAsync, Client.textAsync = original_open, original_text
end
