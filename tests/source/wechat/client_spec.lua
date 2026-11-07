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
            elseif url:find("/web/book/read", 1, true) then
                cb(posted.web_read_reply or '{"succ":1}')
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
            posted.eink = { method = method, path = path, query = opts.query, body = opts.body }
            if path == "/shelf/sync" then
                cb(posted.shelf_reply or { books = {}, archive = {} })
            elseif path == "/book/getProgress" then
                cb({ bookId = "42", book = { chapterUid = 1, progress = 10 } })
            elseif path == "/book/underlines" then
                cb({ underlines = {} })
            elseif path == "/review/add" then
                cb({ reviewId = "rv-1" })
            elseif path == "/feature" then
                cb({ feature = { guest_token = "gt" } })
            elseif path == "/book/read" then
                cb(posted.read_reply or { succ = 1 })
            elseif path:find("^/book/%a+[Bb]ookmark$") or path:find("^/shelf/") or path == "/review/useredit"
                    or path == "/review/delete" then
                cb({ succ = 1 })
            elseif path == "/book/bookmarklist" then
                cb({
                    synckey = 1,
                    updated = {
                        { chapterUid = 4, range = "303-332", markText = "原文", type = 1 },
                    },
                    chapters = { { chapterUid = 4, chapterIdx = 4 } },
                })
            elseif path == "/review/list" and opts.query.bookId == "77" then
                -- 翻页：hasMore=1 带 maxIdx 续拉，重复 reviewId 去重
                if opts.query.maxIdx == nil then
                    cb({ totalCount = 2, hasMore = 1, maxIdx = 5,
                        reviews = { { review = { reviewId = "a", range = "1-2", content = "甲" } } } })
                else
                    cb({ hasMore = 0, reviews = {
                        { review = { reviewId = "a", range = "1-2", content = "甲" } },
                        { review = { reviewId = "b", range = "3-4", content = "乙" } },
                    } })
                end
            elseif path == "/review/list" and opts.query.bookId == "88" then
                -- App 同款参数被拒（-2003），listType=11 能通
                if opts.query.listType == 1 then
                    cb(nil, "-2003 参数格式错误")
                else
                    cb({ hasMore = 0, reviews = { { review = { reviewId = "c", content = "丙" } } } })
                end
            elseif path == "/store/search" then
                cb(posted.search_reply or { data = { { bookInfo = { bookId = "9", title = "三体" } } } })
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
    -- 书架 / 进度 / 详情 / 目录 / 想法 / 划线全走 App 协议
    local function call(fn, ...)
        posted = {}
        fn(...)
        return posted.eink
    end
    local wire
    local req = call(client.shelfSyncAsync, client, function(d) wire = d end)
    Assert.eq(req.method .. req.path, "GET/shelf/sync")
    Assert.eq(req.query.album, 1)
    Assert.not_nil(wire)

    -- 增量索引：带游标与本地计数，只要 id 不要元数据
    req = call(client.shelfSyncIdsAsync, client, 100, 18, function(d) wire = d end)
    Assert.eq(req.method .. req.path, "GET/shelf/sync")
    Assert.eq(req.query.synckey, 100)
    Assert.eq(req.query.onlyBookid, 1)
    Assert.eq(req.query.localBookCount, 18)

    -- 变更补详情：POST /shelf/syncbook 带 bookIds
    req = call(client.shelfSyncBooksAsync, client, { "b1", "b2" }, function() end)
    Assert.eq(req.method .. req.path, "POST/shelf/syncbook")
    Assert.eq(req.body.bookIds[1], "b1")
    Assert.eq(req.body.bookIds[2], "b2")

    req = call(client.getProgressAsync, client, "42", function(d) wire = d end)
    Assert.eq(req.path, "/book/getProgress")
    Assert.eq(req.query.bookId, "42")
    Assert.eq(wire.book.progress, 10)

    req = call(client.chapterInfosAsync, client, "42", function() end)
    Assert.eq(req.path, "/book/chapterInfos")
    Assert.eq(req.body.synckeys[1], 0)
    Assert.eq(req.body.bookIds[1], "42")

    req = call(client.bookInfoAsync, client, "42", function() end)
    Assert.eq(req.path, "/book/info")
    Assert.eq(req.query.bookId, "42")

    req = call(client.addToShelfAsync, client, "123", function() end)
    Assert.eq(req.path, "/shelf/add")
    Assert.eq(req.body.bookIds[1], "123")
    req = call(client.removeFromShelfAsync, client, "123", function() end)
    Assert.eq(req.path, "/shelf/delete")
    Assert.eq(req.body.bookIds[1], "123")

    req = call(client.saveArchiveAsync, client, 7, "科幻", { "1", "2" }, function() end)
    Assert.eq(req.path, "/shelf/archive")
    Assert.eq(req.body.archiveId, 7)
    Assert.eq(req.body.name, "科幻")
    Assert.eq(req.body.bookIds[2], "2")

    req = call(client.addReviewAsync, client, { bookId = "99", content = "想法", range = "1-2" },
        function(d) wire = d end)
    Assert.eq(req.path, "/review/add")
    Assert.eq(wire.reviewId, "rv-1")
    req = call(client.editReviewAsync, client, { reviewId = "rv-1", content = "修改" }, function() end)
    Assert.eq(req.path, "/review/useredit")
    req = call(client.deleteReviewAsync, client, "rv-1", function() end)
    Assert.eq(req.path, "/review/delete")
    Assert.eq(req.body.reviewId, "rv-1")

    req = call(client.addBookmarkAsync, client, "99", 8, { bookId = "99", range = "1-6" }, function() end)
    Assert.eq(req.path, "/book/addBookmark")
    Assert.eq(req.body.range, "1-6")
    req = call(client.updateBookmarkAsync, client, { bookmarkId = "bm-1" }, function() end)
    Assert.eq(req.path, "/book/updateBookmark")
    req = call(client.removeBookmarkAsync, client, "bm-1", function() end)
    Assert.eq(req.path, "/book/removeBookmark")
    Assert.eq(req.body.bookmarkIds[1], "bm-1", "App 版删除接收 bookmarkIds 数组")

    req = call(client.underlinesAsync, client, "3300055092", "4", function(d) wire = d end)
    Assert.eq(req.path, "/book/underlines")
    Assert.eq(req.query.chapterUid, "4")
    Assert.eq(#wire.underlines, 0)
    req = call(client.readReviewsAsync, client, "3300055092", "4",
        { { range = "386-407", maxIdx = 0, count = 1, synckey = 0 } }, function() end)
    Assert.eq(req.path, "/book/readreviews")
    Assert.eq(req.body.chapterUid, 4)
    Assert.eq(req.body.reviews[1].range, "386-407")

    req = call(client.searchAsync, client, "三体", function(d) wire = d end)
    Assert.eq(req.path, "/store/search")
    Assert.eq(req.query.keyword, "三体")
    Assert.eq(req.query.v, 2)
    Assert.eq(req.query.type, 0)
    Assert.eq(wire.books[1].bookInfo.bookId, "9")
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

    client:myReviewsAsync("77", function(data) wire = data end)
    Assert.eq(posted.eink.query.maxIdx, 5, "hasMore=1 时按回包 maxIdx 续拉")
    Assert.eq(#wire.reviews, 2)
    Assert.eq(wire.reviews[2].review.content, "乙")
    Assert.eq(wire.hasMore, 0)

    client:myReviewsAsync("88", function(data) wire = data end)
    Assert.eq(posted.eink.query.listType, 11, "首页被拒改用 listType=11 重试")
    Assert.eq(wire.reviews[1].review.content, "丙")
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
    -- 进度走 App /book/read：本地坐标，阅读时长为 0。时长在统计上报里，不在这里重计。
    local Eink = require("source.wechat.eink")
    local orig_call = Eink.callAsync
    Eink.credentials = function() return { vid = "1", device_id = "d", refresh_token = "r" } end
    Eink.installId = function() return "i" end
    Eink.setGuestToken = function() end
    local fail_read = false
    Eink.callAsync = function(method, path, opts, cb)
        posted.eink = { method = method, path = path, body = opts and opts.body, query = opts and opts.query }
        if path == "/feature" then
            cb({ feature = { guest_token = "gt" } })
        elseif path == "/book/read" then
            cb(fail_read and { succ = 0 } or { succ = 1 })
        else
            cb({})
        end
        return { cancel = function() end }
    end
    posted = {}
    local ok, err
    client:putProgressAsync("99", {
        progress = 50, chapter_uid = 8, chapter_idx = 3, chapter_offset = 24000, chapter_fraction = 0.5,
    }, function(data, e) ok, err = data, e end)
    Assert.eq(posted.eink.path, "/book/read")
    Assert.eq(posted.eink.method, "POST")
    Assert.eq(posted.eink.body.bookId, "99")
    Assert.eq(posted.eink.body.chapterUid, 8)
    Assert.eq(posted.eink.body.chapterIdx, 3)
    Assert.eq(posted.eink.body.chapterOffset, 24000)
    Assert.eq(posted.eink.body.chapterProgress, 50)
    Assert.eq(posted.eink.body.progress, 50)
    Assert.eq(posted.eink.body.currentProgress, 50)
    Assert.eq(posted.eink.body.readingTime, 0)
    Assert.eq(#posted.eink.body.hours, 0)
    Assert.is_nil(posted.eink.body.readUpdateTime, "单条 /book/read 不带进度时间")
    Assert.is_nil(posted.eink.body.isResendReadingInfo)
    Assert.not_nil(posted.eink.body.signature)
    Assert.not_nil(ok)
    Assert.is_nil(err)
    Assert.is_nil(posted.url, "进度不再打网页阅读接口")

    client:putProgressAsync("99", {
        progress = 50, chapter_uid = 8, chapter_idx = 3, chapter_offset = 24000,
        chapter_fraction = 0.5,
        hours = { { startOfHour = 3600, readingTime = 15, timeZone = "+08:00", ttsTime = 0 } },
    }, function(data, e) ok, err = data, e end)
    Assert.eq(posted.eink.body.readingTime, 15, "时长随进度一起报，服务端才改坐标")
    Assert.eq(posted.eink.body.hours[1].startOfHour, 3600)
    Assert.eq(posted.eink.body.chapterOffset, 24000)
    Assert.not_nil(ok)

    fail_read = true
    ok, err = nil, nil
    client:putProgressAsync("99", { progress = 50, chapter_uid = 8 },
        function(data, e) ok, err = data, e end)
    Assert.is_nil(ok)
    Assert.not_nil(err)

    -- 跨小时走离线批量。-2054 丢掉 /config token，换新 token 再签一次。
    local sha256 = require("ffi/sha2").sha256
    local configs, batches, reject = 0, {}, true
    Eink.callAsync = function(method, path, opts, cb)
        posted.eink = { method = method, path = path, body = opts and opts.body, query = opts and opts.query }
        if path == "/feature" then
            cb({ feature = { guest_token = "gt" } })
        elseif path == "/config" then
            configs = configs + 1
            cb({ token = "t" .. configs })
        elseif path == "/book/batchUploadProgress" then
            batches[#batches + 1] = opts.body
            if reject then
                reject = false
                cb(nil, "expired", { errcode = -2054 })
            else
                cb({ succ = 1 })
            end
        elseif path == "/book/read" then
            cb({ succ = 1 })
        else
            cb({})
        end
        return { cancel = function() end }
    end
    ok, err = nil, nil
    client:putProgressAsync("99", {
        progress = 50, chapter_uid = 8, chapter_idx = 3, chapter_offset = 24000,
        hours = {
            { startOfHour = 0, readingTime = 10, timeZone = "+08:00", ttsTime = 0 },
            { startOfHour = 3600, readingTime = 15, timeZone = "+08:00", ttsTime = 0 },
        },
    }, function(data, e) ok, err = data, e end)
    Assert.not_nil(ok)
    Assert.is_nil(err)
    Assert.eq(configs, 2, "-2054 之后重新取 token")
    Assert.eq(#batches, 2)
    Assert.eq(posted.eink.path, "/book/batchUploadProgress")
    Assert.eq(posted.eink.query, nil)
    Assert.eq(batches[1].books[1].isResendReadingInfo, 0, "实时跨小时不是补报积压")
    Assert.eq(batches[1].books[1].readingTime, 25)
    Assert.eq(#batches[1].books[1].hours, 2)
    Assert.eq(batches[1].books[1].chapterOffset, 24000)
    Assert.eq(batches[1].books[1].readUpdateTime, batches[1].books[1].timestamp)
    Assert.eq(#batches[1].books[1].signature, 64, "每本仍用 guest 签名")
    local function outer(batch, token)
        return sha256(tostring(batch.timestamp) .. token .. tostring(batch.random))
    end
    Assert.eq(batches[1].signature, outer(batches[1], "t1"))
    Assert.eq(batches[2].signature, outer(batches[2], "t2"))
    Assert.is_true(batches[1].signature ~= batches[2].signature)

    local marked
    Eink.callAsync = function(_method, path, opts, cb)
        if path == "/book/markstatus" then
            marked = opts.body
            cb({ status = 4 })
        else
            cb(nil, "no")
        end
        return { cancel = function() end }
    end
    ok, err = nil, nil
    client:markFinishedAsync("99", function(data, e) ok, err = data, e end)
    Assert.eq(marked.bookId, "99")
    Assert.eq(marked.status, 4)
    Assert.eq(marked.finishInfo, 0)
    Assert.eq(marked.isCancel, 0)
    Assert.eq(marked.auto, 1)
    Assert.eq(ok.status, 4)
    Assert.is_nil(err)
    Eink.callAsync = orig_call
end

-- bookCount 大于 books 条数也原样交回（专辑、公众号不在这三份列表里）
do
    local data, err
    posted = { shelf_reply = { bookCount = 3, books = { { bookId = "1" }, { bookId = "2" } }, archive = {} } }
    client:shelfSyncAsync(function(d, e) data, err = d, e end)
    Assert.is_nil(err)
    Assert.eq(data.bookCount, 3)
    Assert.eq(#data.books, 2)
    posted = {}
end

-- Web reader session supplies the token for a zero-duration presence heartbeat only.
do
    web_replies["/web/reader/"] = '<html>{"psvts":"ps","pclts":"pc","token":"tk"}</html>'
    local state, state_err
    client:readerStateAsync("99", function(value, err) state, state_err = value, err end)
    Assert.eq(state.psvts, "ps")
    Assert.eq(state.pclts, "pc")
    Assert.eq(state.token, "tk")
    Assert.is_nil(state_err)
    Assert.is_true(captured[#captured]:find("/web/reader/", 1, true) ~= nil)

    posted.web_read_reply = '{"succ":1}'
    local result, report_err
    client:reportReadAsync({ rt = 0 }, "https://weread.qq.com/web/reader/99",
        function(value, err) result, report_err = value, err end)
    Assert.eq(posted.url, "https://weread.qq.com/web/book/read")
    Assert.eq(posted.body.rt, 0)
    Assert.eq(posted.referer, "https://weread.qq.com/web/reader/99")
    Assert.not_nil(result)
    Assert.is_nil(report_err)

    posted.web_read_reply = "{}"
    result, report_err = nil, nil
    client:reportReadAsync({ rt = 0 }, nil, function(value, err) result, report_err = value, err end)
    Assert.is_nil(result)
    Assert.not_nil(report_err)
    web_replies["/web/reader/"] = nil
end
