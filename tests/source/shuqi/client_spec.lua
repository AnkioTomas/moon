--[[--
书旗：搜索签名、正文解密、目录地址、验证码登录和书架同步体。

@module tests.source.shuqi.client_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

package.preload["json"] = function() return require("support.json_stub") end

local Assert = require("support.assert")
local Json = require("support.json_stub")
local Mapper = require("source.shuqi.mapper")

Assert.eq(Mapper.searchSign("1793900599"), "2988ab30d4114f664a6792c7962c3fdf")
Assert.eq(Mapper.contentSign({ bookId = "8016707", timestamp = "1", user_id = "8000000" }),
    "bd9ab4f63403fd63fd3191ff23bc1731")
Assert.eq(Mapper.gatewaySign({ a = "1", b = "2" }, "eefc4798f28ea41622487ad80ef7e81c"),
    "11c4ba6147c7d69ab433d71889f3d992")
Assert.eq(Mapper.gatewaySign({ a = "x y" }, "eefc4798f28ea41622487ad80ef7e81c"),
    "687e16005410b369cf1f38c4459fbdc5")
Assert.eq(Mapper.javaEncode("x y"), "x+y")

local found = Mapper.searchBooks({
    status = 1,
    data = { { bid = 8062580, title = "三体", author = "刘慈欣", cover = "//img/a.jpg", desc = "科幻" } },
})
Assert.eq(#found, 1)
Assert.eq(found[1].stable_id, "8062580")
Assert.eq(found[1].title, "三体")
Assert.eq(found[1].authors, "刘慈欣")
Assert.eq(found[1].cover, "https://img/a.jpg")
Assert.eq(found[1].source_id, "shuqi")
Assert.is_nil(Mapper.searchBooks({ status = -1, info = { message = "parameter is missing" } }))

local detail = Mapper.detail({
    state = "200",
    data = { bookId = 8016707, bookName = "不灭神王", authorName = "观棋", intro = "简介", imgUrl = "https://img/b.jpg" },
})
Assert.eq(detail.stable_id, "8016707")
Assert.eq(detail.title, "不灭神王")
Assert.eq(detail.authors, "观棋")
Assert.eq(detail.intro, "简介")
local described = Mapper.detail({
    state = "200",
    data = { bookId = 8007543, bookName = "三体", authorName = "刘慈欣", desc = "科幻", imgUrl = "https://img/c.jpg" },
})
Assert.eq(described.intro, "科幻")

local toc = Mapper.chapters({
    state = 200,
    data = {
        freeContUrlPrefix = "https://free/",
        chargeContUrlPrefix = "https://charge/",
        chapterList = { {
            volumeList = {
                { chapterId = 11, chapterName = "第一章", isFreeRead = true, contUrlSuffix = "?a=1", chapterOrdid = 1 },
                { chapterId = 12, chapterName = "第二章", isFreeRead = false, isBuy = false, contUrlSuffix = "?a=2" },
                { chapterId = 13, chapterName = "第三章", isFreeRead = false, isBuy = true, contUrlSuffix = "?a=3" },
            },
        } },
    },
})
Assert.eq(#toc, 3)
Assert.eq(toc[1].uid, "11")
Assert.eq(toc[1].content_url, "https://free/?a=1")
Assert.eq(toc[1].toc_version, Mapper.TOC_VERSION)
Assert.eq(toc[1].vip, false)
Assert.eq(toc[2].vip, true)
Assert.is_nil(toc[2].content_url)
Assert.eq(toc[3].content_url, "https://charge/?a=3")

local text = Mapper.chapterText({
    state = 200,
    ChapterContent = "CTWlYm7aeXmxhVQzeeH8LaViChrfeBF6wBnhgD==",
})
Assert.eq(text, "第一段\n第二段")
Assert.eq(select(2, Mapper.chapterText({ state = 200 })), "正文为空")

local channels = Mapper.channels({
    state = 200,
    data = {
        male = { groupList = { { showName = "都市" }, { showName = "玄幻" } } },
        female = { groupList = { { showName = "现言" } } },
        press = { groupList = {} },
        cartoon = { groupList = { { showName = "漫画" } } },
    },
})
Assert.eq(channels.male[1].id, "都市")
Assert.eq(#channels.female, 1)
Assert.eq(#channels.press, 0)

local session = Mapper.session({
    status = 200,
    data = { token = "tok", userInfo = { userid = 42, nickName = "旗" } },
})
Assert.eq(session.token, "tok")
Assert.eq(session.user_id, "42")
Assert.eq(session.name, "旗")
Assert.is_nil(Mapper.session({ status = 500, message = "no" }))
Assert.is_true(Mapper.sent({ status = 200 }))
Assert.is_true(not Mapper.sent({ status = 400, message = "bad" }))

local shelf = Mapper.shelf({ detail = { { bid = 9, title = "一书", author = "甲" } } })
local nested = Mapper.shelf({ status = 200, message = "成功", data = { detail = { { bid = 9, title = "一书", author = "甲" } } } })
Assert.eq(nested[1].stable_id, "9")
Assert.eq(nested[1].title, "一书")
Assert.eq(shelf[1].stable_id, "9")
Assert.is_nil(Mapper.shelf({ message = "fail" }))
local mark = Mapper.mark({ detail = { { bid = 9, chapterid = 11, cname = "第一章", percent = 0.25 } } }, "9")
Assert.eq(mark.chapter_id, "11")
Assert.eq(mark.title, "第一章")
Assert.eq(mark.fraction, 0.25)
Assert.is_nil(Mapper.mark({ detail = { { bid = 9, chapterid = 0, percent = 0.25 } } }, "9"))
Assert.eq(Mapper.mark({ detail = { { bid = 9, chapterid = 11, percent = 2500 } } }, "9").fraction, 0.25)
Assert.eq(Mapper.mark({ data = { detail = { { bid = 9, chapterid = 11, cname = "第一章", percent = 0.25 } } } }, "9").chapter_id, "11")

local cfg = {}
local requests = {}
package.preload["utils.settings"] = function()
    return {
        getSource = function() return cfg end,
        saveSource = function() end,
        get = function() return {} end,
    }
end
package.preload["http.request"] = function()
    return {
        get = function(url, _options, callback)
            requests[#requests + 1] = { method = "GET", url = url }
            local body = "{}"
            if url:find("do=is_search", 1, true) then
                body = Json.encode({ status = 1, data = { { bid = 1, title = "三体", author = "刘慈欣" } } })
            elseif url:find("is_caterank", 1, true) then
                body = Json.encode({ status = 1, data = { { bid = 2, title = "都市书", author = "乙" } } })
            elseif url:find("chapterlist", 1, true) then
                body = Json.encode({ state = 200, data = { chapterList = {} } })
            elseif url:find("https://free/", 1, true) then
                body = Json.encode({ state = 200, ChapterContent = "CTWlYm7aeXmxhVQzeeH8LaViChrfeBF6wBnhgD==" })
            end
            callback(body, nil, nil)
            return { cancel = function() end }
        end,
        post = function(url, payload, _options, callback)
            requests[#requests + 1] = { method = "POST", url = url, body = payload }
            local body = "{}"
            if url:find("sendCode", 1, true) then
                body = Json.encode({ status = 200 })
            elseif url:find("vcode/login", 1, true) then
                body = Json.encode({ status = 200, data = { token = "tok", userInfo = { userid = 7, nickName = "旗" } } })
            elseif url:find("book/info", 1, true) then
                body = Json.encode({ state = 200, data = { bookId = 3, bookName = "详情", authorName = "丙" } })
            elseif url:find("sync/bookmarks", 1, true) then
                body = Json.encode({ detail = { { bid = 9, title = "书架书", author = "丁", chapterid = 11, cname = "第一章", percent = 0.5 } } })
            end
            callback(body, nil, nil)
            return { cancel = function() end }
        end,
    }
end

local Client = require("source.shuqi.client")

local books
Client.searchAsync("三体", function(list) books = list end)
Assert.eq(books[1].title, "三体")
local search_url = requests[#requests].url
local timestamp = search_url:match("timestamp=(%d+)")
Assert.eq(search_url:match("sign=([0-9a-f]+)"), Mapper.searchSign(timestamp))
Assert.is_true(search_url:find("platform=3", 1, true) ~= nil)
Assert.is_true(search_url:find("do=is_search", 1, true) ~= nil)

local ranked
Client.rankAsync("都市", function(list) ranked = list end)
Assert.eq(ranked[1].title, "都市书")
Assert.is_true(requests[#requests].url:find("tag=", 1, true) ~= nil)

local detail_book
Client.detailAsync("8016707", function(book) detail_book = book end)
Assert.eq(detail_book.title, "详情")
Assert.is_true(requests[#requests].body:find("platform=0", 1, true) ~= nil)
Assert.is_true(requests[#requests].body:find("sign=", 1, true) ~= nil)

local chapter
Client.contentAsync("https://free/?a=1", function(value) chapter = value end)
Assert.eq(chapter, "第一段\n第二段")

local denied
Client.shelfAsync(function(_books, err) denied = err end)
Assert.eq(denied, "未登录书旗")

local sent
Client.sendCodeAsync("13800138000", "captcha", function(ok) sent = ok end)
Assert.eq(sent, true)
Assert.is_true(requests[#requests].body:find("mobile=13800138000", 1, true) ~= nil)
Assert.is_true(requests[#requests].body:find("type=1010", 1, true) ~= nil)
Assert.is_true(requests[#requests].body:find("key=sq_h5_gateway", 1, true) ~= nil)

local logged
Client.loginAsync("13800138000", "1234", { fingerprint = "fp" }, function(value) logged = value end)
Assert.eq(logged.user_id, "7")
Assert.eq(cfg.logged_in, true)
Assert.eq(cfg.token, "tok")
Assert.eq(cfg.imei, "fp")
Assert.is_true(requests[#requests].body:find("imei=fp", 1, true) ~= nil)
Assert.is_true(requests[#requests].body:find("agent=chrome", 1, true) ~= nil)

local shelf_books
Client.shelfAsync(function(list) shelf_books = list end)
Assert.eq(shelf_books[1].title, "书架书")
Assert.is_true(requests[#requests].body:find("get_data", 1, true) ~= nil)
Assert.is_true(requests[#requests].body:find("userid%22%3A7", 1, true) ~= nil)

local added
Client.addAsync("9", function(ok) added = ok end)
Assert.eq(added, true)
Assert.is_true(requests[#requests].body:find("action%22%3A1", 1, true) ~= nil)

local removed
Client.removeAsync("9", function(ok) removed = ok end)
Assert.eq(removed, true)
Assert.is_true(requests[#requests].body:find("action%22%3A3", 1, true) ~= nil)

local mark_row
Client.progressAsync("9", function(value) mark_row = value end)
Assert.eq(mark_row.chapter_id, "11")
Assert.eq(mark_row.fraction, 0.5)

local saved
Client.putProgressAsync("9", "11", "第一章", 0.5, function(ok) saved = ok end)
Assert.eq(saved, true)
Assert.is_true(requests[#requests].body:find("action%22%3A2", 1, true) ~= nil)
Assert.is_true(requests[#requests].body:find("percent%22%3A5000", 1, true) ~= nil)
