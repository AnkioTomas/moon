--[[--
iRead：个人 Token 请求形状、回包解码、空书架验登录态、表单摊平与映射离线用例。

@module tests.source.iread_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local JSONStub = require("support.json_stub")

package.preload["json"] = function()
    return { decode = JSONStub.decode, encode = JSONStub.encode }
end

local cfg = { token = "a1b2" }
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end }
end

local requests, replies = {}, {}
package.preload["http.request"] = function()
    return {
        post = function(url, body, opts, cb)
            requests[#requests + 1] = { url = url, body = body, opts = opts }
            cb(table.remove(replies, 1))
            return { cancel = function() end }
        end,
    }
end

for _idx, name in ipairs({ "source.iread.client", "source.iread.mapper", "source.auth" }) do
    package.loaded[name] = nil
end
local Client = require("source.iread.client")
local Mapper = require("source.iread.mapper")
local Auth = require("source.auth")

-- 书架：POST 表单 + Bearer Token；有书直接返回。
do
    replies = { '{"code":200,"data":[{"name":"书"}]}' }
    local rows
    Client.shelfAsync(function(v) rows = v end)
    Assert.len(rows, 1)
    Assert.len(requests, 1)
    Assert.eq(requests[1].url, "https://iread.ankio.net/book/list")
    Assert.eq(requests[1].opts.headers.Authorization, "Bearer a1b2")
    Assert.eq(requests[1].opts.content_type, "application/x-www-form-urlencoded")
end

-- 空书架：服务端对无效 Token 也回 200 + 空数组，必须再验登录态，不能当成「书架被清空」。
do
    requests = {}
    replies = { '{"code":200,"data":[]}', '{"code":200,"data":{"nickname":"我"}}' }
    local rows
    Client.shelfAsync(function(v) rows = v end)
    Assert.len(rows, 0)
    Assert.eq(requests[2].url, "https://iread.ankio.net/user/home")

    replies = { '{"code":200,"data":[]}', '{"code":401,"data":"x"}' }
    local err
    rows = nil
    Client.shelfAsync(function(v, e) rows, err = v, e end)
    Assert.is_nil(rows)
    Assert.eq(err, "iRead 登录已失效，请重新填写个人 Token")
    Assert.is_true(Auth.expired("iread"))
end

-- 非 200：带出 msg；没登录直接报错，不发请求。
do
    requests = {}
    replies = { '{"code":400,"msg":"书籍数据错误"}' }
    local err
    Client.chaptersAsync({ name = "书" }, function(_, e) err = e end)
    Assert.eq(err, "书籍数据错误")

    cfg.token = nil
    requests = {}
    Client.chaptersAsync({ name = "书" }, function(_, e) err = e end)
    Assert.len(requests, 0)
    cfg.token = "a1b2"
end

-- 进度：整行带回，只改位置字段；嵌套表按 PHP 的 a[b] / a[0] 摊平。
do
    requests = {}
    replies = { '{"code":200,"data":{}}' }
    local ok
    Client.saveProgressAsync({ name = "书", sourceId = 3, variable = { k = "v" }, tags = { "x", "y" } },
        { index = 4, title = "第5章", offset = 12 }, function(v) ok = v end)
    Assert.is_true(ok)
    local body = requests[1].body
    Assert.matches(requests[1].url, "/book/process$")
    Assert.matches(body, "durChapterIndex=4")
    Assert.matches(body, "durChapterPos=12")
    Assert.matches(body, "sourceId=3")
    Assert.matches(body, "variable%%5Bk%%5D=v")
    Assert.matches(body, "tags%%5B0%%5D=x")
    Assert.matches(body, "tags%%5B1%%5D=y")
end

-- 正文：book / chapter 是 JSON 字符串，index 0 基；空正文报错。
do
    requests = {}
    replies = { '{"code":200,"data":{"title":"一","content":"第一段\\n第二段"}}' }
    local text
    Client.contentAsync({ name = "书" }, '{"url":"u"}', 3, function(v) text = v end)
    Assert.eq(text, "第一段\n第二段")
    Assert.matches(requests[1].url, "/book/chapter$")
    Assert.matches(requests[1].body, "index=3")
    Assert.matches(requests[1].body, "chapter=%%7B%%22url%%22%%3A%%22u%%22%%7D")

    replies = { '{"code":200,"data":{"content":""}}' }
    local err
    Client.contentAsync({ name = "书" }, "{}", 0, function(_, e) err = e end)
    Assert.eq(err, "iRead 章节内容为空")
end

-- 映射：书名是身份，自定义封面优先、// 补协议；没书名的行丢弃。
do
    local books = Mapper.shelfList({
        { name = "书", author = "作者", coverUrl = "//img/a.jpg", kind = "玄幻" },
        { name = "二", customCoverUrl = "http://img/b.jpg", coverUrl = "x" },
        { author = "无名" },
    })
    Assert.len(books, 2)
    Assert.eq(books[1].stable_id, "书")
    Assert.eq(books[1].cover, "https://img/a.jpg")
    Assert.eq(books[2].cover, "http://img/b.jpg")
end

-- 阅读位置：第 0 章 0 偏移且没时间戳算没读过；目录 uid 是 0 基序号并带回章节原 JSON。
do
    Assert.is_nil(Mapper.readPos({ durChapterIndex = 0, durChapterPos = 0, durChapterTime = 0 }))
    Assert.eq(Mapper.readPos({ durChapterIndex = 0, durChapterPos = 0, durChapterTime = 5 }).index, 0)
    Assert.eq(Mapper.readPos({ durChapterIndex = 2, durChapterTitle = "第3章" }).title, "第3章")
    local toc = Mapper.toc({ { title = "序", url = "a" }, { title = "一", url = "b" } })
    Assert.eq(toc[2].idx, 2)
    Assert.eq(toc[2].uid, "1")
    Assert.matches(toc[2].raw, '"url":"b"')
end

-- 正文带 HTML 标签时剥掉，纯文本原样。
do
    Assert.eq(Mapper.text("<p>甲</p><p>乙</p>"), "甲\n乙")
    Assert.eq(Mapper.text("1 < 2"), "1 < 2")
end
