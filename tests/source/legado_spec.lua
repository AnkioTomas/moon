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

-- 校验新库使用显式配置：地址与登录凭据不落盘，也不替换当前配置。
do
    requests = {}
    replies = {
        '{"isSuccess":true,"data":{"accessToken":"probe-token"}}',
        '{"isSuccess":true,"data":[{"bookUrl":"probe-book"}]}',
    }
    local rows, err
    Client.shelfAsync(function(value, reason) rows, err = value, reason end, {
        server_address = "https://probe.test/reader3", username = "probe-user", password = "probe-password",
    })
    Assert.is_nil(err)
    Assert.eq(rows[1].bookUrl, "probe-book")
    Assert.matches(requests[1].url, "^https://probe.test/reader3/login$")
    Assert.matches(requests[1].body, '"username":"probe%-user"')
    Assert.matches(requests[2].url, "^https://probe.test/reader3/getBookshelf%?")
    Assert.matches(requests[2].url, "accessToken=probe%-token")
    Assert.eq(Client.base(), "http://h:1122", "探测新库时当前客户端仍读旧库配置")
    requests, replies = {}, { '{"isSuccess":true,"data":[]}' }
    Client.shelfAsync(function() end)
    Assert.matches(requests[1].url, "^http://h:1122/getBookshelf%?")
    Assert.is_nil(requests[1].url:find("probe%-token"), "探测令牌不能污染旧库请求")
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
    local resource = "http://h:8080/proxy/book-assets/Text/chapter.xhtml?accessToken=T2"
    Assert.eq(Client.imageUrl("../Images/cover%20one.png", resource),
        "http://h:8080/proxy/book-assets/Images/cover%20one.png?accessToken=T2")
    Assert.eq(Client.imageUrl("../Images/cover.png?v=1#cover", resource),
        "http://h:8080/proxy/book-assets/Images/cover.png?v=1&accessToken=T2#cover")
    Assert.eq(Client.imageUrl("//cdn.example/cover.png", resource), "http://cdn.example/cover.png")
    Assert.eq(Client.imageUrl("data:image/png;base64,AAAA", resource), "data:image/png;base64,AAAA")
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
    Assert.matches(err, "阅读服务地址")
    Assert.is_true(Auth.expired("legado"))
    Auth.reset()

    cfg.username, cfg.password = nil, nil
end

-- EPUB 正文不靠 <p> 判空；保留实体文本、转换 SVG、规范化图片属性及 URL。
do
    local base = "http://h/book-assets/Text/chapter.xhtml"
    local function imageUrl(src, document_url) return require("utils.text").absoluteUrl(document_url, src) end
    local html = Mapper.assetHtml("章", '<?xml version="1.0"?><html><head><title>壳</title></head>'
        .. '<body><style>p{color:red}</style><script>alert(1)</script><div>&amp;</div></body></html>', base, imageUrl)
    Assert.eq(html, "<h1>章</h1>\n<div>&amp;</div>")
    Assert.is_nil(Mapper.assetHtml("只有标题", "<body><div>&nbsp; &#160;</div></body>", base, imageUrl))
    html = Mapper.assetHtml("图", '<body><svg><image xlink:href="../Images/封 面%20图.png"/></svg>'
        .. "<img src = '../Images/a.png?a=1&amp;b=2'/></body>", base, imageUrl)
    Assert.matches(html, 'src="http://h/book%-assets/Images/%%E5%%B0%%81%%20%%E9%%9D%%A2%%20%%E5%%9B%%BE%.png"')
    Assert.matches(html, 'src="http://h/book%-assets/Images/a%.png%?a=1&amp;b=2"')
    Assert.is_nil(html:find("<svg", 1, true))
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

-- 地址是连接位置，不是书籍身份：换 IP / 清空后重连保留进度，换账号仍走清库边界。
do
    local Themed = require("support.theme_stubs")
    local ProgressDB = require("book.progress_db")
    local stable_id = "legado-address-progress-spec"
    assert(ProgressDB.upsert("legado", stable_id, { fraction = 0.63, chapter_idx = 8 }))
    assert(ProgressDB.setDecisionPending("legado", stable_id, true))
    Themed.install()
    package.loaded["ui.themes.widgets.row"] = { widget = function(opts) return opts end }
    cfg = { server_address = "http://old/reader3", username = "old-user", password = "old-password" }
    local saved, reloaded, cleaned, aborted, cleanup_ok = 0, 0, 0, 0, true
    package.loaded["utils.settings"] = {
        getSource = function() return cfg end,
        saveSource = function() saved = saved + 1 end,
    }
    package.loaded["source.registry"] = { reload = function() reloaded = reloaded + 1 end }
    package.loaded["source.logout"] = {
        row = require("source.logout").row,
        abort = function(id)
            Assert.eq(id, "legado")
            aborted = aborted + 1
        end,
        replaceLibrary = function(_id, commit)
            cleaned = cleaned + 1
            if not cleanup_ok then return false end
            commit()
            require("source.registry").reload()
            return true
        end,
    }
    package.loaded["ui/network/manager"] = { runWhenConnected = function(_self, fn) fn() end }
    local pending, candidate
    local shelf = Client.shelfAsync
    Client.shelfAsync = function(cb, settings)
        pending, candidate = cb, settings
        return { cancel = function() end }
    end
    local Setting = require("source.legado.setting")
    Setting.rows()[1](300).callback()
    Themed.last("input").callback("http://new/reader3", "old-user", "old-password")
    Assert.eq(candidate.server_address, "http://new/reader3")
    Assert.eq(candidate.username, "old-user")
    Assert.eq(cfg.server_address, "http://old/reader3", "校验期间当前源仍握着旧库")
    Assert.eq(saved, 0)
    pending(nil, "network failed")
    Assert.eq(cfg.server_address, "http://old/reader3")
    Assert.eq(saved, 0)
    Assert.eq(reloaded, 0)
    Assert.eq(Themed.last("toast").text, "network failed")

    Setting.rows()[1](300).callback()
    Themed.last("input").callback("http://new/reader3", "old-user", "old-password")
    pending({ { bookUrl = stable_id } })
    local progress = ProgressDB.get("legado", stable_id)
    Assert.is_true(progress ~= nil, "更换地址不能删除阅读进度")
    Assert.eq(progress.chapter_idx, 8)
    Assert.eq(progress.fraction, 0.63)
    Assert.eq(progress.sync_status, 0)
    Assert.eq(progress.decision_pending, 1)
    Assert.eq(cfg.server_address, "http://new/reader3")
    Assert.eq(saved, 1)
    Assert.eq(reloaded, 1)
    Assert.eq(cleaned, 0)
    Assert.eq(aborted, 1)

    -- 先清空旧地址再填新地址也不是登出，不能在这一步清掉数据或账号身份。
    Setting.rows()[1](300).callback()
    Themed.last("input").callback("", "", "")
    Assert.is_nil(cfg.server_address)
    Assert.eq(cfg.username, "old-user")
    Assert.eq(cfg.password, "old-password")
    Assert.eq(ProgressDB.get("legado", stable_id).chapter_idx, 8)
    Assert.eq(cleaned, 0)
    Assert.eq(aborted, 2)

    -- 局域网扫描同样走保存地址流程；重新找到服务后继续用原账号与进度。
    package.loaded["source.legado.scan"] = {
        find = function(cb)
            cb({ "http://lan/reader3" })
            return { cancel = function() end }
        end,
    }
    Setting.rows()[2](300).callback()
    Assert.eq(candidate.username, "old-user")
    pending({ { bookUrl = stable_id } })
    Assert.eq(cfg.server_address, "http://lan/reader3")
    Assert.eq(ProgressDB.get("legado", stable_id).chapter_idx, 8)
    Assert.eq(cleaned, 0)

    -- 换账号只准备同步；准备失败不能提交新账号，也不能删除进度。
    saved, reloaded, cleanup_ok = 0, 0, false
    Setting.rows()[1](300).callback()
    Themed.last("input").callback("http://new/reader3", "new-user", "new-password")
    pending({ { bookUrl = "new-book" } })
    Assert.eq(cfg.server_address, "http://lan/reader3")
    Assert.eq(cfg.username, "old-user")
    Assert.eq(saved, 0)
    Assert.eq(reloaded, 0)
    Assert.eq(Themed.last("toast").text, "准备本地同步失败")
    Assert.eq(ProgressDB.get("legado", stable_id).chapter_idx, 8)

    cleanup_ok = true
    Setting.rows()[1](300).callback()
    Themed.last("input").callback("http://new/reader3", "new-user", "new-password")
    pending({ { bookUrl = "new-book" } })
    Assert.eq(cfg.server_address, "http://new/reader3")
    Assert.eq(cfg.username, "new-user")
    Assert.eq(saved, 1)
    Assert.eq(reloaded, 1)
    Assert.eq(ProgressDB.get("legado", stable_id).chapter_idx, 8)
    Assert.eq(ProgressDB.get("legado", stable_id).fraction, 0.63)
    Assert.eq(ProgressDB.get("legado", stable_id).decision_pending, 1)
    Client.shelfAsync = shelf
end
