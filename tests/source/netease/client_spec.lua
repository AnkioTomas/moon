--[[--
电脑端目录、正文、书评与进度，公开搜索不泄露 Cookie。

@module tests.source.netease.client_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local CookieOf = require("support.cookie")
local JSON = require("support.json_stub")
package.loaded["json"] = JSON
local Text = require("utils.text")
local Mapper = require("source.netease.mapper")
local cfg = { cookie = "NTES=desktop", logged_in = true, csrf = "legacy" }
package.loaded["utils.settings"] = { getSource = function() return cfg end }
local requests, response, failure, profile, response_meta = {}, nil, nil, nil, nil
package.loaded["http.request"] = {
    get = function(url, opts, cb)
        requests[#requests + 1] = { url = url, opts = opts }
        cb(url:find("/myinfor.do", 1, true) and profile or response, failure, response_meta)
        return { cancel = function() end }
    end,
    post = function(url, body, opts, cb)
        requests[#requests + 1] = { url = url, body = body, opts = opts }
        cb(response, failure)
        return { cancel = function() end }
    end,
    header = function(res, _name) return res.location end,
}
local Client = require("source.netease.client")
local info = {
    id = "book_4", title = "甲", author = "乙", coverImg = "//img/book.jpg", shareDescription = "简介",
    curDate = 1000, curArticleUuid = "c2", curPagePercent = 25,
    portions = {
        { id = "volume", title = "第一卷", leafNode = false, bigContentId = "10" },
        { id = "c1", title = "第一章", leafNode = true, bigContentId = "11", charSize = 100, needPay = 0 },
        { id = "c2", title = "第二章", leafNode = true, bigContentId = "12", charSize = 200, needPay = 1 },
        { id = "c3", title = "第三章", leafNode = true, bigContentId = "13", needPay = 1, isPaid = true },
    },
}
local detail = Mapper.detail(info)
Assert.eq(detail.stable_id, "book_4")
Assert.eq(detail.cover, "https://img/book.jpg")
local toc = Mapper.chapters(info)
Assert.len(toc, 4)
Assert.is_false(toc[1].leaf)
Assert.eq(toc[2].big_content_id, "11")
Assert.eq(toc[2].word_count, 100)
Assert.is_true(toc[3].vip)
Assert.is_false(toc[4].vip)
Assert.eq(Mapper.progressIndex(info), 3)
info.curDate = 0
Assert.is_nil(Mapper.progressIndex(info), "默认章节不是云端阅读进度")
info.curDate = 1000

local result, err, pages
response = JSON.encode(info)
Client.infoAsync("book_4", function(value, reason) result, err = value, reason end)
Assert.eq(Mapper.detail(result).title, "甲")
Assert.is_nil(err)
Assert.eq(requests[#requests].url, "https://yuedu.163.com/getBook.do?id=book_4")
Assert.eq(CookieOf(requests[#requests]), "NTES=desktop")
response = JSON.encode({ code = 0, data = { books = { { sourceUuid = "book_4", title = "甲" } } } })
Client.searchAsync("甲", function(value) result = value end)
Assert.eq(result[1].stable_id, "book_4")
Assert.is_nil(requests[#requests].opts.headers, "电脑端 Cookie 不发往 3g 域名")
response = JSON.encode({ content = Text.base64Encode("<p>甲</p>"), resultCode = 0 })
Client.contentAsync("book_4", toc[2], function(value, reason) result, err = value, reason end)
Assert.eq(result, "<p>甲</p>")
Assert.matches(requests[#requests].url, "/getArticleContent%.do%?")
Assert.matches(requests[#requests].url, "bigContentId=11")
Client.contentAsync("book_4", toc[1], function(value) result = value end)
Assert.matches(requests[#requests].url, "/getChapterContent%.do%?")
response = JSON.encode({ resultCode = 1, content = "" })
Client.contentAsync("book_4", toc[3], function(value, reason) result, err = value, reason end)
Assert.is_nil(result)
Assert.eq(err, "本章未购买")
response = JSON.encode({ resultCode = 0, content = "" })
Client.contentAsync("book_4", toc[2], function(value, reason) result, err = value, reason end)
Assert.is_nil(result)
Assert.eq(err, "正文为空")
response = JSON.encode({ resultCode = 0, totalPage = 2,
    data = { { username = "甲", text = "好看", posttime = "昨天", stars = 5, likes = 3 } } })
Client.commentsAsync("book_4", function(value, reason, count) result, err, pages = value, reason, count end)
Assert.eq(result[1].grade, 5)
Assert.eq(result[1].likes, 3)
Assert.eq(pages, 2)
Assert.is_nil(err)
Assert.matches(requests[#requests].url, "yuedu%.163%.com/snsComment%.do%?")
response = JSON.encode({ resultCode = 0 })
Client:addToShelfAsync("book/a,b", function(value, reason) result, err = value, reason end)
Assert.eq(result.resultCode, 0)
Assert.is_nil(err)
Assert.eq(requests[#requests].url, "https://guofeng.yuedu.163.com/subscribe.do")
Assert.matches(requests[#requests].body, "operation=addSub")
Assert.matches(requests[#requests].body, "id=book%%2Fa%%2Cb")
Assert.eq(CookieOf(requests[#requests]), "NTES=desktop")
Assert.eq(requests[#requests].opts.headers.Referer, "https://guofeng.yuedu.163.com/")
Client:removeFromShelfAsync("book/a,b", function(value, reason) result, err = value, reason end)
Assert.eq(result.resultCode, 0)
Assert.eq(requests[#requests].url,
    "https://guofeng.yuedu.163.com/shelf.do?operation=unsub&source_uuids=book%2Fa%2Cb")
Assert.eq(requests[#requests].body, "")
for _idx, raw in ipairs({ "", "<html>登录</html>", JSON.encode({ code = 0 }) }) do
    response = raw
    Client:addToShelfAsync("book_4", function(value, reason) result, err = value, reason end)
    Assert.is_nil(result, "空响应、坏 JSON 或缺少成功码不能当作加架成功")
    Assert.eq(err, "响应无效")
end
response = JSON.encode({ resultCode = -1 })
Client:removeFromShelfAsync("book_4", function(value, reason) result, err = value, reason end)
Assert.is_nil(result)
Assert.eq(err, "同步失败")
failure = "network down"
Client:addToShelfAsync("book_4", function(value, reason) result, err = value, reason end)
Assert.is_nil(result)
Assert.eq(err, "network down")
Assert.is_true(Client.loggedIn())
failure, response = nil, JSON.encode({ resultCode = -999 })
Client:removeFromShelfAsync("book_4", function(value, reason) result, err = value, reason end)
Assert.is_nil(result)
Assert.eq(err, "网易云阅读登录已失效")
Assert.is_false(Client.loggedIn())
require("source.auth").ok("netease")

local fields = Mapper.readlog("book_4", toc, 3, 0.25, 1000)
Assert.eq(fields.articleUuid, "c2")
Assert.eq(fields.curPagePercent, 25)
Assert.eq(fields.date, 1000)
Assert.is_nil(Mapper.readlog("book_4", toc, 9, 0, 1000))
Assert.eq(Mapper.readlog("book_4", toc, 3, 2, 1000).curPagePercent, 100)
profile = '<title>个人资料--网易云阅读</title><a id="editNickName"></a>'
response = "1\n"
Client.putProgressAsync("book_4", toc, 3, 0.25, function(value, reason) result, err = value, reason end)
Assert.is_true(result)
Assert.matches(requests[#requests].url, "/addUserReadLog%.do")
Assert.matches(requests[#requests].body, "curPagePercent=25")
Assert.matches(requests[#requests].body, "articleUuid=c2")
Assert.is_nil(requests[#requests].body:find("csrf", 1, true))
response = "0"
Client.putProgressAsync("book_4", toc, 3, 0, function(value, reason) result, err = value, reason end)
Assert.is_nil(result)
Assert.eq(err, "网易云阅读进度保存失败", "失败不能把本地脏进度标成已同步")
profile = '<title>登录--网易云阅读</title><div id="login-container"></div>'
response = "1"
local before = #requests
Client.putProgressAsync("book_4", toc, 3, 0, function(value, reason) result, err = value, reason end)
Assert.is_nil(result, "匿名接口也回 1，登录过期不能算同步成功")
Assert.not_nil(err)
Assert.eq(#requests, before + 1, "失效会话不发进度写请求")
Assert.is_false(Client.loggedIn())
Assert.is_true(require("source.auth").expired("netease"))
require("source.auth").ok("netease")
response_meta = { code = 302, location = "https://yuedu.163.com/loginForm.do?targetUrl=myinfor.do" }
failure = "HTTP 302"
Client.putProgressAsync("book_4", toc, 3, 0, function(value, reason) result, err = value, reason end)
Assert.is_nil(result)
Assert.eq(err, "网易云阅读登录已失效")
Assert.is_false(Client.loggedIn(), "HTTP 层把 302 作为错误时仍要识别真正的登录重定向")
require("source.auth").ok("netease")
response_meta = nil
failure = "network down"
Client.putProgressAsync("book_4", toc, 3, 0, function(value, reason) result, err = value, reason end)
Assert.is_nil(result)
Assert.eq(err, "network down")
Assert.is_true(Client.loggedIn(), "网络失败不能被当成退出登录")
profile = nil
Client.infoAsync("book_4", function(value, reason) result, err = value, reason end)
Assert.is_nil(result)
Assert.eq(err, "network down")
failure = nil

response = '<title>个人资料--网易云阅读</title><a id="editNickName"></a>'
Client.loginCheckAsync("NTES=new", function(value, reason) result, err = value, reason end)
Assert.is_true(result)
Assert.eq(cfg.cookie, "NTES=desktop", "校验不能直接替换当前会话")
Assert.eq(CookieOf(requests[#requests]), "NTES=new")
response = '<title>登录--网易云阅读</title><div id="login-container"></div>'
Client.loginCheckAsync("NTES=bad", function(value, reason) result, err = value, reason end)
Assert.is_false(result)
Assert.not_nil(err)
Assert.eq(cfg.cookie, "NTES=desktop")
Assert.is_true(Client.loggedIn(), "新 Cookie 校验失败不能注销当前有效账号")

local request_api = package.loaded["http.request"]
local get = request_api.get
local late_check
request_api.get = function(_url, _opts, cb)
    late_check = cb
    return { cancel = function() end }
end
Client.putProgressAsync("book_4", toc, 3, 0, function(value, reason) result, err = value, reason end)
cfg.cookie = "NTES=replacement"
late_check('<div id="login-container"></div>')
Assert.is_nil(result)
Assert.is_true(Client.loggedIn(), "旧请求迟到的登录失效不能注销刚换上的账号")
cfg.cookie = "NTES=desktop"
request_api.get = get

local stored_toc
package.loaded["source.toc"] = {
    put = function(id, stable_id, chapters)
        Assert.eq(id, "netease")
        Assert.eq(stable_id, "book_4")
        stored_toc = chapters
        return true
    end,
}
local source = require("source.netease").new()
local identity = { source_id = "netease", stable_id = "book_4" }
response = JSON.encode(info)
source:getProgressAsync(identity, function(value, reason) result, err = value, reason end)
Assert.eq(result.chapter_idx, 3)
Assert.eq(result.chapter_fraction, 0.25)
Assert.eq(result.extra.chapter_fraction, 0.25)
Assert.eq(result.fraction, 0.5625)
Assert.len(stored_toc, 4)
Assert.is_nil(err)
info.curDate = 0
response = JSON.encode(info)
local meta
source:getProgressAsync(identity, function(value, reason, status) result, err, meta = value, reason, status end)
Assert.is_nil(result)
Assert.is_nil(err)
Assert.is_true(meta.empty)

local old_toc = { { idx = 1, uid = "legacy", title = "旧缓存章", toc_version = 1 } }
package.loaded["source.toc"].read = function() return old_toc end
local network = package.loaded["ui/network/manager"]
package.loaded["ui/network/manager"] = { isConnected = function() return false end }
before = #requests
source:loadTocAsync(identity, function(value, reason) result, err = value, reason end)
require("support.stubs").flush()
Assert.eq(result, old_toc, "协议升级不能让离线用户的旧缓存目录失效")
Assert.is_nil(err)
Assert.eq(#requests, before)
package.loaded["ui/network/manager"] = { isConnected = function() return true end }
source:loadTocAsync(identity, function(value, reason) result, err = value, reason end)
Assert.eq(result[1].toc_version, Mapper.TOC_VERSION, "恢复联网后刷新新协议需要的章节字段")
Assert.eq(result[2].big_content_id, "11")
package.loaded["ui/network/manager"] = network

local progress_cancelled, toc_cancelled = 0, 0
local live_client = package.loaded["source.netease.client"]
live_client.putProgressAsync = function(book_id, chapters, idx, within, cb)
    Assert.eq(book_id, "book_4")
    Assert.eq(chapters, toc)
    Assert.eq(idx, 3)
    Assert.eq(within, 0.25)
    cb(true)
    return { cancel = function() progress_cancelled = progress_cancelled + 1 end }
end
source.loadTocAsync = function(_self, _identity, cb)
    cb(toc)
    return { cancel = function() toc_cancelled = toc_cancelled + 1 end }
end
local handle = source:putProgressAsync(identity, { chapter_idx = 3, chapter_fraction = 0.25 },
    function(value, reason) result, err = value, reason end)
Assert.is_true(result)
Assert.is_nil(err)
handle:cancel()
Assert.eq(progress_cancelled, 1, "同步目录回调不能覆盖进度请求的取消句柄")
Assert.eq(toc_cancelled, 0)
source:putProgressAsync(identity, { chapter_idx = 99 }, function(value, reason) result, err = value, reason end)
Assert.is_nil(result)
Assert.eq(err, "缺少网易云阅读章节位置")
