--[[--
source.wechat.client 离线用例：书城搜索走 web/search/global

@module tests.source.wechat.client_spec
--]]

local Assert = require("support.assert")

local captured = {}
local posted = {}

package.preload["source.wechat.auth"] = function()
    return {
        webApiGetAsync = function(path, cb)
            captured[#captured + 1] = path
            if path:find("/web/shelf/sync", 1, true) then
                cb({ pureBookCount = 1, bookCount = 1, synckey = 0 })
            elseif path:find("/web/book/getProgress", 1, true) then
                cb({ bookId = "42", book = { chapterUid = 1, progress = 10 } })
            elseif path:find("/web/book/bookmarklist", 1, true) then
                cb({ synckey = 1, updated = {} })
            elseif path:find("/web/book/underlines", 1, true) then
                cb({ underlines = {} })
            elseif #captured == 1 then
                cb({
                    sid = "sid-1",
                    hasMore = 1,
                    totalCount = 40,
                    books = {
                        { searchIdx = 1, bookInfo = { bookId = "1", title = "A" } },
                        { searchIdx = 2, bookInfo = { bookId = "2", title = "B" } },
                    },
                })
            else
                cb({
                    sid = "sid-1",
                    hasMore = 0,
                    totalCount = 40,
                    books = {
                        { searchIdx = 3, bookInfo = { bookId = "3", title = "C" } },
                    },
                })
            end
            return { cancel = function() end }
        end,
        webApiPostAsync = function(path, body, cb)
            posted.path = path
            posted.body = body
            cb({ succ = 1 })
            return { cancel = function() end }
        end,
        webPostAsync = function(url, body, _, cb)
            posted.url = url
            posted.raw = body
            cb("{}")
            return { cancel = function() end }
        end,
    }
end
package.preload["source.wechat.client"] = nil
package.loaded["source.wechat.client"] = nil

local client = require("source.wechat.client"):new()

do
    captured = {}
    local wire
    client:searchAsync("三国", 3, nil, function(data) wire = data end)
    Assert.eq(#captured, 2)
    Assert.is_true(captured[1]:find("/web/search/global?", 1, true) ~= nil)
    Assert.is_true(captured[1]:find("keyword=%E4%B8%89%E5%9B%BD", 1, true) ~= nil)
    Assert.is_true(captured[1]:find("maxIdx=0", 1, true) ~= nil)
    Assert.is_true(captured[1]:find("fragmentSize=120", 1, true) ~= nil)
    Assert.is_true(captured[1]:find("count=3", 1, true) ~= nil)
    Assert.is_true(captured[1]:find("sid=", 1, true) ~= nil)
    Assert.is_true(captured[2]:find("maxIdx=2", 1, true) ~= nil)
    Assert.is_true(captured[2]:find("sid=sid-1", 1, true) ~= nil)
    Assert.eq(#wire.books, 3)
    Assert.eq(wire.books[3].bookInfo.bookId, "3")
end

do
    captured = {}
    local wire
    client:searchAsync("", 20, nil, function(data) wire = data end)
    Assert.eq(#captured, 0)
    Assert.eq(#wire.books, 0)
end

do
    posted = {}
    local ok
    client:addToShelfAsync("123", function(data) ok = data end)
    Assert.is_true(posted.path:find("/web/shelf/add", 1, true) ~= nil)
    Assert.eq(posted.body.bookIds[1], "123")
    Assert.not_nil(ok)
end

do
    captured = {}
    local wire
    client:shelfSyncAsync(function(data) wire = data end)
    Assert.eq(#captured, 1)
    Assert.is_true(captured[1]:find("/web/shelf/sync?", 1, true) ~= nil)
    Assert.eq(wire.bookCount, 1)
end

do
    captured = {}
    local wire, err
    client:getProgressAsync("42", function(data, e) wire, err = data, e end)
    Assert.eq(#captured, 1)
    Assert.is_true(captured[1]:find("/web/book/getProgress?", 1, true) ~= nil)
    Assert.is_true(captured[1]:find("bookId=42", 1, true) ~= nil)
    Assert.is_nil(err)
    Assert.not_nil(wire)
end

do
    captured = {}
    local wire
    client:bookmarkListAsync("99", function(data) wire = data end)
    Assert.eq(#captured, 1)
    Assert.is_true(captured[1]:find("/web/book/bookmarklist?", 1, true) ~= nil)
    Assert.is_true(captured[1]:find("bookId=99", 1, true) ~= nil)
    Assert.is_true(captured[1]:find("synckey=0", 1, true) ~= nil)
    Assert.not_nil(wire)
end

do
    captured = {}
    client:chapterUnderlinesAsync("99", 8, function() end)
    Assert.eq(#captured, 1)
    Assert.is_true(captured[1]:find("/web/book/underlines?", 1, true) ~= nil)
    Assert.is_true(captured[1]:find("chapterUid=8", 1, true) ~= nil)
end

do
    posted = {}
    client:chapterReviewsAsync("99", 8, { { range = "1-2", synckey = 0 } }, function() end)
    Assert.is_true(posted.path:find("/web/book/readreviews", 1, true) ~= nil)
    Assert.eq(posted.body.bookId, "99")
    Assert.eq(posted.body.chapterUid, 8)
end

do
    captured = {}
    local wire, err
    client:readStatsAsync("monthly", nil, function(data, e) wire, err = data, e end)
    Assert.eq(#captured, 0)
    Assert.is_nil(err)
    Assert.eq(type(wire), "table")
end

do
    package.preload["source.wechat.context"] = function()
        return {
            psvts = function(book_id, chapter_uid)
                if book_id == "99" and tostring(chapter_uid) == "8" then
                    return "psvts-token"
                end
                return nil
            end,
        }
    end
    package.preload["source.wechat.protocol"] = function()
        return {
            readerUrl = function(book_id, chapter_uid)
                return "https://weread.qq.com/web/reader/" .. book_id .. "?c=" .. chapter_uid
            end,
            makeEnterReadPayload = function(opts)
                return {
                    book_id = opts.book_id,
                    chapter_uid = opts.chapter_uid,
                    progress = opts.progress,
                    psvts = opts.psvts,
                    s = "signed",
                }
            end,
        }
    end
    package.loaded["source.wechat.context"] = nil
    package.loaded["source.wechat.protocol"] = nil
    package.loaded["source.wechat.client"] = nil
    package.preload["json"] = function()
        return {
            encode = function()
                return '{"signed":"signed"}'
            end,
            decode = function()
                return {}
            end,
        }
    end
    package.loaded["json"] = nil
    local progress_client = require("source.wechat.client"):new()

    posted = {}
    local ok, err
    progress_client:putProgressAsync("99", 50, 8, function(data, e) ok, err = data, e end)
    Assert.is_true(posted.url:find("/web/book/read", 1, true) ~= nil)
    Assert.is_true(posted.raw:find("signed", 1, true) ~= nil)
    Assert.not_nil(ok)

    ok, err = nil, nil
    progress_client:putProgressAsync("99", 50, nil, function(data, e) ok, err = data, e end)
    Assert.is_nil(ok)
    Assert.not_nil(err)

    ok, err = nil, nil
    progress_client:putProgressAsync("99", 50, 7, function(data, e) ok, err = data, e end)
    Assert.is_nil(ok)
    Assert.not_nil(err)
end
