--[[--
source.wechat.client 离线用例：各接口的 URL 与请求体

@module tests.source.wechat.client_spec
--]]

local Assert = require("support.assert")

local captured = {}
local posted = {}

package.preload["json"] = function()
    return {
        encode = require("support.json_stub").encode,
        decode = require("support.json_stub").decode,
    }
end
package.loaded["json"] = nil

-- 网页接口回原始 JSON 串：解码与 errcode 校验在 client 里真跑
local web_replies = {}
package.preload["source.wechat.auth"] = function()
    local decode = require("support.json_stub").decode
    return {
        webGetAsync = function(url, _opts, cb)
            captured[#captured + 1] = url
            for pattern, raw in pairs(web_replies) do
                if url:find(pattern, 1, true) then
                    cb(raw)
                    return { cancel = function() end }
                end
            end
            if url:find("/web/shelf/sync", 1, true) then
                cb('{"pureBookCount":1,"bookCount":1,"synckey":0}')
            elseif url:find("/web/book/getProgress", 1, true) then
                cb('{"bookId":"42","book":{"chapterUid":1,"progress":10}}')
            elseif url:find("/web/book/underlines", 1, true) then
                cb('{"underlines":[]}')
            end
            return { cancel = function() end }
        end,
        webPostAsync = function(url, body, opts, cb)
            posted.url = url
            posted.raw = body
            posted.referer = opts and opts.headers and opts.headers.Referer
            local ok, decoded = pcall(decode, body)
            posted.body = ok and decoded or nil
            if url:find("/review/add", 1, true) then
                cb('{"reviewId":"rv-1"}')
            else
                cb('{"succ":1}')
            end
            return { cancel = function() end }
        end,
    }
end
package.preload["source.wechat.eink"] = function()
    return {
        callAsync = function(method, path, opts, cb)
            posted.eink = { method = method, path = path, query = opts.query }
            if path == "/book/bookmarklist" then
                cb({
                    synckey = 1,
                    updated = {
                        { chapterUid = 4, range = "303-332", markText = "原文", type = 1 },
                    },
                    chapters = { { chapterUid = 4, chapterIdx = 4 } },
                })
            elseif path == "/review/list" then
                cb({
                    totalCount = 3,
                    reviews = {
                        { review = { bookId = "99", range = "1-2", content = "本书" } },
                        { review = { bookId = "3300107657", range = "464-466", content = "别的书" } },
                        { review = { range = "5-6", content = "无 bookId 保留" } },
                    },
                })
            else
                cb({
                    readLongest = {
                        { book = { bookId = "1" }, readTime = 3600 },
                    },
                })
            end
            return { cancel = function() end }
        end,
    }
end
package.loaded["source.wechat.eink"] = nil
package.preload["source.wechat.client"] = nil
package.loaded["source.wechat.client"] = nil

local client = require("source.wechat.client")

do
    posted = {}
    client:editReviewAsync({ reviewId = "rv-1", content = "修改" }, function() end)
    Assert.is_true(posted.url:find("/web/review/edit", 1, true) ~= nil)

    client:deleteReviewAsync("rv-1", function() end)
    Assert.is_true(posted.url:find("/web/review/delete", 1, true) ~= nil)

    client:updateBookmarkAsync({ bookmarkId = "bm-1", style = 1, colorStyle = 2 }, function() end)
    Assert.is_true(posted.url:find("/web/book/updateBookmark", 1, true) ~= nil)

    client:removeBookmarkAsync("bm-1", function() end)
    Assert.is_true(posted.url:find("/web/book/removeBookmark", 1, true) ~= nil)
end

do
    posted = {}
    local ok
    client:addToShelfAsync("123", function(data) ok = data end)
    Assert.eq(posted.url, "https://weread.qq.com/web/shelf/add")
    Assert.eq(posted.body.bookIds[1], "123")
    Assert.not_nil(ok)
end

do
    posted = {}
    local ok
    client:removeFromShelfAsync("123", function(data) ok = data end)
    Assert.eq(posted.url, "https://i.weread.qq.com/shelf/delete")
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

    -- 登录页 / WAF 拦截页不是 JSON：按失败，不能当成功静默丢数据。
    web_replies["/web/book/info"] = "<html>login</html>"
    local data, err
    client:bookInfoAsync("1", function(d, e) data, err = d, e end)
    Assert.is_nil(data)
    Assert.eq(err, "返回非 JSON")

    -- errcode 非 0 按失败，带服务端错误信息。
    web_replies["/web/book/info"] = '{"errcode":-2010,"errmsg":"用户不存在"}'
    client:bookInfoAsync("1", function(d, e) data, err = d, e end)
    Assert.is_nil(data)
    Assert.eq(err, "用户不存在")
    web_replies["/web/book/info"] = nil
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
    -- 个人划线走 Eink：Web 会话打 /web/book/bookmarklist 恒返回 {}
    captured = {}
    posted = {}
    local wire
    client:bookmarkListAsync("99", function(data) wire = data end)
    Assert.eq(#captured, 0)
    Assert.eq(posted.eink.method, "GET")
    Assert.eq(posted.eink.path, "/book/bookmarklist")
    Assert.eq(posted.eink.query.bookId, "99")
    Assert.eq(posted.eink.query.synckey, 0)
    Assert.eq(#wire.updated, 1)
    Assert.eq(wire.chapters[1].chapterIdx, 4)
end

do
    posted = {}
    local wire
    client:myReviewsAsync("99", function(data) wire = data end)
    Assert.eq(posted.eink.path, "/review/list")
    Assert.eq(posted.eink.query.bookId, "99")
    Assert.eq(posted.eink.query.mine, 1)
    Assert.eq(posted.eink.query.listType, 1)
    -- 别的书的想法剔掉，否则会按 range 挂进这本书（串书）
    Assert.eq(#wire.reviews, 2)
    Assert.eq(wire.reviews[1].review.content, "本书")
    Assert.eq(wire.reviews[2].review.content, "无 bookId 保留")
    Assert.eq(wire.totalCount, 3, "全量判定保留服务端口径")
    Assert.not_nil(wire)
end

do
    posted = {}
    local wire
    client:addReviewAsync({ bookId = "99", content = "想法", range = "1-2" }, function(data) wire = data end)
    Assert.is_true(posted.url:find("weread.qq.com/web/review/add", 1, true) ~= nil)
    Assert.is_true(posted.raw:find("想法", 1, true) ~= nil)
    Assert.eq(wire.reviewId, "rv-1")
end

do
    captured = {}
    posted = {}
    local wire, err
    client:readStatsAsync("monthly", nil, function(data, e) wire, err = data, e end)
    Assert.is_nil(err)
    Assert.eq(posted.eink.path, "/readdata/detail")
    Assert.eq(posted.eink.query.mode, "monthly")
    Assert.is_nil(posted.eink.query.baseTime)
    Assert.eq(#(wire.readLongest or {}), 1)
end

do
    local entered_payload
    package.preload["source.wechat.context"] = function()
        return {
            reader = function()
                return { psvts = "psvts-token", pclts = "pclts-token" }
            end,
        }
    end
    package.preload["source.wechat.protocol"] = function()
        return {
            readerUrl = function(book_id, chapter_uid)
                return "https://weread.qq.com/web/reader/" .. book_id .. "?c=" .. chapter_uid
            end,
            makeEnterReadPayload = function(opts)
                entered_payload = opts
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
    local read_reply = { succ = 1 }
    package.preload["json"] = function()
        return {
            encode = function()
                return '{"signed":"signed"}'
            end,
            decode = function()
                return read_reply
            end,
        }
    end
    package.loaded["json"] = nil
    local progress_client = require("source.wechat.client")

    posted = {}
    local ok, err
    progress_client:putProgressAsync("99", { progress = 50, chapter_uid = 8 }, function(data, e) ok, err = data, e end)
    Assert.is_true(posted.url:find("/web/book/read", 1, true) ~= nil)
    Assert.is_true(posted.raw:find("signed", 1, true) ~= nil)
    Assert.not_nil(ok)
    Assert.eq(entered_payload.pclts, "pclts-token", "进度上报必须带 reader 状态的 pclts")

    -- 没有 succ / synckey 的回包是「收下但没记账」：不能当成功确认，否则数据静默丢失。
    read_reply = {}
    ok, err = nil, nil
    progress_client:putProgressAsync("99", { progress = 50, chapter_uid = 8 }, function(data, e) ok, err = data, e end)
    Assert.is_nil(ok)
    Assert.not_nil(err)
    read_reply = { synckey = 123 }
    ok, err = nil, nil
    progress_client:putProgressAsync("99", { progress = 50, chapter_uid = 8 }, function(data, e) ok, err = data, e end)
    Assert.not_nil(ok)
end

do
    package.preload["json"] = function()
        return {
            encode = function(tbl)
                if tbl.range then
                    return '{"range":"' .. tostring(tbl.range) .. '"}'
                end
                return "{}"
            end,
            decode = function()
                return {}
            end,
        }
    end
    package.loaded["json"] = nil
    package.loaded["source.wechat.client"] = nil
    local bookmark_client = require("source.wechat.client")
    posted = {}
    bookmark_client:addBookmarkAsync("99", 8, {
        bookId = "99",
        chapterUid = 8,
        chapterIdx = 2,
        bookVersion = 1,
        type = 1,
        style = 1,
        colorStyle = 5,
        range = "1-6",
        markText = "aGVsbG8=",
    }, function() end)
    Assert.is_true(posted.url:find("/web/book/addBookmark", 1, true) ~= nil)
    Assert.is_true(posted.raw:find('"range":"1-6"', 1, true) ~= nil)
end

do
    -- 段评：underlines 走 GET 带 bookId/chapterUid；readReviews POST 批量 range，chapterUid 是数字。
    package.preload["json"] = function()
        return { encode = require("support.json_stub").encode, decode = require("support.json_stub").decode }
    end
    package.loaded["json"] = nil
    package.loaded["source.wechat.client"] = nil
    local client = require("source.wechat.client")
    captured, posted = {}, {}
    local got
    client:underlinesAsync("3300055092", "4", function(data) got = data end)
    Assert.matches(captured[1], "^https://weread%.qq%.com/web/book/underlines%?")
    Assert.is_true(captured[1]:find("bookId=3300055092", 1, true) ~= nil)
    Assert.is_true(captured[1]:find("chapterUid=4", 1, true) ~= nil)
    Assert.eq(#got.underlines, 0)

    local ranges = { { range = "386-407", maxIdx = 0, count = 1, synckey = 0 } }
    client:readReviewsAsync("3300055092", "4", ranges, function() end)
    Assert.eq(posted.url, "https://weread.qq.com/web/book/readReviews")
    Assert.eq(posted.body.bookId, "3300055092")
    Assert.eq(posted.body.chapterUid, 4)
    Assert.eq(posted.body.reviews[1].range, "386-407")
end
