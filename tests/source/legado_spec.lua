--[[--
阅读（Legado）Web 服务：地址归一、回包解码、请求形状与映射离线用例。

@module tests.source.legado_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local JSONStub = require("support.json_stub")

package.preload["json"] = function()
    return { decode = JSONStub.decode, encode = JSONStub.encode }
end

local cfg = { server_address = "192.168.1.8:1122/" }
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end }
end

local requests, replies = {}, {}
package.preload["http.request"] = function()
    return {
        get = function(url, opts, cb)
            requests[#requests + 1] = { method = "GET", url = url, opts = opts }
            cb(table.remove(replies, 1))
            return { cancel = function() end }
        end,
        post = function(url, body, opts, cb)
            requests[#requests + 1] = { method = "POST", url = url, body = body, opts = opts }
            cb(table.remove(replies, 1))
            return { cancel = function() end }
        end,
    }
end

package.loaded["source.legado.client"] = nil
package.loaded["source.legado.mapper"] = nil
local Client = require("source.legado.client")
local Mapper = require("source.legado.mapper")

-- 地址缺协议头补 http、去尾斜杠；没配置为 nil。
do
    Assert.eq(Client.base(), "http://192.168.1.8:1122")
    cfg.server_address = "https://legado.lan:1122"
    Assert.eq(Client.base(), "https://legado.lan:1122")
    cfg.server_address = ""
    Assert.is_nil(Client.base())
    cfg.server_address = "http://h:1122"
end

-- 书架：GET /getBookshelf，isSuccess=false 带出 errorMsg。
do
    replies = { '{"isSuccess":true,"errorMsg":"","data":[{"bookUrl":"u1"}]}' }
    local rows, err
    Client.shelfAsync(function(v, e) rows, err = v, e end)
    Assert.is_nil(err)
    Assert.len(rows, 1)
    Assert.matches(requests[1].url, "^http://h:1122/getBookshelf%?refresh=0$")

    replies = { '{"isSuccess":false,"errorMsg":"没有权限","data":null}' }
    rows, err = nil, nil
    Client.shelfAsync(function(v, e) rows, err = v, e end)
    Assert.is_nil(rows)
    Assert.eq(err, "没有权限")

    replies = { "<html>" }
    Client.shelfAsync(function(v, e) rows, err = v, e end)
    Assert.eq(err, "响应无效")
end

-- 正文：index 0 基、url 编码；空正文报错。
do
    requests = {}
    replies = { '{"isSuccess":true,"data":"第一段\\n第二段"}' }
    local text
    Client.contentAsync("https://a.b/c?d=1", 3, nil, function(v) text = v end)
    Assert.eq(text, "第一段\n第二段")
    Assert.matches(requests[1].url, "/getBookContent%?")
    Assert.matches(requests[1].url, "index=3")
    Assert.matches(requests[1].url, "url=https%%3A%%2F%%2Fa%.b%%2Fc%%3Fd%%3D1")

    replies = { '{"isSuccess":true,"data":""}' }
    local err
    Client.contentAsync("u", 0, nil, function(_, e) err = e end)
    Assert.eq(err, "阅读章节内容为空 #1")
end

-- 进度上报：JSON 体带 0 基章序号。
do
    requests = {}
    replies = { '{"isSuccess":true,"data":""}' }
    local ok
    Client.saveProgressAsync({ name = "书", author = "作者", bookUrl = "u1" },
        { index = 4, title = "第5章", offset = 12 }, function(v) ok = v end)
    Assert.is_true(ok)
    Assert.eq(requests[1].method, "POST")
    Assert.matches(requests[1].url, "/saveBookProgress$")
    Assert.eq(requests[1].opts.content_type, "application/json")
    Assert.matches(requests[1].body, '"durChapterIndex":4')
    Assert.matches(requests[1].body, '"url":"u1"')
end

-- 正文夹 <img>：真图留成标签、svg 懒加载占位丢弃、src 尾部请求头剥掉，其余文字照旧转义
do
    local html = Mapper.chapterHtml("章", 'a<b>\n<img src="data:image/svg+xml;base64,PHN2Zy8+">\n'
        .. '<img src="http://h/x.jpg?a=1&amp;b=2,{&quot;h&quot;:1}" alt="x">', function(src) return src end)
    Assert.eq(html, '<h1>章</h1>\n<p>a&lt;b&gt;</p>\n<p><img src="http://h/x.jpg?a=1&amp;b=2"/></p>')
end

-- 映射：bookUrl 是身份，封面走 /cover 代理，自定义封面优先；没有 bookUrl 的行丢弃。
do
    local books = Mapper.shelfList(function(path) return "http://h:1122/cover?path=" .. require("utils.text").urlEncode(path) end, {
        { bookUrl = "u1", name = "书", author = "作者", coverUrl = "http://img/a.jpg", kind = "玄幻" },
        { bookUrl = "u2", name = "二", customCoverUrl = "/local/b.jpg", coverUrl = "x" },
        { name = "无地址" },
    })
    Assert.len(books, 2)
    Assert.eq(books[1].stable_id, "u1")
    Assert.eq(books[1].cover, "http://h:1122/cover?path=http%3A%2F%2Fimg%2Fa.jpg")
    Assert.eq(books[1].category, "玄幻")
    Assert.eq(books[2].cover, "http://h:1122/cover?path=%2Flocal%2Fb.jpg")
end

-- 阅读位置与目录：durChapterIndex 0 基；没读过为 nil；目录 uid 是 0 基序号。
do
    local pos = Mapper.readPos({ durChapterIndex = 2, durChapterPos = 30, durChapterTitle = "第3章", durChapterTime = 1 })
    Assert.eq(pos.index, 2)
    Assert.eq(pos.offset, 30)
    Assert.eq(pos.title, "第3章")
    Assert.is_nil(Mapper.readPos({ durChapterIndex = 0, durChapterTime = 0 }))
    Assert.is_nil(Mapper.readPos(nil))
    local toc = Mapper.toc({ { index = 0, title = "序" }, { index = 1, title = "一" } })
    Assert.eq(toc[2].idx, 2)
    Assert.eq(toc[2].uid, "1")
end

-- reader3：配了账号密码先 POST /login 取 accessToken，请求带上；令牌过期（NEED_LOGIN）重登一次。
do
    cfg.server_address, cfg.username, cfg.password = "http://h:8080/reader3", "u", "p"
    requests = {}
    replies = {
        '{"isSuccess":true,"data":{"accessToken":"T1"}}',
        '{"isSuccess":true,"data":[{"bookUrl":"u1"}]}',
        '{"isSuccess":false,"errorMsg":"NEED_LOGIN","data":"NEED_LOGIN"}',
        '{"isSuccess":true,"data":{"accessToken":"T2"}}',
        '{"isSuccess":true,"data":[]}',
    }
    local rows
    Client.shelfAsync(function(v) rows = v end)
    Assert.len(rows, 1)
    Assert.matches(requests[1].url, "^http://h:8080/reader3/login$")
    Assert.matches(requests[1].body, '"username":"u"')
    Assert.matches(requests[2].url, "/reader3/getBookshelf%?.*accessToken=T1")
    Assert.matches(Client.coverUrl("x"), "accessToken=T1")

    Client.shelfAsync(function(v) rows = v end)
    Assert.len(rows, 0)
    Assert.matches(requests[5].url, "accessToken=T2")

    cfg.username, cfg.password = nil, nil
end

-- reader3：相对图片 / 封面补成服务根 + accessToken；章节与正文走 POST JSON。
do
    cfg.server_address, cfg.username, cfg.password = "http://h:8080/reader3", "u", "p"
    Assert.eq(Client.mode(), "reader3")
    Assert.eq(Client.imageUrl("__API_ROOT__/book-assets/a b.png"), "http://h:8080/book-assets/a b.png?accessToken=T2")
    Assert.eq(Client.imageUrl("https://x/y.jpg"), "https://x/y.jpg")
    requests = {}
    replies = { '{"isSuccess":true,"data":[{"index":0,"title":"序"}]}' }
    local rows
    Client.chaptersAsync("bu", nil, function(v) rows = v end)
    Assert.len(rows, 1)
    Assert.eq(requests[1].method, "POST")
    Assert.matches(requests[1].url, "/reader3/getChapterList%?accessToken=T2$")
    Assert.matches(requests[1].body, '"url":"bu"')

    -- 重登仍失败：标记登录失效，给人看的中文说明（放在复用 T2 的用例之后）。
    local Auth = require("source.auth")
    Auth.reset()
    requests, replies = {}, {
        '{"isSuccess":false,"errorMsg":"NEED_LOGIN","data":"NEED_LOGIN"}',
        '{"isSuccess":false,"errorMsg":"bad password"}',
    }
    local err
    Client.shelfAsync(function(_v, e) err = e end)
    Assert.eq(err, "阅读服务器登录已失效，请检查账号密码")
    Assert.is_true(Auth.expired("legado"))
    Auth.reset()

    cfg.username, cfg.password = nil, nil
end

-- 轻阅读：/api/N 后缀；表单 POST，登录带 model=web，目录 / 正文带书源，正文回包是 { text }。
do
    cfg.server_address, cfg.username, cfg.password = "http://h:1122/api/5", "u", "p"
    Assert.eq(Client.mode(), "qread")
    requests = {}
    replies = {
        '{"isSuccess":true,"data":{"accessToken":"Q1"}}',
        '{"isSuccess":true,"data":[{"bookUrl":"u1","origin":"src1"}]}',
        '{"isSuccess":true,"data":{"rules":{},"text":"正文"}}',
        '{"isSuccess":true,"data":""}',
    }
    local rows, text, ok
    Client.shelfAsync(function(v) rows = v end)
    Assert.eq(rows[1].origin, "src1")
    Assert.eq(requests[1].opts.content_type, "application/x-www-form-urlencoded")
    Assert.matches(requests[1].body, "model=web")
    Assert.matches(requests[2].url, "/api/5/getBookshelf%?accessToken=Q1$")
    Assert.eq(requests[2].body, "version=3.2.1")

    Client.contentAsync("u1", 2, "src1", function(v) text = v end)
    Assert.eq(text, "正文")
    Assert.matches(requests[3].body, "bookSourceUrl=src1")
    Assert.matches(requests[3].body, "index=2")

    Client.saveProgressAsync({ bookUrl = "u1" }, { index = 2, title = "T", offset = 5 }, function(v) ok = v end)
    Assert.is_true(ok)
    Assert.eq(requests[4].body, "index=2&pos=5&title=T&url=u1")

    Assert.eq(Client.imageUrl("baseurl/proxypng?url=a"), "http://h:1122/api/5/proxypng?url=a&accessToken=Q1")
    Assert.eq(Client.coverUrl("/c.jpg"), "http://h:1122/api/5/proxypng?url=%2Fc.jpg&accessToken=Q1")
    cfg.server_address, cfg.username, cfg.password = "http://h:1122", nil, nil
end
