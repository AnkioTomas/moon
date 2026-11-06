--[[--
网易云阅读：搜索、目录、Base64 正文和云端章节位置。

@module tests.source.netease.client_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

package.preload["json"] = function() return require("support.json_stub") end

local Assert = require("support.assert")
local Json = require("support.json_stub")
local Mapper = require("source.netease.mapper")

local found = Mapper.searchBooks({
    code = 0,
    data = { books = { {
        sourceUuid = "abc_4",
        title = "三体",
        author = "刘慈欣",
        description = "科幻",
        iconUrl = "//img/a.jpg",
    }, {
        sourceUrl = "/source/from_rank_4",
        title = "榜上书",
        author = "乙",
    } } },
})
Assert.eq(#found, 2)
Assert.eq(found[1].stable_id, "abc_4")
Assert.eq(found[1].title, "三体")
Assert.eq(found[1].authors, "刘慈欣")
Assert.eq(found[1].cover, "https://img/a.jpg")
Assert.eq(found[1].source_id, "netease")
Assert.eq(found[2].stable_id, "from_rank_4")
Assert.is_nil(Mapper.searchBooks({ code = -1 }))

local info = {
    code = 0,
    data = {
        book = { sourceUuid = "abc_4", title = "三体", author = "刘慈欣", coverImage = "https://img/b.jpg" },
        catalog = {
            { uuid = "c1", secId = "s1", title = "第一章", needPay = false, paid = false, wordCount = 100 },
            { uuid = "c2", secId = "s2", title = "第二章", needPay = true, paid = false, wordCount = 40 },
            { uuid = "c3", secId = "s3", title = "第三章", needPay = true, paid = true, wordCount = 10 },
        },
        config = { articleIndex = 2, firstRead = false, pagePercent = 0 },
    },
}
local detail = Mapper.detail(info)
Assert.eq(detail.stable_id, "abc_4")
Assert.eq(detail.cover, "https://img/b.jpg")
local toc = Mapper.chapters(info)
Assert.eq(#toc, 3)
Assert.eq(toc[1].uid, "c1")
Assert.eq(toc[1].sec_id, "s1")
Assert.eq(toc[1].word_count, 100)
Assert.eq(toc[1].vip, false)
Assert.eq(toc[1].toc_version, Mapper.TOC_VERSION)
Assert.eq(toc[2].vip, true)
Assert.eq(toc[3].vip, false)
Assert.eq(Mapper.progressIndex(info), 2)
Assert.is_nil(Mapper.progressIndex({ data = { config = { articleIndex = 1, firstRead = true } } }))
Assert.eq(Mapper.content({ data = { content = "PHA+55SyPC9wPg==" } }), "<p>甲</p>")
Assert.is_nil(Mapper.content({ code = 0, data = {} }))

local requests = {}
local posts = {}
local readlog_code = 0
local sms_first = false
package.preload["http.request"] = function()
    return {
        headerAll = function(res, name)
            if not res or type(res.headers) ~= "table" then return {} end
            local value = res.headers[name]
            if value == nil then return {} end
            if type(value) == "table" then return value end
            return { value }
        end,
        get = function(url, _options, callback)
            requests[#requests + 1] = url
            local body, res = "{}", nil
            if url:find("/search/book/data.json", 1, true) then
                body = Json.encode({ code = 0, data = { books = { { sourceUuid = "abc_4", title = "三体", author = "刘慈欣" } } } })
            elseif url:find("/rank/", 1, true) then
                body = Json.encode({ code = 0, data = { books = { { sourceUrl = "/source/rank_4", title = "榜书" } } } })
            elseif url:find("/reader/book/info.json", 1, true) then
                body = Json.encode(info)
            elseif url:find("content_uuid=c2", 1, true) then
                body = Json.encode({ code = -1 })
            elseif url:find("/reader/book/content.json", 1, true) then
                body = Json.encode({ code = 0, data = { content = "PHA+55SyPC9wPg==" } })
            elseif url:find("/login/context.json", 1, true) then
                body = Json.encode({ code = 0, data = { user = { nick = "甲" }, csrf_token = "fixture-csrf-2" } })
            elseif url:find("/login.do", 1, true) then
                body = '<input type="hidden" id="csrf_token" name="csrf_token" value="fixture-csrf" />'
                res = { headers = { ["Set-Cookie"] = "YUEDUWAP=fixture" } }
            elseif url:find("sendPhoneNoVerifyCode.do", 1, true) then
                body = Json.encode({ successful = true })
            elseif url:find("/sns/comment/get.json", 1, true) and url:find("id=need_login", 1, true) then
                body = Json.encode({ code = -999 })
            elseif url:find("/sns/comment/get.json", 1, true) then
                body = Json.encode({
                    code = 0,
                    data = {
                        data = { { username = "甲", text = "好看", posttime = "昨天", grade = 5 } },
                        pageQuery = { page = 1, pageCount = 3, more = true },
                    },
                })
            end
            callback(body, nil, res)
            return { cancel = function() end }
        end,
        post = function(url, body, options, callback)
            posts[#posts + 1] = { url = url, body = body, options = options }
            local wire = { successful = true, data = { targetUrl = "/" } }
            if url:find("/reader/book/readlog.json", 1, true) then
                wire = { code = readlog_code }
            elseif url:find("checkPhoneNoVerifyCode.do", 1, true) then
                wire = { successful = true, data = { isFirstLogin = sms_first, targetUrl = "/" } }
            end
            callback(Json.encode(wire), nil, nil)
            return { cancel = function() end }
        end,
    }
end

local Client = require("source.netease.client")

local books
Client.searchAsync("三体", function(list) books = list end)
Assert.eq(books[1].title, "三体")
Assert.is_true(requests[#requests]:find("key=", 1, true) ~= nil)

local ranked
Client.rankAsync("female", function(list) ranked = list end)
Assert.eq(ranked[1].stable_id, "rank_4")
Assert.is_true(requests[#requests]:find("gender=female", 1, true) ~= nil)

local wire
Client.infoAsync("abc_4", function(value) wire = value end)
Assert.eq(Mapper.detail(wire).title, "三体")

local html
Client.contentAsync("abc_4", "c1", function(value) html = value end)
Assert.eq(html, "<p>甲</p>")

local denied
Client.contentAsync("abc_4", "c2", function(_html, err) denied = err end)
Assert.eq(denied, "本章未购买")

local readlog = Mapper.readlog("abc_4", toc, 2, 0.25, "fixture-csrf", 1000)
Assert.eq(readlog.secId, "s2")
Assert.eq(readlog.article_index, 2)
Assert.eq(readlog.page_precent, 0.25)
Assert.eq(readlog.offset, 110)
Assert.eq(readlog.curDate, 1000)
Assert.is_nil(Mapper.readlog("abc_4", toc, 2, 0, nil, 1000))
Assert.is_nil(Mapper.readlog("abc_4", toc, 9, 0, "fixture-csrf", 1000))

local settings = require("utils.settings")
local cfg = settings.getSource("netease")
cfg.logged_in, cfg.cookie, cfg.csrf = nil, nil, nil
settings.saveSource("netease")
Client.reset()

local logged_out
Client.putProgressAsync("abc_4", toc, 2, 0, function(_ok, err) logged_out = err end)
Assert.eq(logged_out, "未登录网易云阅读")
Assert.eq(#posts, 0)

local signed_in
Client.passwordLoginAsync("13800138000", "secret12", function(ok) signed_in = ok end)
Assert.is_true(signed_in)
Assert.is_true(Client.loggedIn())
Assert.eq(posts[1].body:find("phone=13800138000", 1, true) ~= nil, true)
Assert.eq(posts[1].body:find("csrf_token=fixture%-csrf", 1, false) ~= nil, true)
Assert.eq(posts[1].body:find("targetUrl=false", 1, true) ~= nil, true)
Assert.eq(posts[1].options.headers.Cookie, "YUEDUWAP=fixture")

local saved
Client.putProgressAsync("abc_4", toc, 2, 0.25, function(ok) saved = ok end)
Assert.is_true(saved)
local progress = posts[#posts]
Assert.eq(progress.url:find("/reader/book/readlog.json", 1, true) ~= nil, true)
Assert.eq(progress.body:find("page_precent=0.25", 1, true) ~= nil, true)
Assert.eq(progress.body:find("secId=s2", 1, true) ~= nil, true)
Assert.eq(progress.body:find("offset=110", 1, true) ~= nil, true)
Assert.eq(progress.body:find("csrf_token=fixture%-csrf%-2", 1, false) ~= nil, true)
Assert.eq(progress.options.headers.Cookie, "YUEDUWAP=fixture")

local sent
Client.sendCodeAsync("13800138000", "abcd", function(ok) sent = ok end)
Assert.is_true(sent)
Assert.eq(requests[#requests]:find("imageCode=abcd", 1, true) ~= nil, true)
Assert.eq(requests[#requests]:find("phoneNo=13800138000", 1, true) ~= nil, true)

local before = #posts
local first
sms_first = true
Client.smsLoginAsync("13800138000", "123456", "", function(_ok, err) first = err end)
Assert.eq(first, "网易云阅读首次登录要先设置密码")
Assert.eq(#posts, before + 1)

local registered
Client.smsLoginAsync("13800138000", "123456", "secret12", function(ok) registered = ok end)
Assert.is_true(registered)
Assert.eq(posts[#posts].url:find("phoneNoFromFastLogin.json", 1, true) ~= nil, true)
Assert.eq(posts[#posts].body:find("password=secret12", 1, true) ~= nil, true)
Assert.is_true(Client.loggedIn())

readlog_code = -999
local expired
Client.putProgressAsync("abc_4", toc, 2, 0, function(_ok, err) expired = err end)
Assert.eq(expired, "网易云阅读登录已失效")
Assert.eq(Client.loggedIn(), false)

local reviews, review_pages = Mapper.comments({
    code = 0,
    data = {
        data = {
            { username = "甲", text = "好看", posttime = "昨天", grade = 4, likes = 3 },
            { username = "乙", text = "同感", replied = { username = "甲" } },
            { username = "丙" },
        },
        pageQuery = { page = 1, pageCount = 2, more = true },
    },
})
Assert.eq(#reviews, 2)
Assert.eq(reviews[1].author, "甲")
Assert.eq(reviews[1].text, "好看")
Assert.eq(reviews[1].time, "昨天")
Assert.eq(reviews[1].grade, 4)
Assert.eq(reviews[1].likes, 3)
Assert.is_nil(reviews[1].reply_to)
Assert.eq(reviews[2].reply_to, "甲")
Assert.eq(review_pages, 2)
Assert.is_nil(Mapper.comments({ code = -1 }))
local empty = Mapper.comments({ code = 0, data = { data = {} } })
Assert.eq(#empty, 0)

local loaded, load_err, pages
Client.commentsAsync("abc_4", function(items, err, count) loaded, load_err, pages = items, err, count end)
Assert.is_nil(load_err)
Assert.eq(#loaded, 1)
Assert.eq(loaded[1].author, "甲")
Assert.eq(loaded[1].text, "好看")
Assert.eq(pages, 3)
Assert.eq(requests[#requests]:find("/sns/comment/get.json?type=2&page=1&pageSize=4&id=abc_4", 1, true) ~= nil, true)

local locked
Client.commentsAsync("need_login", function(_items, err) locked = err end)
Assert.eq(locked, "未登录网易云阅读")

local Themed = require("support.theme_stubs")
Themed.install()
package.loaded["ui/network/manager"] = { runWhenConnected = function(_net, fn) fn() end }
local login_calls = {}
Client.passwordLoginAsync = function(phone, password, cb)
    login_calls[#login_calls + 1] = { method = "password", phone = phone, password = password }
    cb(nil, "fixture")
end
Client.smsLoginAsync = function(phone, code, password, cb)
    login_calls[#login_calls + 1] = { method = "sms", phone = phone, code = code, password = password }
    cb(nil, "fixture")
end
require("source.netease.setting").login()
local input = Themed.last("input")
Assert.is_true(input.shown)
input.callback("13800138000", "secret12", "")
Assert.eq(login_calls[1].method, "password")
input.callback("13800138000", "", "123456")
Assert.eq(login_calls[2].method, "sms")
Assert.eq(login_calls[2].password, "")
input.callback("13800138000", "secret12", "123456")
Assert.eq(login_calls[3].method, "sms")
Assert.eq(login_calls[3].password, "secret12")
Assert.eq(login_calls[3].code, "123456")
Assert.is_true(Themed.last("progress_dialog").closed)
