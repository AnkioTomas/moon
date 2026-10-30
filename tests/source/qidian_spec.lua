--[[--
起点书架分页、目录 / 正文映射与 Cookie 解析离线用例。

@module tests.source.qidian_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local JSONStub = require("support.json_stub")

package.preload["json"] = function()
    return { decode = JSONStub.decode, encode = JSONStub.encode }
end

local cfg = {}
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end }
end

local expired
package.preload["source.auth"] = function()
    return { expire = function(_, msg) expired = msg; return msg end, ok = function() end }
end

local requests, replies = {}, {}
package.preload["http.request"] = function()
    return {
        get = function(url, opts, cb)
            requests[#requests + 1] = { url = url, opts = opts }
            local reply = table.remove(replies, 1)
            cb(reply.body, reply.err, reply.res)
            return { cancel = function() end }
        end,
        post = function(url, body, opts, cb)
            requests[#requests + 1] = { url = url, body = body, opts = opts }
            local reply = table.remove(replies, 1)
            cb(reply.body, reply.err, reply.res)
            return { cancel = function() end }
        end,
    }
end

package.loaded["source.qidian.client"] = nil
package.loaded["source.qidian.mapper"] = nil
package.loaded["source.qidian.setting"] = nil
local Client = require("source.qidian.client")
local Mapper = require("source.qidian.mapper")
local Setting = require("source.qidian.setting")

local function page(data)
    return '<script id="vite-plugin-ssr_pageContext" type="application/json">'
        .. JSONStub.encode({ pageContext = { pageProps = { pageData = data } } }) .. "</script>"
end

do
    local data = Mapper.pageData(page({ bookInfo = { bookId = 9 } }))
    Assert.eq(data.bookInfo.bookId, 9)
    Assert.is_nil(Mapper.pageData("<html>登录</html>"))
end

do
    local book = Mapper.book({
        bookId = 101, bookName = "诡秘", authorName = "乌贼", chanName = "玄幻",
        wordsCnt = 100, desc = "　　甲<br>乙",
    })
    Assert.eq(book.stable_id, "101")
    Assert.eq(book.cover, "https://bookcover.yuewen.com/qdbimg/349573/101/180")
    Assert.eq(book.meta.words, 100)
    Assert.eq(book.intro, "　　甲\n乙")
end

do
    local books = Mapper.shelfList({
        { bid = 1, bName = "短", info = { bookId = 1, bookName = "全名", authorName = "甲", wordsCnt = 3 } },
        { bid = 2, bName = "截断", local_book = { stable_id = "2", title = "本地", cover = "" } },
        { bid = 3, bName = "兜底", bAuth = "乙" },
    })
    Assert.eq(books[1].title, "全名")
    Assert.eq(books[2].cover, "https://bookcover.yuewen.com/qdbimg/349573/2/180")
    Assert.eq(books[3].title, "兜底")
    Assert.eq(books[3].authors, "乙")
end

-- 分类开关：关 = 题材；开 = 自定义分组（互斥，不混合）。
do
    cfg.category_as_group = false
    local off = Mapper.shelfList({
        { bid = 1, cateName = "玄幻", _group_name = "追更", info = { bookId = 1, bookName = "甲", chanName = "玄幻" } },
        { bid = 2, cateName = "都市", info = { bookId = 2, bookName = "乙", chanName = "都市" } },
    })
    Assert.eq(off[1].category, "玄幻", "关：进组仍用题材")
    Assert.eq(off[2].category, "都市", "关：没进组用题材")
    cfg.category_as_group = true
    local on = Mapper.shelfList({
        { bid = 1, cateName = "玄幻", _group_name = "追更", info = { bookId = 1, bookName = "甲", chanName = "玄幻" } },
        { bid = 2, cateName = "都市", info = { bookId = 2, bookName = "乙", chanName = "都市" } },
    })
    Assert.eq(on[1].category, "追更", "开：进组用分组名")
    Assert.is_nil(on[2].category, "开：没进组不写题材")
    cfg.category_as_group = false
end

do
    local toc = Mapper.toc({ vs = {
        { vN = "卷一", cs = { { id = 11, cN = "第一章", cnt = 10, sS = 1, uT = "2022-10-07 10:22:55" } } },
        { vN = "卷二", cs = { { id = 22, cN = "VIP", cnt = 20, sS = 0, uT = "bad" } } },
    } })
    Assert.len(toc, 2)
    Assert.eq(toc[1].uid, "11")
    Assert.eq(toc[1].updated, 1665109375)
    Assert.is_false(toc[1].vip)
    Assert.eq(toc[2].idx, 2)
    Assert.eq(toc[2].title, "VIP")
    Assert.is_nil(toc[2].updated)
    Assert.is_true(toc[2].vip)
    Assert.eq(Mapper.chapterTime("2022-10-07 10:22"), 1665109320)
    Assert.is_nil(Mapper.chapterTime("2022-10-07"))
    local read = Mapper.readChapter({ readCid = 730944635, readCname = "第一章" })
    Assert.eq(read.uid, "730944635")
    Assert.eq(read.title, "第一章")
    Assert.is_nil(Mapper.readChapter({ readCid = 0 }))
    Assert.is_nil(Mapper.readChapter({}))
end

do
    Assert.eq(Mapper.chapterText("<p>　　甲<p>　　乙&amp;丙"), "\n　　甲\n　　乙&丙")
    Assert.is_nil(Mapper.chapterText(""))
    Assert.is_false(Mapper.locked({ vipStatus = 0, isBuy = 0, content = "<p>甲" }))
    Assert.is_true(Mapper.locked({ vipStatus = 1, isBuy = 0 }))
    Assert.is_false(Mapper.locked({ vipStatus = 1, isBuy = 1 }))
end

do
    Assert.eq(Setting.parseCookie("_csrfToken=t; ywkey=k; bad name=1"), "_csrfToken=t; ywkey=k")
    Assert.eq(Client.csrf("_csrfToken=t; ywkey=k"), "t")
    Assert.is_nil(Client.csrf("ywkey=k"))
    Assert.eq(Setting.browser.domain, "m.qidian.com")
    Assert.eq(Setting.browser.login:match("^https://([^/]+)"), Setting.browser.domain)
    Assert.eq(Setting.browser.check:match("^https://([^/]+)"), Setting.browser.domain)
    Assert.eq(Setting.fromPayload({ cookies = {
        { domain = ".qidian.com", name = "_csrfToken", value = "t" },
        { domain = "m.qidian.com", name = "ywkey", value = "k" },
        { domain = "evil.com", name = "x", value = "y" },
    } }), "_csrfToken=t; ywkey=k")
end

-- 默认分组翻完再拉其它分组，请求带 _csrfToken。
do
    cfg.cookie = "ywkey=k; _csrfToken=tok"
    requests, replies = {}, {
        { body = '{"code":0,"data":{"list":[{"bid":1,"bName":"甲"}],"groups":[{"groupId":-100,"bookCount":1},{"groupId":2,"bookCount":1}],"page":{"isLast":1}}}' },
        { body = '{"code":0,"data":{"list":[{"bid":1,"bName":"甲"},{"bid":2,"bName":"乙"}],"page":{"isLast":1}}}' },
    }
    local rows, err
    Client.shelfAsync(cfg.cookie, function(v, e) rows, err = v, e end)
    Assert.is_nil(err)
    Assert.len(rows, 2)
    Assert.eq(rows[2].bid, 2)
    Assert.len(requests, 2)
    Assert.matches(requests[1].url, "gid=%-100")
    Assert.matches(requests[1].url, "_csrfToken=tok")
    Assert.matches(requests[2].url, "gid=2")
end

-- 书架页 302：已保存的 Cookie 标失效。
do
    expired = nil
    requests, replies = {}, { { body = nil, err = "HTTP 302", res = { code = 302 } } }
    local ok, err
    Client.loginCheckAsync(cfg.cookie, function(v, e) ok, err = v, e end)
    Assert.is_nil(ok)
    Assert.eq(err, "起点登录已失效")
    Assert.eq(expired, "起点登录已失效")
end

-- 加入书架走 POST，书号在表单里。
do
    requests, replies = {}, { { body = '{"code":0,"data":{"9":{"code":0,"message":"操作成功"}}}' } }
    local ok
    Client.addAsync("9", function(v) ok = v end)
    Assert.is_true(ok)
    Assert.matches(requests[1].url, "/webcommon/bookshelf/addbooks%?")
    Assert.eq(requests[1].body, "bookId=9")
end

-- 进度上传带章节更新时间的 unix 秒。空时间不发请求，避免把阅读状态写坏。
do
    local Stubs = require("support.stubs")
    cfg.cookie = "ywkey=k; _csrfToken=tok"
    requests, replies = {}, {}
    local ok, err
    Client.updateReadAsync("9", "11", "c1", false, "", function(v, e) ok, err = v, e end)
    Stubs.flush()
    Assert.is_nil(ok)
    Assert.eq(err, "起点章节时间缺失")
    Assert.len(requests, 0)

    requests, replies = {}, { { body = '{"code":0}' } }
    Client.updateReadAsync("9", "11", "c1", true, 1665109375, function(v, e) ok, err = v, e end)
    Assert.is_true(ok)
    Assert.matches(requests[1].url, "/webcommon/chapter/updReadStatus%?")
    Assert.matches(requests[1].body, "chapterUpdateTime=1665109375")
    Assert.matches(requests[1].body, "isVip=1")
    Assert.matches(requests[1].body, "chapterId=11")

    requests, replies, expired = {}, { { body = '{"code":1403,"msg":"登录失效"}' } }, nil
    Client.updateReadAsync("9", "11", "c1", 0, "1665109375", function(v, e) ok, err = v, e end)
    Assert.is_nil(ok)
    Assert.eq(err, "起点登录已失效")
    Assert.eq(expired, "起点登录已失效")
end

do
    requests, replies = {}, { { body = page({ records = { { bid = 7, bName = "甲", bAuth = "乙", cat = "玄幻" } } }) } }
    local got
    Client.rankAsync("/rank/yuepiao/catid21/", function(v) got = v end)
    Assert.matches(requests[1].url, "/rank/yuepiao/catid21/$")
    local books = Mapper.rank(got)
    Assert.eq(books[1].stable_id, "7")
    Assert.eq(books[1].authors, "乙")

    replies = { { body = "<html>nope</html>" } }
    local err
    Client.rankAsync("/rank/x/", function(v, e) got, err = v, e end)
    Assert.is_nil(got)
    Assert.is_true(err ~= nil)
end

do
    local books = Mapper.search({ bookInfo = { records = {
        { bid = 7, bName = "甲", bAuth = "乙...", cat = "玄幻", desc = "简<br>介" },
        { bid = 8, bName = "丙", bAuth = "丁" },
    } } })
    Assert.len(books, 2)
    Assert.eq(books[1].stable_id, "7")
    Assert.is_nil(books[1].authors)
    Assert.eq(books[1].intro, "简\n介")
    Assert.eq(books[2].authors, "丁")

    requests, replies = {}, { { body = page({ bookInfo = { records = {} } }) } }
    local got
    Client.searchAsync("斗罗", function(v) got = v end)
    Assert.matches(requests[1].url, "/soushu/%%E6%%96%%97%%E7%%BD%%97%.html$")
    Assert.is_true(got.bookInfo ~= nil)
end
