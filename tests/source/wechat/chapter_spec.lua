--[[--
微信章节正文的 range 坐标原文与 reader 状态回归测试。

@module tests.source.wechat.chapter_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")

package.preload["json"] = function()
    return {
        encode = require("support.json_stub").encode,
        decode = require("support.json_stub").decode,
    }
end

local queries = {}
local app_err = nil
local trial = false
local bom = false
local txt_zip = false
local zip_text_missing = false
local info_requests = {}
local app_response

package.preload["workers.job"] = function()
    return {
        run = function(fn, opts)
            opts.on_done(fn())
            return { cancel = function() end }
        end,
    }
end

package.preload["http.request"] = function()
    return {
        header = function() return "encrypt-key" end,
        ok = function(code) return type(code) == "number" and code >= 200 and code < 300 end,
    }
end

package.preload["source.wechat.eink"] = function()
    return {
        credentials = function() return { vid = "42" } end,
        callAsync = function(method, path, opts, cb)
            if path == "/book/info" then
                info_requests[#info_requests + 1] = opts.query
            else
                queries[#queries + 1] = opts.query
            end
            if app_response then return app_response(method, path, opts, cb) end
            if path == "/book/info" then
                cb({ book = { version = 7 } })
                return { cancel = function() end }
            end
            if app_err then
                cb(nil, app_err)
            else
                local body
                if opts.query.bookType == "txt" and not txt_zip then
                    body = string.rep("\0", 257) .. "ustar"
                else
                    body = "PK"
                end
                cb({ body = body, code = 200 })
            end
            return { cancel = function() end }
        end,
    }
end

package.preload["source.wechat.auth"] = function()
    return {
        hasSession = function() return true end,
        webPostAsync = function() error("chapter download must not fall back to the web reader") end,
        webGetAsync = function() error("chapter download must not fall back to the web reader") end,
    }
end

local FULL = '<?xml version="1.0"?><html><head><title></title>'
    .. '<link href="../Styles/stylesheets.css" rel="stylesheet" type="text/css" /></head>'
    .. '<body><h2 class="secondTitle">1</h2><p class="content"><span class="wr-underline">正文</span>'
    .. '<img class="qqreader-footnote" alt="注" src="../Images/note.png" /></p>'
    .. '<img src="https://res.weread.qq.com/x.png" /></body></html>\n'
    .. '<?xml version="1.0"?><html><head><title></title></head><body><p>第二段文档</p></body></html>'
local PLAIN = "\239\187\191第一行 <b>\n  第二行"
local TRIAL = "“第四路，已过浔阳！”\n这是李善德发明的脚程格眼。..."

package.preload["source.wechat.protocol"] = function()
    return {
        readerUrl = function() return "https://weread.qq.com/web/reader/id" end,
    }
end

package.preload["source.wechat.package"] = function()
    return {
        password = function() return "pw" end,
        formatChaptersParam = function(uids)
            uids = uids or {}
            if #uids == 0 then return "0" end
            local nums = {}
            for i, u in ipairs(uids) do
                local n = tonumber(u)
                if not n then
                    local parts = { "0" }
                    for _idx, x in ipairs(uids) do parts[#parts + 1] = tostring(x) end
                    return table.concat(parts, ",")
                end
                nums[i] = n
            end
            local ok = true
            for i = 2, #nums do if nums[i] ~= nums[i - 1] + 1 then ok = false break end end
            if ok then
                local a, b = nums[1], nums[#nums]
                if a == 1 then return "0-" .. b end
                if a == b then return "0," .. a end
                return "0," .. a .. "-" .. b
            end
            local parts = { "0" }
            for _idx, n in ipairs(nums) do parts[#parts + 1] = tostring(n) end
            return table.concat(parts, ",")
        end,
        extractChapters = function(files, _book, uids, book_type)
            local out, style = {}, files["Styles/stylesheets.css"]
            for _idx, uid in ipairs(uids) do
                local html = FULL
                if trial then html = TRIAL elseif bom then html = "98791" .. FULL end
                -- keep real BOM via bytes below in separate fix
                out[tostring(uid)] = { text = html, format = book_type == "txt" and "txt" or "html" }
            end
            return out, style
        end,
        unzip = function()
            local q = queries[#queries]
            local ch = tostring(q.chapters or "")
            if ch == "0" or ch:find("^0%-") or ch:find("^0,") then
                return { ["Styles/stylesheets.css"] = ".content{text-indent:2em}", dummy = true }
            end
            return { dummy = true }
        end,
        pickStyle = function(files)
            return files["Styles/stylesheets.css"] or files["Styles/stylesheet.css"]
        end,
        chapterHtml = function()
            if txt_zip then error("TXT ZIP with text entry must not fall back to chapterHtml") end
            if trial then return TRIAL end
            if bom then return "\239\187\191" .. FULL end
            return FULL
        end,
        chapterText = function() return PLAIN end,
        chapterZipText = function()
            if txt_zip and not zip_text_missing then return PLAIN end
            return nil
        end,
    }
end

package.preload["source.wechat.assets"] = function()
    return {
        localizeAsync = function(_book, _chapter, html, _referer, fetch_style, cb)
            return fetch_style(function(css)
                Assert.eq(css, ".content{text-indent:2em}")
                cb((html:gsub("https://res%.weread%.qq%.com/x%.png", "images/x.png")))
            end)
        end,
    }
end

for _, name in ipairs({
    "workers.job", "http.request", "source.wechat.eink", "source.wechat.package", "source.wechat.chapter",
}) do
    package.loaded[name] = nil
end
local Chapter = require("source.wechat.chapter")
local Context = require("source.wechat.context")
Context.clear()
Context.rememberBookVersion("book", 7)

do
    -- EPUB：解码后的 xhtml 原样交出，不抽 body、不删虚线 / title、不改脚注；range 坐标原文同一份。
    local html_out, range_source, format
    Chapter.fetchHtmlAsync("book", { uid = "chapter" }, function(html, err, raw, fmt)
        Assert.is_nil(err)
        html_out, range_source, format = html, raw, fmt
    end)
    Assert.eq(html_out, FULL)
    Assert.eq(range_source, FULL)
    Assert.eq(format, "html")
    Assert.eq(#queries, 1)
    Assert.eq(queries[1].bookType, "epub")
    Assert.eq(queries[1].chapters, "chapter")
    Assert.eq(queries[1].bookVersion, 7)
    Assert.eq(queries[1].offline, "0", "单章在线阅读 offline=0")
end

do
    -- TXT：bookType=txt，range 按包内纯文本逐 rune 计，段落化后的 HTML 只用于显示。
    local body, range_source, format
    Chapter.fetchHtmlAsync("book", { uid = "c2", format = "txt" }, function(html, err, raw, fmt)
        Assert.is_nil(err)
        body, range_source, format = html, raw, fmt
    end)
    Assert.eq(range_source, PLAIN)
    Assert.eq(format, "txt")
    Assert.is_true(body:find("<p>", 1, true) ~= nil)
    -- 段首空白只在显示用 HTML 里剥掉，缩进统一由 CSS 给。
    Assert.is_true(body:find("<p>第二行</p>", 1, true) ~= nil)
    Assert.eq(queries[#queries].bookType, "txt")
    Assert.eq(queries[#queries].chapters, "c2")
end

do
    -- 交给宿主：EPUB 是整份 document，只改资源引用；TXT 仍是 html 片段走外壳。
    local payload
    local before = #queries
    Chapter.fetchContentAsync("book", { idx = 1, uid = "chapter", title = "第一章" }, function(p) payload = p end)
    -- 正文一次，样式表一次（chapters=0），没有网页分片。
    Assert.eq(queries[before + 1].chapters, "chapter")
    Assert.eq(queries[before + 1].bookType, "epub")
    Assert.eq(queries[before + 2].chapters, "0")
    Assert.is_nil(payload.html)
    local note = '<img class="qqreader-footnote" alt="注" src="../Images/note.png" />'
    local expected = FULL:gsub("https://res%.weread%.qq%.com/x%.png", "images/x.png")
        :gsub(note:gsub("%p", "%%%0"), '<a href="#wr-fn1" id="wr-fnref1" epub:type="noteref">'
            .. '<img class="qqreader-footnote" alt="注" src="../Images/note.png" style="height:0.8em;width:auto;vertical-align:super;border:0" /></a>')
        -- 两份拼接文档：aside 进最后一个 body；epub:type 让 KOReader 页内脚注 / 弹窗都能认。
        :gsub("<p>第二段文档</p></body>",
            '<p>第二段文档</p><aside id="wr-fn1" epub:type="footnote">[1] 注 <a href="#wr-fnref1">↩</a></aside>\n</body>')
    Assert.eq(payload.document, expected)
    -- 脚注图标尺寸不依赖整书样式表：行内 style 压到 0.8em 上标，原有 style 被替换。
    Assert.is_true(payload.document:find('height:0.8em', 1, true) ~= nil)

    Chapter.fetchContentAsync("book", { idx = 2, uid = "c2", format = "txt", title = "第2章 想<整>我" }, function(p) payload = p end)
    Assert.is_nil(payload.document)
    -- TXT 正文不带章名：章首补 h1（转义），EPUB 原文自带标题不补。
    local heading = "<h1>第2章 想&lt;整&gt;我</h1>"
    Assert.eq(payload.html:sub(1, #heading), heading)
    Assert.is_true(payload.html:find("<p>", 1, true) ~= nil)
end

do
    -- 脚注链接带原文件名：锚点在本章里就改成 #锚点，不在的（跨章）只留文字
    local saved = FULL
    FULL = FULL:gsub("</body></html>\n<%?xml", '<p><a href="part0012.html#note_1">[1]</a><a href="../Text/zhushi.xhtml#zhu116">[2]</a></p>'
        .. '<p id="note_1">注文</p></body></html>\n<?xml', 1)
    local payload
    Chapter.fetchContentAsync("book", { idx = 1, uid = "chapter", title = "第一章" }, function(p) payload = p end)
    FULL = saved
    Assert.is_true(payload.document:find('<a href="#note_1">[1]</a>', 1, true) ~= nil)
    Assert.is_nil(payload.document:find("zhushi", 1, true))
    Assert.is_true(payload.document:find("[2]", 1, true) ~= nil)
end

do
    -- 跨章注释链接里的图标：找不到注文也要限制尺寸，否则样式表缺规则时显示成大方块
    local saved = FULL
    FULL = FULL:gsub("</body></html>\n<%?xml", '<p>总之<a href="../Text/zhushi.xhtml#zhu9"><img class="x" src="n.png"/></a></p></body></html>\n<?xml', 1)
    local payload
    Chapter.fetchContentAsync("book", { idx = 1, uid = "chapter", title = "第一章" }, function(p) payload = p end)
    FULL = saved
    Assert.is_true(payload.document:find('<img class="x" src="n.png" style="height:0.8em', 1, true) ~= nil)
end

do
    -- 进度定位缓存写盘失败（磁盘满）：正文已到手，照常交出，不当成章节失败
    local Position = require("source.wechat.progress")
    local saved = Position.remember
    Position.remember = function() return nil, "disk full" end
    local payload, err
    Chapter.fetchContentAsync("book", { idx = 1, uid = "chapter", title = "第一章" }, function(p, e) payload, err = p, e end)
    Position.remember = saved
    Assert.is_nil(err)
    Assert.is_true(payload.document ~= nil)
end

do
    -- 注释章：锚点 id → 注文（去掉 [n] 序号与标签，保留实体转义）
    local notes = Chapter._noteTexts('<p class="noteContent"><a href="../Text/chapter32.xhtml#zw116" id="zhu116">[116]</a>当时多用沙子&amp;吸干墨迹。</p>'
        .. '<p>无锚点</p><p class="noteContent"><a id="zhu117">[117]</a></p>')
    Assert.eq(notes.zhu116, "当时多用沙子&amp;吸干墨迹。")
    Assert.is_nil(notes.zhu117)
end

do
    -- 无权阅读的付费章：EPUB 通道回纯文本试读片段，必须报错，不能当正文落盘。
    trial = true
    local payload, err = "untouched", nil
    Chapter.fetchContentAsync("book", { idx = 2, uid = "paid", title = "第二章" }, function(p, e) payload, err = p, e end)
    trial = false
    Assert.is_nil(payload)
    Assert.matches(err, "试读")
end

do
    -- 服务端给 XHTML 带 UTF-8 BOM：是正文，不能当试读片段拒掉。
    bom = true
    local payload, err = nil, nil
    Chapter.fetchContentAsync("book", { idx = 1, uid = "bom", title = "第一章" }, function(p, e) payload, err = p, e end)
    bom = false
    Assert.is_nil(err)
    Assert.is_true(payload ~= nil)
end

do
    -- App 通道失败就结束，不再改走网页。
    app_err = "加载失败"
    local n = #queries
    local html_out, err
    Chapter.fetchHtmlAsync("book", { uid = "flaky" }, function(h, e) html_out, err = h, e end)
    app_err = nil
    Assert.is_nil(html_out)
    Assert.eq(err, "加载失败")
    Assert.eq(#queries, n + 1)
end

do
    -- 部分 TXT 章回包是加密 ZIP（非 ustar）：走 chapterZipText，不按 HTML 清单解析。
    txt_zip = true
    local body, range_source, format, err
    Chapter.fetchHtmlAsync("book", { uid = "1595", format = "txt" }, function(html, e, raw, fmt)
        body, err, range_source, format = html, e, raw, fmt
    end)
    txt_zip = false
    Assert.is_nil(err)
    Assert.eq(range_source, PLAIN)
    Assert.eq(format, "txt")
    Assert.is_true(body:find("<p>", 1, true) ~= nil)
    Assert.eq(queries[#queries].bookType, "txt")
end

do
    -- 未缓存的书先拿真实版本，下一章直接复用，不把 0 当通用版本。
    local before = #info_requests
    Chapter.fetchHtmlAsync("fresh-book", { uid = "1" }, function(html, err)
        Assert.is_nil(err)
        Assert.eq(html, FULL)
    end)
    Assert.eq(queries[#queries].bookVersion, 7)
    Chapter.fetchHtmlAsync("fresh-book", { uid = "2" }, function(html, err)
        Assert.is_nil(err)
        Assert.eq(html, FULL)
    end)
    Assert.eq(#info_requests, before + 1)
end

do
    -- -2063 的 info.bookVersion 直接用于唯一一次重试，不额外拉详情。
    local attempts, callbacks, before = 0, 0, #info_requests
    Context.rememberBookVersion("updated-book", 3)
    app_response = function(_method, path, opts, cb)
        Assert.eq(path, "/book/chapterdownload")
        attempts = attempts + 1
        if attempts == 1 then
            Assert.eq(opts.query.bookVersion, 3)
            cb(nil, "version expired", { errcode = -2063, body = { info = { bookVersion = "8" } } })
        else
            Assert.eq(opts.query.bookVersion, 8)
            cb({ body = "PK", code = 200 })
        end
        return { cancel = function() end }
    end
    Chapter.fetchHtmlAsync("updated-book", { uid = "1" }, function(html, err)
        callbacks = callbacks + 1
        Assert.is_nil(err)
        Assert.eq(html, FULL)
    end)
    app_response = nil
    Assert.eq(attempts, 2)
    Assert.eq(callbacks, 1)
    Assert.eq(#info_requests, before)
    Assert.eq(Context.bookVersion("updated-book"), 8)
end

do
    -- 回包没有可用新版本（包括 0）时刷新详情；第二次过期直接失败。
    for i, info in ipairs({ {}, { bookVersion = "0" }, { bookVersion = "bad" }, { bookVersion = "4" } }) do
        local book_id = "expired-book-" .. i
        local attempts, details, callbacks = 0, 0, 0
        Context.rememberBookVersion(book_id, 4)
        app_response = function(_method, path, opts, cb)
            if path == "/book/info" then
                details = details + 1
                cb({ book = { version = 9 } })
            else
                attempts = attempts + 1
                Assert.eq(opts.query.bookVersion, attempts == 1 and 4 or 9)
                cb(nil, "version expired", { errcode = -2063, body = { info = info } })
            end
            return { cancel = function() end }
        end
        Chapter.fetchHtmlAsync(book_id, { uid = "1" }, function(html, err)
            callbacks = callbacks + 1
            Assert.is_nil(html)
            Assert.eq(err, "version expired")
        end)
        app_response = nil
        Assert.eq(attempts, 2)
        Assert.eq(details, 1)
        Assert.eq(callbacks, 1)
    end
end

do
    -- 获取版本失败或详情缺字段，必须交出错误，不能假装成功或盲发版本 0。
    for i, reply in ipairs({ { err = "network failed" }, { wire = {}, err = "缺少书籍版本" } }) do
        local before = #queries
        app_response = function(_method, path, _opts, cb)
            Assert.eq(path, "/book/info")
            cb(reply.wire, reply.wire and nil or reply.err)
            return { cancel = function() end }
        end
        Chapter.fetchHtmlAsync("bad-info-" .. i, { uid = "1" }, function(html, err)
            Assert.is_nil(html)
            Assert.eq(err, reply.err)
        end)
        app_response = nil
        Assert.eq(#queries, before)
    end
end

do
    -- 详情获取与过期恢复都能取消；迟来的回调不能继续下载或通知结果。
    for _idx, phase in ipairs({ "initial-info", "retry-download", "refresh-info" }) do
        local book_id = "cancel-" .. phase
        local pending, cancelled_path, callbacks
        callbacks = 0
        if phase ~= "initial-info" then Context.rememberBookVersion(book_id, 4) end
        local attempts = 0
        app_response = function(_method, path, _opts, cb)
            if path == "/book/chapterdownload" then
                attempts = attempts + 1
                if attempts == 1 then
                    local info = phase == "retry-download" and { bookVersion = 9 } or {}
                    cb(nil, "version expired", { errcode = -2063, body = { info = info } })
                    return { cancel = function() error("cancelled stale request") end }
                end
            end
            pending = cb
            return { cancel = function() cancelled_path = path end }
        end
        local handle = Chapter.fetchHtmlAsync(book_id, { uid = "1" }, function() callbacks = callbacks + 1 end)
        Assert.not_nil(pending)
        handle:cancel()
        Assert.eq(cancelled_path, phase == "retry-download" and "/book/chapterdownload" or "/book/info")
        local before = #queries
        if phase == "retry-download" then pending({ body = "PK", code = 200 })
        else pending({ book = { version = 9 } }) end
        Assert.eq(#queries, before)
        Assert.eq(callbacks, 0)
        app_response = nil
    end
end

do
    -- 已开始解包也能取消，Job 的迟到完成/失败不能再交出结果。
    local Job = require("workers.job")
    local run = Job.run
    for _idx, format in ipairs({ "epub", "txt" }) do
        local pending, cancelled, callbacks = nil, false, 0
        Job.run = function(_fn, opts)
            pending = opts
            return { cancel = function() cancelled = true end }
        end
        local handle = Chapter.fetchHtmlAsync("book", { uid = "1", format = format }, function()
            callbacks = callbacks + 1
        end)
        Assert.not_nil(pending)
        handle:cancel()
        Assert.is_true(cancelled)
        pending.on_done({ text = format == "txt" and PLAIN or FULL })
        pending.on_failed("late failure")
        Assert.eq(callbacks, 0)
    end
    Job.run = run
end

do
    -- TXT ZIP 缺正文就报包错误，不能退回 EPUB 清单。
    txt_zip, zip_text_missing = true, true
    Chapter.fetchHtmlAsync("book", { uid = "1595", format = "txt" }, function(html, err)
        Assert.is_nil(html)
        Assert.matches(err, "zip: chapter 1595 not in package")
    end)
    txt_zip, zip_text_missing = false, false
end

do
    -- 批量：prime 五章 offline=1、chapters=0-5；随后 fetchHtml 不再打网。
    Context.rememberBookVersion("batch-book", 7)
    local before = #queries
    local chapters = {}
    for i = 1, 5 do chapters[i] = { uid = tostring(i), idx = i } end
    local ok_out, err_out
    Chapter.primeBatchAsync("batch-book", chapters, { offline = true }, function(ok, err)
        ok_out, err_out = ok, err
    end)
    Assert.is_true(ok_out)
    Assert.is_nil(err_out)
    Assert.eq(queries[before + 1].chapters, "0-5")
    Assert.eq(queries[before + 1].offline, "1")
    local after_prime = #queries
    local html_out
    Chapter.fetchHtmlAsync("batch-book", { uid = "3" }, function(html, err)
        Assert.is_nil(err)
        html_out = html
    end)
    Assert.eq(#queries, after_prime, "primed 章不得再次请求 chapterdownload")
    Assert.eq(html_out, FULL)
end
