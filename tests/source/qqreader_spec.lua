--[[--
QQ阅读书架分页、目录 / 正文映射与 Cookie 解析离线用例。

@module tests.source.qqreader_spec
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
            requests[#requests + 1] = { method = "GET", url = url, opts = opts }
            local reply = table.remove(replies, 1)
            cb(reply.body, reply.err, reply.res)
            return { cancel = function() end }
        end,
        post = function(url, body, opts, cb)
            requests[#requests + 1] = { method = "POST", url = url, body = body, opts = opts }
            local reply = table.remove(replies, 1)
            cb(reply.body, reply.err, reply.res)
            return { cancel = function() end }
        end,
    }
end

package.loaded["source.qqreader.client"] = nil
package.loaded["source.qqreader.mapper"] = nil
package.loaded["source.qqreader.setting"] = nil
local Client = require("source.qqreader.client")
local Mapper = require("source.qqreader.mapper")
local Setting = require("source.qqreader.setting")

do
    local book = Mapper.book({
        bid = 54425396, title = "大生意人", author = "赵之羽",
        category2Name = "小说", category3Name = "影视小说",
        totalWords = 452453, intro = "生意人", cover = "",
    })
    Assert.eq(book.stable_id, "54425396")
    Assert.eq(book.category, "影视小说")
    Assert.eq(book.cover, "https://wfqqreader-1252317822.image.myqcloud.com/cover/396/54425396/b_54425396.jpg")
    Assert.eq(book.meta.words, 452453)
    Assert.eq(Mapper.book({ bid = 1, title = "甲", category2Name = "小说" }).category, "小说")
end

do
    local books = Mapper.shelfList({
        { bid = 1, title = "短", info = { bid = 1, title = "全名", author = "甲", totalWords = 3 } },
        { bid = 2, title = "截断", local_book = { stable_id = "2", title = "本地", cover = "" } },
        { bid = 3, title = "兜底", author = "乙" },
    })
    Assert.eq(books[1].title, "全名")
    Assert.eq(books[2].cover, "https://wfqqreader-1252317822.image.myqcloud.com/cover/2/2/b_2.jpg")
    Assert.eq(books[3].title, "兜底")
    Assert.eq(books[3].authors, "乙")
end

do
    local toc = Mapper.toc({
        { cid = 1, chapterName = "第1章", free = 1 },
        { cid = 5, chapterName = "第5章", free = 0 },
    })
    Assert.len(toc, 2)
    Assert.eq(toc[1].uid, "1")
    Assert.is_false(toc[1].vip)
    Assert.eq(toc[2].idx, 2)
    Assert.is_true(toc[2].vip)
    Assert.is_nil(Mapper.readChapter({ lastReadChapterId = 0 }))
    Assert.eq(Mapper.readChapter({ lastReadChapterId = 5 }).uid, "5")
    Assert.is_false(Mapper.onShelf({ inShelf = 0 }))
    Assert.is_true(Mapper.onShelf({ inShelf = 1 }))
end

do
    local preview = { chapterVipFlag = 1, authStatus = 0, content = "预览", encrypt = false, fontEncrypt = false }
    Assert.is_true(Mapper.locked(preview))
    Assert.is_false(Mapper.encrypted(preview))
    Assert.is_false(Mapper.locked({ chapterVipFlag = 1, authStatus = 1, content = "已购" }))
    Assert.is_false(Mapper.locked({ chapterVipFlag = 1, authStatus = 2, content = "会员" }))
    Assert.is_false(Mapper.locked({ chapterVipFlag = 0, authStatus = 1, content = "免费" }))
    Assert.is_true(Mapper.encrypted({ encrypt = true, content = "乱码" }))
    Assert.is_true(Mapper.encrypted({ fontEncrypt = 1 }))
end

do
    Assert.eq(Setting.parseCookie("ywguid=g; ywTicket=t; bad name=1"), "ywTicket=t; ywguid=g")
    Assert.eq(Setting.browser.domain, "book.qq.com")
    Assert.eq(Setting.browser.login:match("^https://([^/]+)"), Setting.browser.domain)
    Assert.eq(Setting.browser.check:match("^https://([^/]+)"), Setting.browser.domain)
    Assert.eq(Setting.browser.login:match("^https://"), "https://")
    Assert.eq(Setting.fromPayload({ cookies = {
        { domain = ".qq.com", name = "ywguid", value = "g" },
        { domain = "book.qq.com", name = "ywTicket", value = "t" },
        { domain = "yuewen.com", name = "x", value = "y" },
    } }), "ywTicket=t; ywguid=g")
end

-- 置顶和普通列表拼在一起，翻页直到 hasNext 为假。同号去重。
do
    cfg.cookie = "ywguid=g"
    requests, replies = {}, {
        { body = '{"code":0,"data":{"topBookList":[{"bid":1,"title":"甲"}],"bookList":[{"bid":2,"title":"乙"}],"hasNext":true}}' },
        { body = '{"code":0,"data":{"topBookList":[],"bookList":[{"bid":2,"title":"乙"},{"bid":3,"title":"丙"}],"hasNext":false}}' },
    }
    local rows, err
    Client.shelfAsync(cfg.cookie, function(v, e) rows, err = v, e end)
    Assert.is_nil(err)
    Assert.len(rows, 3)
    Assert.eq(rows[3].bid, 3)
    Assert.matches(requests[1].url, "pageNo=1")
    Assert.matches(requests[1].url, "pageSize=100")
    Assert.eq(requests[1].opts.headers.Cookie, "ywguid=g")
    Assert.matches(requests[2].url, "pageNo=2")
end

-- 已保存的 Cookie 收到 -4 才标失效。校验新 Cookie 不污染旧登录态。
do
    expired = nil
    cfg.cookie = "ywguid=old"
    requests, replies = {}, { { body = '{"code":-4,"msg":"登陆鉴权失败"}' } }
    local ok, err
    Client.loginCheckAsync("ywguid=new", function(v, e) ok, err = v, e end)
    Assert.is_nil(ok)
    Assert.eq(err, "QQ阅读登录已失效")
    Assert.is_nil(expired)

    requests, replies, expired = {}, { { body = '{"code":-4,"msg":"登陆鉴权失败"}' } }, nil
    Client.loginCheckAsync(cfg.cookie, function(v, e) ok, err = v, e end)
    Assert.eq(err, "QQ阅读登录已失效")
    Assert.eq(expired, "QQ阅读登录已失效")

    requests, replies = {}, { { body = '{"code":0,"data":{"nickname":"甲"}}' } }
    Client.loginCheckAsync("ywguid=new", function(v, e) ok, err = v, e end)
    Assert.is_true(ok)
end

-- 加入 / 删除 / 进度都是 JSON。进度不传章内偏移。
do
    cfg.cookie = "ywguid=g"
    requests, replies = {}, { { body = '{"code":0}' } }
    local ok
    Client.addAsync("9", function(v) ok = v end)
    Assert.is_true(ok)
    Assert.eq(requests[1].url, "https://book.qq.com/api/bookshelf/add")
    Assert.eq(JSONStub.decode(requests[1].body).bid, 9)
    Assert.eq(requests[1].opts.content_type, "application/json")

    requests, replies = {}, { { body = '{"code":0}' } }
    Client.removeAsync("9", function(v) ok = v end)
    Assert.is_true(ok)
    Assert.eq(JSONStub.decode(requests[1].body).bids[1], 9)

    requests, replies = {}, { { body = '{"code":0}' } }
    Client.updateReadAsync("9", "11", function(v) ok = v end)
    Assert.is_true(ok)
    local body = JSONStub.decode(requests[1].body)
    Assert.eq(body.bid, 9)
    Assert.eq(body.lastReadChapterId, 11)
    Assert.is_nil(body.lastReadOffset)
end

-- 付费预览和字体加密都不当正文，哪怕 content 非空。
do
    cfg.cookie = "ywguid=g"
    requests, replies = {}, {
        { body = '{"code":0,"data":{"content":"预览两百字","chapterVipFlag":1,"authStatus":0,"encrypt":false,"fontEncrypt":false}}' },
    }
    local text, err
    Client.contentAsync("9", "5", function(v, e) text, err = v, e end)
    Assert.is_nil(text)
    Assert.eq(err, "QQ阅读 VIP 章节未购买")

    requests, replies = {}, {
        { body = '{"code":0,"data":{"content":"乱码","encrypt":true,"fontEncrypt":false,"chapterVipFlag":0,"authStatus":1}}' },
    }
    Client.contentAsync("9", "1", function(v, e) text, err = v, e end)
    Assert.is_nil(text)
    Assert.eq(err, "QQ阅读章节已加密")

    requests, replies = {}, {
        { body = '{"code":0,"data":{"content":"　　甲\\r\\n　　乙","chapterVipFlag":0,"authStatus":1,"encrypt":false}}' },
    }
    Client.contentAsync("9", "1", function(v, e) text, err = v, e end)
    Assert.eq(text, "　　甲\r\n　　乙")
    Assert.is_nil(err)
end

do
    local item = '<a title="%s" href="//book.qq.com/book-detail/%s" class="wrap"><p class="intro">简&amp;介</p>'
        .. '<a href="//book.qq.com/book-writer/1"><span>%s</span></a></a></div>'
    local books = Mapper.searchHtml(item:format("甲", "11", "乙") .. item:format("丙", "12", "丁...")
        .. item:format("甲", "11", "乙"))
    Assert.len(books, 2)
    Assert.eq(books[1].stable_id, "11")
    Assert.eq(books[1].authors, "乙")
    Assert.eq(books[1].intro, "简&介")
    Assert.is_nil(books[2].authors)
    Assert.eq(books[1].cover, "https://wfqqreader-1252317822.image.myqcloud.com/cover/11/11/b_11.jpg")
end
