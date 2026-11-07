--[[--
塔读：微信扫码、书架页、搜索卡片、目录序号、正文去广告。

@module tests.source.tadu.client_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

package.preload["json"] = function() return require("support.json_stub") end

local Assert = require("support.assert")
local Json = require("support.json_stub")
local Mapper = require("source.tadu.mapper")

Assert.eq(Mapper.qrUuid('<img src="/connect/qrcode/abc123">'), "abc123")
Assert.eq(Mapper.qrText("abc123"), "https://open.weixin.qq.com/connect/confirm?uuid=abc123")
Assert.eq((Mapper.wxStatus('{"wx_errcode":408}')), "wait")
local kind, wx_code, errcode = Mapper.wxStatus('{"wx_errcode":405,"wx_code":"wx1"}')
Assert.eq(kind, "ok")
Assert.eq(wx_code, "wx1")
Assert.eq(errcode, 405)
Assert.eq((Mapper.wxStatus("window.wx_errcode=403;window.wx_code='';")), "fail")
Assert.eq((Mapper.wxStatus("window.wx_errcode=402;")), "expired")
Assert.eq(Mapper.user({ data = { user = { nickname = "塔" } } }).name, "塔")
Assert.is_nil(Mapper.user({ data = {} }))

local card = [[
<a href="/book/988420/" class="bookImg"><img data-src="https://img/a.jpg" /></a>
<a href="/book/988420/" class="bookNm"><span class="orange">三体</span>宇宙</a>
<a href="/book/988420/" class="bookIntro">星际</a>
<div class="authorNm"><i></i>刘慈欣</div>
]]
local found = Mapper.books(card)
Assert.eq(#found, 1)
Assert.eq(found[1].stable_id, "988420")
Assert.eq(found[1].title, "三体宇宙")
Assert.eq(found[1].authors, "刘慈欣")
Assert.eq(found[1].intro, "星际")
Assert.eq(found[1].cover, "https://img/a.jpg")
Assert.eq(found[1].source_id, "tadu")

local home, home_err = Mapper.shelfPage("<title>小说,小说网-塔读小说网|免费阅读最新热门小说</title>")
Assert.is_nil(home)
Assert.eq(home_err, "未登录塔读")
local empty = Mapper.shelfPage("<title>我的书架</title><p>您还没有收藏</p>")
Assert.eq(#empty, 0)
local kong = Mapper.shelfPage('<title>个人中心-塔读文学网</title><div class="bookrack_table_kong"></div>')
Assert.eq(#kong, 0)
local gone = Mapper.shelfPage("<title>出错了-塔读文学网</title>")
Assert.is_nil(gone)
local row = Mapper.shelf([[
<tr class="td_con">
<td class="checkbox"><a class="check_btn" data-bookid="9"></a></td>
<td class="entry"><a class="linkBlock" href="/book/9/">一书</a></td>
<td class="table_author"><p>作者甲</p></td>
</tr>
]])
Assert.eq(#row, 1)
Assert.eq(row[1].stable_id, "9")
Assert.eq(row[1].title, "一书")
Assert.eq(row[1].authors, "作者甲")
local quoted = Mapper.shelf([[
<tr class="td_con">
<td class="checkbox"><a data-bookid='9' class="check_btn"></a></td>
<td class="entry"><a href="/book/9/" class="linkBlock">一书</a></td>
<td class="new_chapter"><a href="/book/9/1/" class="linkBlock">第1章</a></td>
<td class="table_author"><p>作者甲</p></td>
</tr>
]])
Assert.eq(quoted[1].title, "一书")
Assert.eq(quoted[1].authors, "作者甲")
Assert.is_true(Mapper.shelfHasNext('<a href="/tadu/space/reader?pgNum=2">', 1))
Assert.is_true(Mapper.shelfHasNext('<a href="/tadu/space/my-bookshelf/2">', 1))
Assert.is_true(not Mapper.shelfHasNext('<a href="/tadu/space/reader?pgNum=1">', 1))

local detail = Mapper.detail([[
<a class="bookImg"><img data-src="https://img/cover_a.jpg" /></a>
<a class="bkNm" data-name="系统劈腿，判给我半个系统">系统劈腿，判给我半个系统</a>
<span class="author">小小怪 著</span>
<p class="intro">曾经。</p>
]], "1034377")
Assert.eq(detail.title, "系统劈腿，判给我半个系统")
Assert.eq(detail.authors, "小小怪")
Assert.eq(detail.intro, "曾经。")
Assert.eq(detail.cover, "https://img/cover_a.jpg")

local toc = Mapper.chapters([[
<a href="/book/1034377/102154602/">第1章 要留清白在人间</a>
<a href="/book/1034377/102154603/">第2章 系统脚踏两条船</a>
<a href="/book/1034377/102154602/">第1章 要留清白在人间</a>
]])
Assert.eq(#toc, 2)
Assert.eq(toc[1].uid, "102154602")
Assert.eq(toc[1].source_idx, "1")
Assert.eq(toc[1].toc_version, Mapper.TOC_VERSION)
Assert.eq(toc[2].title, "第2章 系统脚踏两条船")

local text = Mapper.content({
    status = 200,
    data = { content = '<p>正文中提及塔读</p><p data-limit="OQ==">隐藏</p><p>下一段</p>' },
}, "9")
Assert.eq(text, "<p>正文中提及塔读</p><p>下一段</p>")
local denied = select(2, Mapper.content({ status = 500, msg = "请登录" }))
Assert.eq(denied, "请登录")

local settings = {}
local requests = {}
local deleted = false
local function reply(url, payload)
    if url:find("long.open.weixin.qq.com", 1, true) then
        return '{"wx_errcode":405,"wx_code":"wx1"}'
    end
    if url:find("open.weixin.qq.com/connect/qrconnect", 1, true) then
        return '<img src="/connect/qrcode/abc123">'
    end
    if url:find("/webchat/invoke/", 1, true) then return "<html>ok</html>", { "session=s1" } end
    if url:find("/user/info", 1, true) then
        return Json.encode({ data = { user = { nickname = "塔" } } })
    end
    if url:find("pgNum=1", 1, true) then
        if deleted then return '<title>个人中心-塔读文学网</title><div class="bookrack_table_kong"></div>' end
        return '<title>个人中心-塔读文学网</title><a class="check_btn" data-bookid="9"></a><a class="linkBlock" href="/book/9/">一书</a><a href="/tadu/space/reader?pgNum=2">'
    end
    if url:find("pgNum=2", 1, true) then
        return '<title>个人中心-塔读文学网</title><a class="check_btn" data-bookid="8"></a><a class="linkBlock" href="/book/8/">二书</a>'
    end
    if url:find("/api/v1/favorite/", 1, true) then
        return Json.encode({ status = 902, msg = "已收藏" })
    end
    if url:find("/delFavorites", 1, true) then
        deleted = true
        return Json.encode({ status = 200 })
    end
    if url:find("/search", 1, true) then return card end
    if url:find("/book/1034377/9/", 1, true) then
        return '<input id="bookPartResourceUrl" value="/getPartContentByCodeTable/1034377/1">'
    end
    if url:find("/getPartContentByCodeTable/", 1, true) then
        return Json.encode({ status = 200, data = { content = '<p>正文</p><p data-limit="OQ==">塔读APP</p>' } })
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
        headerAll = function(res) return res and res.cookies or {} end,
        get = function(url, options, callback)
            requests[#requests + 1] = { method = "GET", url = url, headers = options.headers }
            local body, cookies = reply(url)
            callback(body, nil, cookies and { cookies = cookies } or nil)
            return { cancel = function() end }
        end,
        post = function(url, payload, options, callback)
            requests[#requests + 1] = { method = "POST", url = url, body = payload, headers = options.headers }
            local body, cookies = reply(url, payload)
            callback(body, nil, cookies and { cookies = cookies } or nil)
            return { cancel = function() end }
        end,
    }
end

local Client = require("source.tadu.client")

local uuid
Client.qrCreateAsync(function(value) uuid = value end)
Assert.eq(uuid, "abc123")

local polled, code
Client.qrPollAsync("abc123", 408, function(value, wx) polled, code = value, wx end)
Assert.eq(polled, "ok")
Assert.eq(code, "wx1")
Assert.is_true(requests[#requests].url:find("last=408", 1, true) ~= nil)

local user
Client.exchangeAsync("wx1", function(value) user = value end)
Assert.eq(user.name, "塔")
Assert.eq(settings.logged_in, true)
Assert.eq(settings.name, "塔")
Assert.is_true(settings.cookie:find("session=s1", 1, true) ~= nil)

local shelf_html
Client.shelfAsync(function(html) shelf_html = html end)
local shelf = Mapper.shelf(shelf_html)
Assert.eq(#shelf, 2)
Assert.eq(shelf[1].stable_id, "9")
Assert.eq(shelf[2].stable_id, "8")

local added
Client.addAsync("9", function(ok) added = ok end)
Assert.eq(added, true)

local removed
Client.removeAsync("9", function(ok) removed = ok end)
Assert.eq(removed, true)
local removal
for _idx, request in ipairs(requests) do
    if request.url:find("/delFavorites", 1, true) then removal = request end
end
Assert.eq(removal.body, "bookId=9")

local books
Client.searchAsync("三体", function(html) books = Mapper.books(html) end)
Assert.eq(books[1].title, "三体宇宙")
Assert.is_true(requests[#requests].body:find("query=", 1, true) ~= nil)

local chapter
Client.contentAsync("1034377", "1", function(html) chapter = html end, "9")
Assert.eq(chapter, "<p>正文</p>")
Assert.is_true(requests[#requests].url:find("/getPartContentByCodeTable/1034377/1", 1, true) ~= nil)
