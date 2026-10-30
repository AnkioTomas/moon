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

-- 阅读页取会话参数：psvts 必需，pclts / token 可缺；没有 psvts 的页面（登录页、WAF）按失败。
do
    local Protocol = require("source.wechat.protocol")
    local url = Protocol.readerUrl("rs1")
    web_replies[url] = '<script>window.__INITIAL_STATE__={"reader":{"psvts":"PS","pclts":"PC","token":"TK"}}</script>'
    local state
    client:readerStateAsync("rs1", function(s) state = s end)
    Assert.eq(captured[#captured], url)
    Assert.eq(state.psvts, "PS")
    Assert.eq(state.pclts, "PC")
    Assert.eq(state.token, "TK")

    web_replies[url] = '<script>{"psvts" : "PS2"}</script>'
    client:readerStateAsync("rs1", function(s) state = s end)
    Assert.eq(state.psvts, "PS2")
    Assert.is_nil(state.pclts)
    Assert.is_nil(state.token)

    web_replies[url] = "<html>login</html>"
    local err
    client:readerStateAsync("rs1", function(s, e) state, err = s, e end)
    Assert.is_nil(state)
    Assert.eq(err, "reader.psvts not found")
    web_replies[url] = nil
end

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
    -- 进度走真实网页会话；原文偏移不换算成百分比，也不附带阅读时长。
    package.preload["source.wechat.eink"] = nil
    local Eink = require("source.wechat.eink")
    Eink.credentials = function() return { vid = "1", device_id = "d" } end
    Eink.installId = function() return "i" end
    Eink.setGuestToken = function() end
    require("source.wechat.context").clear()
    web_replies["/web/reader/"] = '{"psvts":"ps","pclts":"pc"}'
    posted = {}
    local ok, err
    client:putProgressAsync("99", {
        progress = 50, chapter_uid = 8, chapter_idx = 3, chapter_offset = 24000, chapter_fraction = 0.35,
    },
        function(data, e) ok, err = data, e end)
    Assert.eq(posted.url, "https://weread.qq.com/web/book/read")
    Assert.eq(posted.body.pr, 50)
    Assert.eq(posted.body.c, require("source.wechat.protocol").encode(8))
    Assert.eq(posted.body.co, 24000)
    Assert.eq(posted.body.ps, "ps")
    Assert.eq(posted.body.pc, "pc")
    Assert.is_nil(posted.body.rt)
    Assert.is_nil(posted.body.hours)
    Assert.not_nil(posted.body.s)
    Assert.not_nil(ok)

    posted.web_read_reply = "{}"
    ok, err = nil, nil
    local meta
    client:putProgressAsync("99", { progress = 50, chapter_uid = 8 },
        function(data, e, m) ok, err, meta = data, e, m end)
    Assert.is_nil(ok)
    Assert.not_nil(err)
    Assert.is_true(meta and meta.permanent, "收下不记账必须 permanent，别每轮脏同步白撞")
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
