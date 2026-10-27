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
    local html = '<a href="/book/25866531901067904" style="" class="details-part" data-bookid="25866531901067904" data-v-1>'
        .. '<div class="common-img" data-v-1><div><img src="//bookcover.yuewen.com/a/90.webp" alt="x"></div></div>'
        .. '<div class="common-info"><p class="book-title" data-v-1>来日&amp;有信</p><p class="book-profile" data-v-1>简介</p>'
        .. '<p class="book-module" data-v-1>千山茶客<span class="pipe">·</span>连载中<span class="pipe">·</span>21万字</p></div></a>'
        .. '<a href="/book/2" data-bookid="2" data-v-1><div class="common-img"><img src="//c/2.webp"></div>'
        .. '<div class="common-info"><p class="book-title">乙</p><p class="book-module">丙<span>·</span>完结</p></div></a>'
    local books = Xiaoxiang.rank(html)
    Assert.len(books, 2)
    Assert.eq(books[1].stable_id, "25866531901067904")
    Assert.eq(books[1].title, "来日&有信")
    Assert.eq(books[1].authors, "千山茶客")
    Assert.eq(books[1].cover, "https://bookcover.yuewen.com/a/90.webp")
    Assert.eq(books[2].title, "乙")
    Assert.len(Xiaoxiang.rank("<html></html>"), 0)
end

do
    local function wire(chapter) return { data = { chapterContents = { chapter } } } end
    Assert.eq(Xiaoxiang.content(wire({ chapterPrice = "0", auth = true, chapterContent = "\r\n\227\128\128甲\r\n\227\128\128\r\n\227\128\128乙" })), "甲\n乙")
    local free, kind = Xiaoxiang.content(wire({ chapterPrice = "9", auth = false, chapterContent = "预览" }))
    Assert.is_nil(free)
    Assert.eq(kind, "unpaid")
    Assert.eq(Xiaoxiang.content(wire({ chapterPrice = "9", auth = true, chapterContent = "全文" })), "全文")
    Assert.is_nil((Xiaoxiang.content({ data = {} })))
    local cipher, ckind, chapter = Xiaoxiang.content(wire({ chapterPrice = "20", auth = true, encrypt = true, chapterContent = "9HHP" }))
    Assert.is_nil(cipher)
    Assert.eq(ckind, "encrypted")
    Assert.eq(chapter.chapterContent, "9HHP")

    local rows = { { bookid = "35554414603847007", title = " 书 ", author = "甲", ccid = "35554414603847008", restype = 1 },
        { bookid = "2", title = "乙", author = "丙", ccid = "0" } }
    local books = Xiaoxiang.shelfList(rows)
    Assert.eq(books[1].stable_id, "35554414603847007")
    Assert.eq(books[1].title, "书")
    Assert.eq(books[1].cover, "https://bookcover.yuewen.com/qdbimg/349573/c_35554414603847007/180")
    local progress = Xiaoxiang.progress(rows)
    Assert.eq(progress["35554414603847007"], "35554414603847008")
    Assert.is_nil(progress["2"])
end

do
    local seen = {}
    package.loaded["http.request"] = nil
    package.preload["http.request"] = function()
        return {
            get = function(url, opts, cb)
                seen.url, seen.headers = url, opts.headers
                cb(seen.reply)
                return {}
            end,
            post = function(url, body, opts, cb)
                seen.post_url, seen.body, seen.headers = url, body, opts.headers
                cb(seen.reply)
                return {}
            end,
        }
    end
    package.loaded["source.xiaoxiang.client"] = nil
    local Settings = require("utils.settings")
    local cfg = Settings.getSource("xiaoxiang")
    cfg.cookie = "csrfToken=C1; ywKey=K"
    Settings.saveSource("xiaoxiang", cfg)
    local Client = require("source.xiaoxiang.client")
    require("source.auth").reset()

    seen.reply = '{"code":0,"data":{"isLogin":0}}'
    local err
    Client.shelfRemoveAsync("35554414603847007", function(_wire, e) err = e end)
    Assert.is_true(require("source.auth").expired("xiaoxiang"))
    Assert.is_nil(seen.post_url)

    seen.reply = '{"code":0,"data":{"isLogin":1}}'
    Client.userAsync("a=1", function(info) seen.info = info end)
    Assert.eq(seen.info.isLogin, 1)
    Assert.eq(seen.headers.Cookie, "a=1; csrfToken=moon")
    Assert.matches(seen.url, "_csrfToken=moon")

    local replies = { '{"code":0,"data":{"isLogin":1}}', '{"code":0,"msg":"ok","data":null}' }
    package.loaded["source.auth"].reset()
    seen.reply = nil
    local n = 0
    package.loaded["http.request"] = nil
    package.preload["http.request"] = function()
        return {
            get = function(url, opts, cb) n = n + 1; seen.url = url; cb(replies[1]) return {} end,
            post = function(url, body, opts, cb) seen.post_url, seen.body = url, body; cb(replies[2]) return {} end,
        }
    end
    package.loaded["source.xiaoxiang.client"] = nil
    Client = require("source.xiaoxiang.client")
    local ok
    Client.shelfRemoveAsync("35554414603847007", function(wire) ok = wire ~= nil end)
    Assert.is_true(ok)
    Assert.matches(seen.post_url, "/bookshelf/delete%?_csrfToken=C1")
    Assert.matches(seen.body, '"bookId":"35554414603847007"')

    replies[2] = '{"code":0,"data":{"chapterContents":[{"ccid":35554414603847008,"chapterPrice":"0","auth":true,"chapterContent":"甲"}]}}'
    local text
    Client.contentAsync("35554414603847007", "35554414603847008", function(t) text = t end)
    Assert.eq(text, "甲")
    Assert.matches(seen.body, '"ccids":%["35554414603847008"%]')
    cfg.cookie = nil
    Settings.saveSource("xiaoxiang", cfg)
    package.loaded["source.xiaoxiang.client"] = nil
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
    Assert.matches(err, "扫码登录")
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
    -- login_res(2){ status 1, web_data(4){ token(1) } }
    local login = QRLogin.fields("\8\1\34\4\10\2tk")
    Assert.eq(login[1], 1)
    Assert.eq(QRLogin.fields(login[4])[1], "tk")
end

do
    local seen
    package.loaded["http.request"] = nil
    package.preload["http.request"] = function()
        return { get = function(_url, opts, cb) seen = opts.headers; cb('{"code":200,"data":{}}') return {} end }
    end
    package.loaded["source.changpei.client"] = nil
    require("source.changpei.client").userAsync("PHPSESSID=a; moon_token=TK", function() end)
    Assert.eq(seen.token, "TK")
    Assert.eq(seen.Cookie, "PHPSESSID=a")
end


-- token 过期（9996）：用 refresh_token 换新 token 写回 Cookie 再重发；换不到才算登录失效
do
    local grpc_status, renew_calls, tokens = "0", 0, {}
    package.loaded["http.request"] = nil
    package.preload["http.request"] = function()
        return {
            header = function(res, name) return res and res[name] end,
            get = function(_url, opts, cb)
                tokens[#tokens + 1] = opts.headers.token
                if opts.headers.token == "OLD" then cb('{"code":9996,"msg":"请先登录"}') else cb('{"code":200,"data":{}}') end
                return {}
            end,
            post = function(url, body, opts, cb)
                renew_calls = renew_calls + 1
                Assert.matches(url, "get_token")
                Assert.eq(body, "\0\0\0\0\4\42\2RF")
                Assert.eq(opts.headers.imei, "dev")
                cb("\0\0\0\0\6\26\4NEW1", nil, { ["grpc-status"] = grpc_status })
                return {}
            end,
        }
    end
    package.loaded["source.changpei.client"] = nil
    local Client = require("source.changpei.client")
    local Auth = require("source.auth")
    local settings = require("utils.settings")
    settings.saveSource("changpei", { cookie = "PHPSESSID=a; _c_n_=dev; moon_token=OLD; moon_refresh=RF" })
    Auth.reset()

    local wire
    Client.historyAsync(function(w) wire = w end)
    Assert.not_nil(wire)
    Assert.eq(renew_calls, 1)
    Assert.eq(tokens[#tokens], "NEW1")
    Assert.matches(settings.getSource("changpei").cookie, "moon_token=NEW1")
    Assert.matches(settings.getSource("changpei").cookie, "moon_refresh=RF")
    Assert.is_false(Auth.expired("changpei"))

    settings.saveSource("changpei", { cookie = "PHPSESSID=a; _c_n_=dev; moon_token=OLD; moon_refresh=RF" })
    grpc_status = "16"
    local failed
    Client.historyAsync(function(w, err) failed = { w, err } end)
    Assert.is_nil(failed[1])
    Assert.eq(failed[2], "请先登录")
    Assert.is_true(Auth.expired("changpei"))

    settings.saveSource("changpei", { cookie = "PHPSESSID=a; _c_n_=dev; moon_token=OLD" })
    Auth.reset()
    renew_calls = 0
    Client.historyAsync(function() end)
    Assert.eq(renew_calls, 0, "没有 refresh_token 不请求")
    Assert.is_true(Auth.expired("changpei"))
    settings.saveSource("changpei", {})
    Auth.reset()
    package.preload["http.request"] = nil
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

-- 长佩：分页没有页数上限，超过 50 页照样翻到空页
do
    local pages = {}
    package.loaded["http.request"] = nil
    package.preload["http.request"] = function()
        return {
            get = function(url, _opts, cb)
                if url:find("system/init", 1, true) then
                    cb('{"code":200,"data":{"timestamp":1792556196}}')
                else
                    local n = tonumber(url:match("page=(%d+)"))
                    pages[#pages + 1] = n
                    cb(n > 60 and '{"code":200,"data":{"list":[]}}'
                        or ('{"code":200,"data":{"list":[{"type":"novel","id":%d}]}}'):format(n))
                end
                return {}
            end,
            post = function(_url, _body, _opts, cb) cb('{"code":200,"data":[]}') return {} end,
        }
    end
    package.loaded["source.changpei.client"] = nil
    local Deep = require("source.changpei.client")
    local rows, err
    Deep.shelfAsync(function(r, e) rows, err = r, e end)
    Assert.is_nil(err)
    Assert.len(rows, 60)
    Assert.len(pages, 61)
    package.preload["http.request"] = nil
end

-- 潇湘：分页没有页数上限，pageCount 多少就翻多少页
do
    local pages = 0
    package.loaded["http.request"] = nil
    package.preload["http.request"] = function()
        return {
            get = function(url, _opts, cb)
                if url:find("/bookshelf/pc/page", 1, true) then
                    pages = pages + 1
                    cb('{"code":0,"data":{"pageCount":60,"data":[{"restype":1,"groupId":-100,"bookid":"1","title":"甲"}]}}')
                else
                    cb('{"code":0,"data":{"isLogin":1}}')
                end
                return {}
            end,
            post = function(_url, _body, _opts, cb) cb('{"code":0,"data":{"isLogin":1}}') return {} end,
        }
    end
    local Settings = require("utils.settings")
    local cfg = Settings.getSource("xiaoxiang")
    cfg.cookie = "csrfToken=C1; ywKey=K"
    Settings.saveSource("xiaoxiang", cfg)
    package.loaded["source.xiaoxiang.client"] = nil
    local Deep = require("source.xiaoxiang.client")
    require("source.auth").reset()
    local rows, err
    Deep.shelfAsync(function(r, e) rows, err = r, e end)
    Assert.is_nil(err)
    Assert.len(rows, 60)
    Assert.eq(pages, 60)
    cfg.cookie = nil
    Settings.saveSource("xiaoxiang", cfg)
    package.loaded["source.xiaoxiang.client"] = nil
    package.preload["http.request"] = nil
end
