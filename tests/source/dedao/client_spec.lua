--[[--
得到：扫码链接、已购书架、搜索、目录章节号、SVG 解密。

@module tests.source.dedao.client_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

package.preload["json"] = function() return require("support.json_stub") end
package.preload["ui/uimanager"] = function()
    return { nextTick = function(_ui, fn) fn() end, scheduleIn = function(_ui, _delay, fn) fn() end }
end
package.preload["ui.guard"] = function()
    return { call = function(_label, fn, ...) return fn(...) end }
end

local Assert = require("support.assert")
local Json = require("support.json_stub")
local Mapper = require("source.dedao.mapper")

Assert.eq(Mapper.qrText("igetweb1"), "https://m.igetget.com/oauth/qrcode/v2/authorize?token=igetweb1&source=igetweb&dv=")
Assert.eq(Mapper.login({ data = { status = 0 } }), "wait")
Assert.eq(Mapper.login({ data = { status = 1 } }), "ok")
Assert.eq(Mapper.login({ data = { status = 2 } }), "fail")

local shelf = Mapper.shelf({
    list = {
        { type = 2, enid = "e1", title = "三体", author = "刘慈欣", icon = "https://c" },
        { type = 13, enid = "e2", title = "听书" },
        { type = 230, enid = "e3", title = "本地上传" },
    },
})
Assert.eq(#shelf, 1)
Assert.eq(shelf[1].stable_id, "e1")
Assert.eq(shelf[1].source_id, "dedao")

local found = Mapper.search({
    data = { moduleList = { { layerDataList = {
        { type = 2, Title = "<hl>三体</hl>全集", author = "刘慈欣", image = "https://img", extra = { enid = "e1" } },
        { type = 2, Title = "重复", extra = { enid = "e1" } },
        { type = 66, Title = "课程", extra = { enid = "e9" } },
    } } } },
})
Assert.eq(#found, 1)
Assert.eq(found[1].title, "三体全集")
Assert.eq(found[1].cover, "https://img")

local toc = Mapper.chapters({
    bookInfo = {
        orders = { { pathInEpub = "chapter01.xhtml", chapterId = "c1" } },
        toc = {
            { href = "chapter01.xhtml#sigil", text = "序", level = 0, playOrder = 2 },
            { href = "chapter02.xhtml", text = "第二章", level = 1, playOrder = 1 },
        },
    },
})
Assert.eq(#toc, 2)
Assert.eq(toc[1].uid, "chapter02.xhtml")
Assert.eq(toc[1].toc_version, Mapper.TOC_VERSION)
Assert.eq(toc[2].uid, "c1")
Assert.eq(toc[2].depth, 1)
Assert.eq(Mapper.progressUid("c1"), "c1")
Assert.is_nil(Mapper.progressUid(""))

local cipher = "UzX9+34+GWS32TeZD7pKPYHRf4jS1JHrdgxu4mR6gj5QxmZ0tAASG61dGrB/0C0+"
Assert.eq(Mapper.pageText(cipher), "第一段\n第二段")

local settings = { cookie = "csrfToken=c; token=t", logged_in = true }
package.loaded["source.logout"] = { clear = function(_id, clear) clear(); return true end }
local requests = {}
local cookies, qr_status = {}, 0
local pages_reply, remove_reply
local function reply(url, payload)
    if url:find("/loginapi/getAccessToken", 1, true) then return '"oauth-token"' end
    if url:find("/qrcode/check_login", 1, true) then
        return Json.encode({ errCode = 0, data = { status = qr_status } })
    end
    if url:find("/oauth/api/embedded/qrcode", 1, true) then
        return Json.encode({ errCode = 0, data = { qrCodeString = "igetweb9" } })
    end
    if url:find("/api/hades/v2/product/list", 1, true) then
        return Json.encode({ h = { c = 0 }, c = { is_more = false, list = {
            { type = 2, enid = "e1", title = "三体", author = "刘慈欣" },
        } } })
    end
    if url:find("/bookshelf/add", 1, true) then
        return Json.encode({ h = { c = 0 }, c = { data = { n = 1 } } })
    end
    if url:find("/product/pcremove", 1, true) then
        return remove_reply or Json.encode({ h = { c = 0 }, c = { n = 0 } })
    end
    if url:find("/api/pc/user/info", 1, true) then
        return Json.encode({ h = { c = 0 }, c = { uid_hazy = "test-user" } })
    end
    if url:find("/api/search/pc/tophits", 1, true) then
        return Json.encode({ h = { c = 0 }, c = { data = { moduleList = { { layerDataList = {
            { type = 2, Title = "<hl>三体</hl>", author = "刘", extra = { enid = "e1" } },
        } } } } } })
    end
    if url:find("/pc/ebook2/v1/pc/detail", 1, true) then
        return Json.encode({ h = { c = 0 }, c = { enid = "e1", title = "三体", book_author = "刘慈欣", cover = "https://c" } })
    end
    if url:find("/read/token", 1, true) then
        return Json.encode({ h = { c = 0 }, c = { token = "read-token" } })
    end
    if url:find("/get_pages", 1, true) then
        if pages_reply then return pages_reply() end
        if payload and payload:find('"chapter_id":"vip"', 1, true) then
            return Json.encode({ h = { c = 4000, e = "user no legal!" } })
        end
        return Json.encode({ h = { c = 0 }, c = { is_end = true, pages = { { svg = cipher, is_last = true } } } })
    end
    if url:find("/getread", 1, true) then
        return Json.encode({ h = { c = 0 }, c = { data = { findex = "c1", windex = 0 } } })
    end
    if url:find("/addread", 1, true) then
        return Json.encode({ h = { c = 0 }, c = { status = 1 } })
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
        headerAll = function() return cookies end,
        get = function(url, options, callback)
            requests[#requests + 1] = { method = "GET", url = url, headers = options.headers }
            callback(reply(url), nil, {})
            return { cancel = function() end }
        end,
        post = function(url, payload, options, callback)
            requests[#requests + 1] = { method = "POST", url = url, body = payload, headers = options.headers }
            local raw, err = reply(url, payload)
            callback(raw, err, {})
            return { cancel = function() end }
        end,
    }
end

local Client = require("source.dedao.client")

local token
Client.accessTokenAsync(function(value) token = value end)
Assert.eq(token, "oauth-token")
Assert.eq(requests[#requests].headers["Xi-DT"], "web")
Assert.eq(requests[#requests].headers["Xi-Csrf-Token"], "c")

local code
Client.qrCreateAsync("oauth-token", function(value) code = value end)
Assert.eq(code, "igetweb9")
Assert.eq(requests[#requests].headers["X-Oauth-Access-Token"], "oauth-token")

local rows
Client:shelfSyncAsync(function(body) rows = Mapper.shelf(body) end)
Assert.eq(#rows, 1)
Assert.is_true(requests[#requests].body:find('"category":"ebook"', 1, true) ~= nil)

local added
Client:addToShelfAsync("e1", function(ok) added = ok end)
Assert.eq(added, true)
Assert.is_true(requests[#requests].body:find('"book_enids":["e1"]', 1, true) ~= nil)
Assert.is_true(requests[#requests].body:find('"ptype":2', 1, true) ~= nil)

local books
Client.searchAsync("三体", function(body) books = Mapper.search(body) end)
Assert.eq(books[1].title, "三体")
Assert.is_true(requests[#requests].body:find('"tab_type":2', 1, true) ~= nil)

local fallback = Mapper.detail({
    title = "", operating_title = "得到书", book_author = "甲", book_intro = "简介",
}, "e1")
Assert.eq(fallback.title, "得到书")
Assert.eq(fallback.authors, "甲")
Assert.eq(fallback.stable_id, "e1")

local detail
Client.detailAsync("e1", function(body) detail = Mapper.detail(body, "e1") end)
Assert.eq(detail.title, "三体")
Assert.eq(detail.authors, "刘慈欣")

local text, terr, kind
Client.contentAsync("e1", "c1", function(value, err, content_kind) text, terr, kind = value, err, content_kind end)
Assert.eq(text, "第一段\n第二段")
Assert.is_nil(terr)
Assert.is_true(requests[#requests].url:find("/ebk_web_go/v2/get_pages", 1, true) ~= nil)
Assert.is_true(requests[#requests].body:find('"token":"read-token"', 1, true) ~= nil)

Client.contentAsync("e1", "vip", function(value, err, content_kind) text, terr, kind = value, err, content_kind end)
Assert.is_nil(text)
Assert.eq(terr, "本章未购买")
Assert.eq(kind, "unpaid")

local progress
Client.progressAsync("e1", function(item) progress = item end)
Assert.eq(progress.findex, "c1")

local posted
Client.putProgressAsync("e1", "c1", "序", function(ok) posted = ok end)
Assert.eq(posted, true)
Assert.is_true(requests[#requests].body:find('"findex":"c1"', 1, true) ~= nil)

cookies, qr_status = { "session=new-login; Path=/" }, 1
local login
local candidate = { csrfToken = "candidate" }
local old_cookie = settings.cookie
Client.qrPollAsync("oauth-token", "igetweb9", function(wire) login = wire end, candidate)
Assert.eq(login.data.status, 1)
Assert.eq(settings.cookie, old_cookie)
Assert.eq(candidate.session, "new-login")
Client.confirmLoginAsync(candidate, function(ok) Assert.is_true(ok) end)
Assert.matches(settings.cookie, "session=new%-login")
Assert.matches(Client.cookie(), "session=new%-login")
Client.loggedIn()
Assert.matches(Client.cookie(), "session=new%-login")
cookies = {}

local removed, remove_err
for _idx, bad in ipairs({ "<html>upstream unavailable</html>", "broken", "{}", '{"h":{},"c":{}}',
    '{"h":{"c":401},"c":{}}' }) do
    remove_reply = bad
    Client:removeFromShelfAsync("e1", function(ok, err) removed, remove_err = ok, err end)
    Assert.is_nil(removed)
    Assert.is_true(remove_err ~= nil)
end
settings.logged_in = true
remove_reply = nil
Client:removeFromShelfAsync("e1", function(ok, err) removed, remove_err = ok, err end)
Assert.is_true(removed)
Assert.is_nil(remove_err)
Assert.eq(Json.decode(requests[#requests].body).data[1].pid, "e1")
Assert.eq(Json.decode(requests[#requests].body).data[1].ptype, 2)

local function chapterResult()
    text, terr = nil, nil
    Client.contentAsync("e1", "c1", function(value, err) text, terr = value, err end)
end
local page_count = 0
pages_reply = function()
    page_count = page_count + 1
    if page_count > 1 then return nil, "network timeout" end
    return Json.encode({ h = { c = 0 }, c = { pages = { { svg = cipher } } } })
end
chapterResult()
Assert.is_nil(text)
Assert.eq(terr, "network timeout")

for _idx, body in ipairs({
    { is_end = true, pages = { { svg = cipher }, { svg = "broken" } } },
    { is_end = true },
    { pages = {} },
}) do
    pages_reply = function() return Json.encode({ h = { c = 0 }, c = body }) end
    chapterResult()
    Assert.is_nil(text)
    Assert.eq(terr, "响应无效")
end

page_count = 0
pages_reply = function()
    page_count = page_count + 1
    return Json.encode({ h = { c = 0 }, c = { pages = { { svg = cipher } } } })
end
chapterResult()
Assert.eq(page_count, 40)
Assert.is_nil(text)
Assert.eq(terr, "响应无效")

local Aes = require("crypto.aes")
local Text = require("utils.text")
local SVG_KEY, SVG_IV = "3e4r06tjkpjcevlbslr3d96gdb5ahbmo", "6fd89a1b3a7f48fb"
local function svgCipher(svg)
    return Text.base64Encode(Aes.cbc_encrypt(svg, SVG_KEY, SVG_IV))
end
local blank = svgCipher("<svg></svg>")
Assert.eq(Mapper.pageText(blank), "")
-- 同一基线的字拼成一行。上一行没排满就换段；排满的行和页边续行合成一段。
Assert.eq(Mapper.pageText(svgCipher('<text x="10" y="20">膝</text><text x="40" y="20">盖</text>')), "膝盖")
Assert.eq(Mapper.pageText(svgCipher([[<text x="80" y="20">甲</text>
<text x="30" y="56">乙</text><text x="50" y="56">丙</text><text x="740" y="56">。</text>
<text x="30" y="92">下</text>]])), "甲\n乙丙。下")
Assert.eq(Mapper.pageText(svgCipher('<text x="70" y="20">A</text><text x="740" y="20">c</text><text x="30" y="56">D</text>')), "Ac D")
page_count = 0
pages_reply = function()
    page_count = page_count + 1
    return Json.encode({ h = { c = 0 }, c = {
        is_end = page_count == 2, pages = { { svg = page_count == 1 and blank or cipher } },
    } })
end
chapterResult()
Assert.eq(text, "第一段\n第二段")
Assert.is_nil(terr)
