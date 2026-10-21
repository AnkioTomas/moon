--[[--
长佩 / 潇湘数据映射离线用例：搜索、目录、正文解密与未购识别。

@module tests.source.changpei_xiaoxiang_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

package.preload["json"] = function() return require("support.json_stub") end
package.loaded["source.xiaoxiang.mapper"] = nil

local Aes = require("crypto.aes")
local Assert = require("support.assert")
local Text = require("utils.text")

local Changpei = require("source.changpei.mapper")
local Xiaoxiang = require("source.xiaoxiang.mapper")

local KEY, IV = "u0LRrbu$Enm84koA", "$h$b3!iGzsYnnshj"
local function seal(plain) return Text.base64Encode(Aes.cbc_encrypt(plain, KEY, IV)) end

do
    local books = Changpei.search({ data = { list = {
        { novel_id = 7, novel_name = " 书 ", novel_author = "甲", novel_desc = "简介", novel_type = "架空",
            novel_cover = "https://x/a.jpg?x-oss-process=style/small", novel_wordnumber = 1000 },
        { novel_id = 8, novel_name = "乙", novel_author = "丙", novel_desc = "",
            novel_cover = "https://x/nocover.jpg?x", novel_type = "" },
    } } })
    Assert.len(books, 2)
    Assert.eq(books[1].stable_id, "7")
    Assert.eq(books[1].title, "书")
    Assert.eq(books[1].cover, "https://x/a.jpg")
    Assert.is_nil(books[2].cover)
    Assert.is_nil(books[2].category)
end

do
    local toc = Changpei.toc({ data = { list = {
        { type = "item", id = 1, name = "一", price = 0 },
        { type = "item", id = 2, name = "二" },
        { type = "item", id = 3, name = "三", price = 5 },
        { type = "more" },
    } } })
    Assert.len(toc, 3)
    Assert.eq(toc[3].uid, "3")
    Assert.is_nil(toc[2].vip)
    Assert.is_true(toc[3].vip)
    Assert.eq(toc[1].toc_version, Changpei.TOC_VERSION)
end

do
    local text = Changpei.content({ data = { chapterInfo = { chapterPrice = 0, content = seal("　　第一段\r\n\r\n　　第二段\n") } } })
    Assert.eq(text, "　　第一段\n　　第二段")
    local _t, _e, kind = Changpei.content({ data = { chapterInfo = { chapterPrice = 9, isSub = false, content = "" } } })
    Assert.eq(kind, "unpaid")
    local _t0, e0, kind0 = Changpei.content({ code = 200, msg = "操作成功",
        data = { chapterInfo = { chapterPrice = "25", isSub = "0", content = "" } } })
    Assert.eq(kind0, "unpaid")
    Assert.is_nil(e0)
    local bought = Changpei.content({ data = { chapterInfo = { chapterPrice = 9, isSub = true, content = seal("正文") } } })
    Assert.eq(bought, "正文")
    local _t2, _e2, verify = Changpei.content({ data = { check = 2, chapterInfo = { chapterPrice = 0, content = seal("乱码") } } })
    Assert.eq(verify, "verify")
    local none, err = Changpei.content({ msg = "访问异常" })
    Assert.is_nil(none)
    Assert.eq(err, "访问异常")
end

do
    local html = '<ul><li style="padding-bottom:15px;"><img src="//c.example/1.jpg"><h4><a href="/book/123" target="_blank">书名</a>'
        .. '<span class="subtitle"><a><i></i>某作者</a><a></a><span>玄幻</span></span></h4>'
        .. '<p class="detail">简介&amp;内容</p></li></ul>'
    local books = Xiaoxiang.search(html)
    Assert.len(books, 1)
    Assert.eq(books[1].stable_id, "123")
    Assert.eq(books[1].authors, "某作者")
    Assert.eq(books[1].cover, "https://c.example/1.jpg")
    Assert.eq(books[1].intro, "简介&内容")
end

do
    local html = 'x"chapters":[{"type":0,"isVip":-1,"title":"正文"},'
        .. '{"type":1,"ccid":"11","title":"第1章","price":0},'
        .. '{"type":1,"ccid":"12","title":"第2章","price":10}],"other":{"a":1}'
    local toc = Xiaoxiang.toc(html)
    Assert.len(toc, 2)
    Assert.eq(toc[2].uid, "12")
    Assert.is_nil(toc[1].vip)
    Assert.is_true(toc[2].vip)
    Assert.len(Xiaoxiang.toc("<html></html>"), 0)
end

do
    Assert.eq(Xiaoxiang.content('<main id="content" class="a"><p>甲&amp;乙</p><p> </p><p>丙</p></main>'), "甲&乙\n丙")
    local _t, kind = Xiaoxiang.content('<main id="content" class="a lock-mask"><p>预览</p></main>')
    Assert.eq(kind, "unpaid")
    Assert.is_nil((Xiaoxiang.content("<html></html>")))
end

do
    local CpSetting = require("source.changpei.setting")
    Assert.eq(CpSetting.parseCookie("Cookie: PHPSESSID=x; _c_n_=y\n"), "PHPSESSID=x; _c_n_=y")
    Assert.eq(CpSetting.parseCookie("  "), "")

    local XxSetting = require("source.xiaoxiang.setting")
    Assert.eq(XxSetting.parseCookie("Cookie: a=1; b=2\n"), "a=1; b=2")
    Assert.eq(XxSetting.parseCookie("乱七八糟"), "")
end

do
    local seen, reply = {}, '{"code":9996,"msg":"请先登录","data":[]}'
    package.loaded["http.request"] = nil
    package.preload["http.request"] = function()
        return { get = function(_url, opts, cb) seen.headers = opts.headers; cb(reply) return {} end }
    end
    package.loaded["source.changpei.client"] = nil
    local Settings = require("utils.settings")
    local cfg = Settings.getSource("changpei")
    cfg.cookie = "PHPSESSID=T1"
    Settings.saveSource("changpei", cfg)
    local Client = require("source.changpei.client")
    local Auth = require("source.auth")
    Auth.reset()
    local err
    Client.chaptersAsync("1", function(_wire, e) err = e end)
    Assert.eq(seen.headers.Cookie, "PHPSESSID=T1")
    Assert.eq(seen.headers.Client, "pc")
    Assert.eq(err, "请先登录")
    Assert.is_true(Auth.expired("changpei"))
    cfg.cookie = nil
    Settings.saveSource("changpei", cfg)
    Auth.reset()
    Client.searchAsync("x", function() end)
    Assert.is_nil(seen.headers.Cookie)
    Assert.is_true(not Auth.expired("changpei"))
    package.preload["http.request"] = nil
end

-- 书架 / 阅读历史 / 签名 POST
do
    local Cp = require("source.changpei.mapper")
    local books = Cp.shelfList({ { id = 7, name = " 书 ", author = "甲", cover = "https://x/a.jpg?x-oss=1" } })
    Assert.eq(books[1].stable_id, "7")
    Assert.eq(books[1].title, "书")
    Assert.eq(books[1].cover, "https://x/a.jpg")
    local hist = Cp.history({ data = { list = { { list = {
        { novel_id = 9, latest_read_cid = 123 }, { novel_id = 8, latest_read_cid = 0 },
    } } } } })
    Assert.eq(hist["9"], "123")
    Assert.is_nil(hist["8"])

    local pages, posted = {}, {}
    package.loaded["http.request"] = nil
    package.preload["http.request"] = function()
        return {
            get = function(url, _opts, cb)
                if url:find("system/init", 1, true) then
                    cb('{"code":200,"data":{"timestamp":1792556196}}')
                else
                    local n = tonumber(url:match("page=(%d+)"))
                    pages[#pages + 1] = n
                    cb(n == 1 and '{"code":200,"data":{"list":[{"type":"novel","id":5},{"type":"shelf","id":1}]}}'
                        or '{"code":200,"data":{"list":[]}}')
                end
                return {}
            end,
            post = function(url, body, opts, cb)
                posted = { url = url, body = body, headers = opts.headers }
                cb('{"code":200,"data":[]}')
                return {}
            end,
        }
    end
    package.loaded["source.changpei.client"] = nil
    local Client = require("source.changpei.client")
    local rows
    Client.shelfAsync(function(r) rows = r end)
    Assert.len(pages, 2)
    Assert.eq(pages[2], 2)
    Assert.len(rows, 1)
    local ok
    Client.shelfAddAsync("5", function(wire) ok = wire ~= nil end)
    Assert.is_true(ok)
    Assert.eq(posted.body, '{"module":"novel","cid":5,"status":1}')
    Assert.eq(posted.headers.Timestamp, "1792556196")
    Client.shelfAddAsync("2125021", function() end)
    Assert.eq(posted.headers["Rand-Str"], "4d427f47b607d1d06ecd0d3a11fbcf7d")
    Client.shelfRemoveAsync("5", function() end)
    Assert.eq(posted.body, '{"module":"novel","cid":5,"status":0}')
    package.preload["http.request"] = nil
end

-- 扫码登录：gRPC-web 帧与 protobuf 顶层字段
local QRLogin = require("source.changpei.qrlogin")

do
    Assert.eq(QRLogin.frame("Login"), "\0\0\0\0\7\10\5Login")
end

do
    local token = ("a"):rep(32)
    local fields = QRLogin.decode("\0\0\0\0\35\10\32" .. token .. "\16\200\1")
    Assert.eq(fields[1], token)
    Assert.eq(fields[2], 200)
    local poll = QRLogin.decode("\0\0\0\0\36\8\4\26\32" .. token)
    Assert.eq(poll[1], 4)
    Assert.eq(poll[3], token)
    Assert.eq(next(QRLogin.decode("")), nil)
end


-- 书城榜单：rankingNav → 两行 chip，节点取榜单 + 子榜
do
    package.loaded["http.request"] = nil
    package.preload["http.request"] = function()
        return { get = function(url, _opts, cb)
            if url:find("rankingNav", 1, true) then
                cb('{"code":200,"data":[{"name":"畅销榜","rank_id":1,"type":[{"name":"昨日","value":1},{"name":"30天","value":3}]},'
                    .. '{"name":"精品榜","rank_id":15,"url":"event/x","type":[]},'
                    .. '{"name":"人气榜","rank_id":3,"type":[{"name":"7天","value":2}]}]}')
            else
                cb('{"code":200,"data":{"count":1,"list":[{"novel_id":9,"novel_name":"榜书","novel_author":"甲"}]}}')
            end
            return {}
        end }
    end
    package.loaded["source.changpei.client"] = nil
    package.loaded["source.changpei"] = nil
    local source = require("source.changpei").new()
    local res
    source:browseAsync({ node = "1:3" }, function(r) res = r end)
    Assert.eq(res.data[1].stable_id, "9")
    Assert.len(res.groups[1].chips, 2)
    Assert.eq(res.groups[1].active, "1:1")
    Assert.eq(res.groups[2].active, "1:3")
    package.preload["http.request"] = nil
end
