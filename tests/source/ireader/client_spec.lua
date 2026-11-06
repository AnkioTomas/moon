--[[--
掌阅：网页封套、扫码、书架插入位置、目录分页、正文计费、进度章节号。

@module tests.source.ireader.client_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

package.preload["json"] = function() return require("support.json_stub") end

local Assert = require("support.assert")
local Json = require("support.json_stub")
local Mapper = require("source.ireader.mapper")

Assert.eq(Mapper.qrCode('"abc"'), "abc", "扫码 body 是带引号的 JSON 字符串")
Assert.eq(Mapper.qrCode("abc"), "abc")
Assert.is_nil(Mapper.qrCode(""))

local waiting = select(2, Mapper.login({ code = 30059, msg = "随机码未授权" }))
Assert.eq(waiting, "wait")
local user = Mapper.login({
    code = 0,
    body = { name = "usr1", session_id = "sid1", nick = "读者", avatar = "http://a" },
})
Assert.eq(user.usr, "usr1")
Assert.eq(user.zysid, "sid1")
Assert.eq(user.name, "读者")
Assert.eq(select(2, Mapper.login({ code = 1, msg = "失败" })), "fail")

local shelf = Mapper.shelf({
    data = {
        { book_id = 1, book_name = "在架", dtype = 0, is_local_book = false },
        { book_id = 2, book_name = "文件夹", dtype = 1 },
        { book_id = 3, book_name = "本地上传", dtype = 0, is_local_book = true },
    },
})
Assert.eq(#shelf, 1)
Assert.eq(shelf[1].stable_id, "1")
Assert.eq(shelf[1].source_id, "ireader")

local found = Mapper.search([[
<div data-id="42" data-src="https://img/a.jpg"><span class="name">三体</span>
<span class="author">刘慈欣</span><p class="brief">科幻</p></div>
<div data-id="42" data-src="https://img/dup.jpg"><span class="name">重复</span></div>
]])
Assert.eq(#found, 1)
Assert.eq(found[1].title, "三体")
Assert.eq(found[1].authors, "刘慈欣")
Assert.eq(found[1].cover, "https://img/a.jpg")

local channel = Mapper.channel([[
{"cli_res_id": 9, "cli_res_name": "好书"} <img src="https://img/c.jpg">
{"cli_res_id": 9, "cli_res_name": "好书"} <img src="https://img/c2.jpg">
]])
Assert.eq(#channel, 1)
Assert.eq(channel[1].stable_id, "9")
Assert.eq(channel[1].title, "好书")
Assert.eq(channel[1].cover, "https://img/c.jpg")

local toc = Mapper.chapters({
    { id = 1, name = "卷一", children = { { id = 2, name = "第一章" } } },
    { id = 3, name = "第二章" },
})
Assert.eq(#toc, 3)
Assert.eq(toc[1].uid, "1")
Assert.eq(toc[2].uid, "2")
Assert.eq(toc[2].depth, 2)
Assert.eq(toc[2].idx, 2)
Assert.eq(toc[1].toc_version, Mapper.TOC_VERSION)
Assert.eq(Mapper.progressUid(0), "1")
Assert.eq(Mapper.progressUid("4"), "5")
Assert.is_nil(Mapper.progressUid("nope"))

local settings = {}
local requests = {}
local function reply(url, payload)
    if url:find("m.zhangyue.com/search", 1, true) then return "search-page" end
    if url:find("/qrcode/get", 1, true) then
        return Json.encode({ code = 0, body = '"abc"' })
    end
    if url:find("/qrcode/result", 1, true) then
        return Json.encode({ code = 30059, msg = "随机码未授权" })
    end
    if url:find("/bookshelf/list", 1, true) then
        return Json.encode({ code = 0, body = { data = { { order = 10, top = 0 }, { order = 3, top = 1 } }, current_version = 7 } })
    end
    if url:find("/bookshelf/upsert", 1, true) then
        return Json.encode({ code = 100011, msg = "已在书架" })
    end
    if url:find("/book/detail", 1, true) then
        if url:find("book_id=locked", 1, true) then
            return Json.encode({ code = 100001, msg = "用户名不能为空" })
        end
        return Json.encode({ code = 0, body = { id = "9", name = "好书", fee_unit = 10, author = "作者" } })
    end
    if url:find("/chapter/web/list", 1, true) then
        local page = url:match("page=(%d+)")
        local row = page == "1" and { id = 1, name = "第一章" } or { id = 2, name = "第二章" }
        return Json.encode({ code = 0, body = { list = { row }, page = { totalPage = 2 } } })
    end
    if url:find("/chapter-content", 1, true) then
        if url:find("chapter_id=vip", 1, true) then
            return Json.encode({ code = 0, body = { bookContent = "<p>锁</p>", charging_info = { price = 1, is_buy = false } } })
        end
        if url:find("chapter_id=owned", 1, true) then
            return Json.encode({ code = 0, body = { bookContent = "<p>已购</p>", charging_info = { is_buy = true } } })
        end
        if url:find("chapter_id=free", 1, true) then
            return Json.encode({ code = 0, body = { bookContent = "<p>免费</p>", charging_info = nil } })
        end
        return Json.encode({ code = 0, body = { bookContent = "<p>正文</p>" } })
    end
    if url:find("/getProgress", 1, true) then
        return Json.encode({ code = 0, body = { ["9"] = { readProcess = { chapterId = 4, readPercent = 50 } } } })
    end
    if url:find("/book/progress", 1, true) then
        return Json.encode({ code = 0, body = true })
    end
    if url:find("/expired", 1, true) then
        return Json.encode({ code = 600001, msg = "登录已失效" })
    end
    return payload
end

package.preload["utils.settings"] = function()
    return {
        getSource = function() return settings end,
        saveSource = function() end,
    }
end
package.preload["http.request"] = function()
    return {
        get = function(url, _options, callback)
            requests[#requests + 1] = { method = "GET", url = url }
            callback(reply(url))
            return { cancel = function() end }
        end,
        post = function(url, payload, _options, callback)
            requests[#requests + 1] = { method = "POST", url = url, body = payload }
            callback(reply(url, payload))
            return { cancel = function() end }
        end,
    }
end

local Client = require("source.ireader.client")

Assert.eq((Client.shelfCursor({ { order = 10, top = 0 }, { order = 3, top = 1 } }, 7)), 9)
Assert.eq(select(2, Client.shelfCursor({}, nil)), 0)
Assert.eq((Client.shelfCursor(nil, nil)), 999998)

local code, qerr = nil, "unset"
Client.qrCreateAsync(function(value, err) code, qerr = value, err end)
Assert.eq(code, "abc")
Assert.is_nil(qerr)
Assert.is_true(requests[1].url:find("p29=zye5b814", 1, true) ~= nil, "设备号 p29")
Assert.is_true(requests[1].url:find("p33=com.chaozh.iReaderFree", 1, true) ~= nil, "包名 p33")
Assert.is_true(requests[1].url:find("https://api-pc.zhangyue.com/bookstore/open/user/qrcode/get?", 1, true) == 1)

local polled
Client.qrPollAsync("abc", function(wire) polled = wire end)
Assert.eq(polled.code, 30059)
Assert.is_true(requests[#requests].url:find("code=abc", 1, true) ~= nil)

---@type table|string|nil
local anon_body = "x"
local anon_err
Client.detailAsync("locked", function(body, err) anon_body, anon_err = body, err end)
Assert.is_nil(anon_body)
Assert.eq(anon_err, "未登录掌阅")

settings.usr, settings.zysid = "usr1", "sid1"
local detail
Client.detailAsync("9", function(body) detail = body end)
Assert.eq(detail.name, "好书")
Assert.eq(Mapper.detail(detail, "9").title, "好书")
Assert.eq(Mapper.detail(detail, "9").stable_id, "9")

local html, herr, kind
Client.contentAsync("9", "1", function(body, err, content_kind) html, herr, kind = body, err, content_kind end)
Assert.eq(html, "<p>正文</p>")
Assert.is_nil(herr)
Assert.is_true(requests[#requests].url:find("https://pc.ireader.com/nsr/chapter-content?", 1, true) == 1)
Assert.is_true(requests[#requests].url:find("is_whole_book=true", 1, true) ~= nil, "按本计费整本标记")

Client.contentAsync("9", "vip", function(body, err, content_kind) html, herr, kind = body, err, content_kind end)
Assert.is_nil(html)
Assert.eq(herr, "本章未购买")
Assert.eq(kind, "unpaid")

Client.contentAsync("9", "free", function(body, err, content_kind) html, herr, kind = body, err, content_kind end)
Assert.eq(html, "<p>免费</p>")
Assert.is_nil(herr)

Client.contentAsync("9", "owned", function(body, err, content_kind) html, herr, kind = body, err, content_kind end)
Assert.eq(html, "<p>已购</p>")
Assert.is_nil(herr)

local rows
Client.chaptersAsync("9", function(list) rows = list end)
Assert.eq(#rows, 2)
Assert.eq(rows[2].name, "第二章")

local added, aerr
Client.addAsync("9", "好书", function(ok, err) added, aerr = ok, err end)
Assert.eq(added, true)
Assert.is_nil(aerr)
local upsert = requests[#requests]
Assert.eq(upsert.method, "POST")
Assert.is_true(upsert.body:find('name="type"', 1, true) ~= nil)
Assert.is_true(upsert.body:find("\r\n\r\n1\r\n", 1, true) ~= nil, "插入 type=1")
Assert.is_true(upsert.body:find('"order":9', 1, true) ~= nil)
Assert.is_true(upsert.body:find('"is_local_book":false', 1, true) ~= nil)

local progress
Client.progressAsync("9", function(item) progress = item end)
Assert.eq(progress.readProcess.chapterId, 4)
Assert.eq(Mapper.progressUid(progress.readProcess.chapterId), "5")

local posted
Client.putProgressAsync("9", "5", 20, function(ok) posted = ok end)
Assert.eq(posted, true)
Assert.is_true(requests[#requests].body:find('"chapterId":"4"', 1, true) ~= nil, "进度存的是列表 id 减一")
Assert.is_true(requests[#requests].body:find('"deviceName":"掌阅网页"', 1, true) ~= nil)

local expired
Client.get("/expired", nil, function(_body, err) expired = err end)
Assert.eq(expired, "掌阅登录已失效，请点「重新登录」，用掌阅 App 扫码。")

local search_html
Client.searchAsync("三体", function(raw) search_html = raw end)
Assert.eq(search_html, "search-page")
Assert.is_true(requests[#requests].url:find("https://m.zhangyue.com/search?", 1, true) == 1)
Assert.is_true(requests[#requests].url:find("keyWord=", 1, true) ~= nil)
