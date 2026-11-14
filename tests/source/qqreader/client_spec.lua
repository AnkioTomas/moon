--[[-- QQ阅读正文取消、身份快照、权限复查与坏响应回归。 @module tests.source.qqreader.client_spec --]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local CookieOf = require("support.cookie")
local JSON = require("support.json_stub")
local cfg, requests, replies, late, cancelled = {}, {}, {}, nil, {}
local fock_delay, fock_called, fock_cancelled, fock_uid = false, 0, false, nil
local expired
package.preload["json"] = function() return JSON end
package.preload["utils.settings"] = function() return { getSource = function() return cfg end } end
package.preload["source.auth"] = function()
    return { ok = function() end, expire = function(_id, msg) expired = msg; return msg end }
end
package.preload["http.request"] = function()
    return { get = function(url, opts, cb)
        local idx = #requests + 1
        requests[idx] = { url = url, opts = opts }
        local reply = table.remove(replies, 1)
        local function done()
            if reply.before then reply.before() end
            cb(reply.body, reply.err, reply.res)
        end
        if reply.delay then late = done else done() end
        return { cancel = function() cancelled[idx] = true end }
    end }
end
package.preload["source.qqreader.fock"] = function()
    return { chapterAsync = function(_info, _font, _chapter, _pool, _version, uid, cb)
        fock_called, fock_uid = fock_called + 1, uid
        local function done() cb("decoded fixture") end
        if fock_delay then late = done else done() end
        return { cancel = function() fock_cancelled = true end }
    end }
end
local Client = require("source.qqreader.client")
local Mapper = require("source.qqreader.mapper")
local encrypted = '{"code":0,"data":{"content":"encrypted","encrypt":true,"fontEncrypt":true,'
    .. '"chapterVipFlag":1,"authStatus":1,"fontResponse":{"fixedFontTtf":"https://example.invalid/font.ttf"}}}'
local piracy = '{"code":0,"data":{"fkp":"d2luZG93Lm9ua2V5Zm9jdXMoImtleXBvb2wiLCAyKQ==","fuid":1234567890123456}}'

local function reset()
    cfg.cookie = "ywguid=111"
    requests, replies, late, cancelled = {}, {}, nil, {}
    fock_delay, fock_called, fock_cancelled, fock_uid, expired = false, 0, false, nil, nil
end

for stage = 1, 5 do
    reset()
    replies = { { body = encrypted }, { body = piracy }, { body = encrypted }, { body = "font fixture" } }
    if stage <= 4 then replies[stage].delay = true else fock_delay = true end
    local called = false
    local job = Client.contentAsync("9", "1", function() called = true end)
    local count = #requests
    Assert.eq(count, math.min(stage, 4))
    job.cancel()
    if stage <= 4 then Assert.is_true(cancelled[stage]) else Assert.is_true(fock_cancelled) end
    late()
    Assert.is_false(called, "取消后迟到回调不能返回正文")
    Assert.eq(#requests, count, "取消后不能启动下一阶段")
end

do
    reset()
    replies = {
        { body = encrypted, before = function() cfg.cookie = "ywguid=222" end },
        { body = piracy }, { body = encrypted }, { body = "font fixture" },
    }
    local text, err
    Client.contentAsync("9", "1", function(value, reason) text, err = value, reason end)
    Assert.eq(text, "decoded fixture")
    Assert.is_nil(err)
    for idx = 1, 3 do Assert.eq(CookieOf(requests[idx]), "ywguid=111") end
    Assert.matches(requests[3].url, "fuid=1234567890123456")
    Assert.eq(fock_uid, "1234567890123456")
    Assert.is_nil(requests[4].opts.headers, "字体请求不带账号 Cookie")
end

do
    reset()
    replies = { { body = encrypted }, { body = piracy },
        { body = '{"code":0,"data":{"content":"preview","chapterVipFlag":1,"authStatus":0}}' } }
    local text, err, kind
    Client.contentAsync("9", "1", function(value, reason, result) text, err, kind = value, reason, result end)
    Assert.is_nil(text)
    Assert.eq(kind, "unpaid")
    Assert.matches(err, "未购买")
    Assert.eq(fock_called, 0)
    Assert.is_true(Mapper.locked({ chapterVipFlag = 1, authStatus = 3 }))
end

do
    reset()
    replies = { { body = '{"code":0}' } }
    local text, err
    Client.contentAsync("9", "1", function(value, reason) text, err = value, reason end)
    Assert.is_nil(text)
    Assert.matches(err, "章节内容为空")
end

for _idx, body in ipairs({
    '{"code":0}', '{"code":0,"data":{}}',
    '{"code":0,"data":{"bookList":[false]}}',
    '{"code":0,"data":{"bookList":[],"hasNext":true}}',
}) do
    reset()
    replies = { { body = body } }
    local rows, err
    Client.shelfAsync(cfg.cookie, function(value, reason) rows, err = value, reason end)
    Assert.is_nil(rows, "坏书架不能当合法空快照 reconcile")
    Assert.is_true(type(err) == "string")
end

do
    reset()
    replies = {
        { body = '{"code":0,"data":{"bookList":[{"bid":1}],"hasNext":true}}' },
        { body = '{"code":0,"data":{"bookList":[{"bid":2}],"hasNext":false}}', delay = true },
    }
    local called = false
    local job = Client.shelfAsync(cfg.cookie, function() called = true end)
    job.cancel()
    Assert.is_true(cancelled[2], "同步第一页不能覆盖第二页取消句柄")
    late()
    Assert.is_false(called)
end

do
    reset()
    local ok, err, account
    replies = { { body = '{"code":0,"data":{"nickname":"fixture"}}' } }
    Client.loginCheckAsync("uid=123; usid=fixture", function(value, reason, id) ok, err, account = value, reason, id end)
    Assert.is_true(ok)
    Assert.eq(account.id, "123")
    replies = { { body = '{"code":0,"data":{"nickname":"fixture"}}' } }
    Client.loginCheckAsync("ywguid=123; uid=456", function(value, reason) ok, err = value, reason end)
    Assert.is_nil(ok)
    Assert.matches(err, "账号标识缺失")
    replies = { { err = "redirect", res = { code = 302 } } }
    Client.loginCheckAsync(cfg.cookie, function(value, reason) ok, err = value, reason end)
    Assert.is_nil(ok)
    Assert.eq(expired, err)
    expired = nil
    replies = { { err = "offline" } }
    Client.loginCheckAsync(cfg.cookie, function(value, reason) ok, err = value, reason end)
    Assert.eq(err, "offline")
    Assert.is_nil(expired, "网络失败不能注销有效账号")
end

do
    reset()
    replies = { { body = '{"code":0,"data":{"bookList":[{"bid":9,"title":"fixture"}],"hasNext":true}}' } }
    local rows, err, more
    Client.searchAsync("fixture", function(value, reason, next_page) rows, err, more = value, reason, next_page end, 2)
    Assert.len(rows, 1)
    Assert.is_nil(err)
    Assert.is_true(more)
    Assert.matches(requests[1].url, "keyWord=fixture")
    Assert.matches(requests[1].url, "pageNo=2")
    Assert.is_nil(CookieOf(requests[1]))
    Assert.is_nil(requests[1].opts.headers.Origin, "同源 GET 不发送 Origin")
    replies = { { body = '{"code":0,"data":{}}' } }
    Client.searchAsync("fixture", function(value, reason) rows, err = value, reason end)
    Assert.is_nil(rows)
    Assert.matches(err, "搜索响应无效")
    replies = { { body = '<html id="__nuxt">challenge</html>' } }
    Client.listAsync("/book-rank/male-sell/cycle-1", function(value, reason) rows, err = value, reason end)
    Assert.is_nil(rows)
    Assert.matches(err, "列表响应无效")
end

do
    reset()
    local filters = "20001-0-0-0-0-0-0-1"
    replies = { { body = '{"code":0,"data":{"categoryList":[],"books":[],"total":0,"params":'
        .. '{"categoryId2":20001,"categoryId3":0,"finishStatus":0,"priceStatus":0,"words":0,"updateTime":0,"orderBy":0,"pageNo":1}}}' } }
    local data, err
    Client.categoryAsync(filters, function(value, reason) data, err = value, reason end)
    Assert.is_nil(err)
    Assert.is_true(type(data) == "table")
    Assert.eq(requests[1].opts.headers.Referer, "https://book.qq.com/book-cate/" .. filters)
    Assert.is_nil(requests[1].opts.headers.Origin)
    replies = { { body = '<div class="book-cate main"><a title="fixture" href="/book-detail/9">'
        .. '<p class="intro">fixture</p></a></div></div>' } }
    Client.listAsync("/book-cate/" .. filters, function(value, reason) data, err = value, reason end)
    Assert.is_nil(err)
    Assert.len(data, 1, "JSON 假空不代表官网 SSR 分类没有书")
end

do
    reset()
    replies = { { body = '{"code":0,"data":{"commentCount":32,"cursor":"","comments":'
        .. '[{"commentId":"c1","title":"title","content":"fixture","user":{"nickname":"author"},"createTime":1620000000000}]}}' } }
    local data
    Client.bookCommentsAsync("9", function(value) data = value end)
    local items = Mapper.bookComments(data.comments)
    Assert.eq(items[1].author, "author")
    Assert.eq(items[1].text, "title\nfixture")
    Assert.eq(items[1].time, 1620000000)
    Assert.eq(data.commentCount, 32)
    Assert.is_nil(CookieOf(requests[1]))
    replies = { { body = '{"code":0,"data":{"commentCount":1,"comments":[false]}}' } }
    local err
    Client.bookCommentsAsync("9", function(value, reason) data, err = value, reason end)
    Assert.is_nil(data)
    Assert.matches(err, "书评响应无效")
end
