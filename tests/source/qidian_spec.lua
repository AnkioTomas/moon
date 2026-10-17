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

do
    local toc = Mapper.toc({ vs = {
        { vN = "卷一", cs = { { id = 11, cN = "第一章", cnt = 10, sS = 1 } } },
        { vN = "卷二", cs = { { id = 22, cN = "VIP", cnt = 20, sS = 0 } } },
    } })
    Assert.len(toc, 2)
    Assert.eq(toc[1].uid, "11")
    Assert.eq(toc[2].idx, 2)
    Assert.eq(toc[2].title, "VIP")
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
