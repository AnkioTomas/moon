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

local txt = false
local gets = 0
local empty_e0 = 0

package.preload["source.wechat.auth"] = function()
    return {
        hasSession = function() return true end,
        webGetAsync = function()
            gets = gets + 1
            return { cancel = function() end }
        end,
        webPostAsync = function(url, _, _, cb)
            if url:match("/e_0$") and empty_e0 > 0 then
                empty_e0 = empty_e0 - 1
                cb("{}")
            elseif url:match("/e_0$") then
                cb(txt and '{"bookId":"1"}' or "e0")
            elseif url:match("/e_2$") then
                cb("e2")
            else
                cb(url:match("/e_1$") and "e1" or url:match("/t_0$") and "t0" or url:match("/t_1$") and "t1" or "e3")
            end
            return { cancel = function() end }
        end,
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
local trial = false
local bom = false
local signed_with = {}
local styles = {}

package.preload["source.wechat.protocol"] = function()
    return {
        readerUrl = function() return "https://weread.qq.com/web/reader/id" end,
        contentParams = function(_, _, psvts, opts)
            signed_with[#signed_with + 1] = psvts
            styles[#styles + 1] = opts.style
            return {}
        end,
        decodeShards = function(first)
            if first == "e2" then return ".content{text-indent:2em}" end
            if trial then return TRIAL end
            if bom then return "\239\187\191" .. FULL end
            return txt and PLAIN or FULL
        end,
    }
end

package.preload["source.wechat.context"] = function()
    return {
        reader = function(book_id, uid) return { psvts = "ps-" .. book_id .. ":" .. uid } end,
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

package.loaded["source.wechat.chapter"] = nil
local Chapter = require("source.wechat.chapter")

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
    -- 不下载阅读页：分片直接用 Context 本地生成的 psvts 签名。
    Assert.eq(gets, 0, "不再请求阅读页")
    Assert.len(signed_with, 3)
    for _, ps in ipairs(signed_with) do Assert.eq(ps, "ps-book:chapter") end
    -- st=1 时服务端回整书样式表而不是正文（实测），正文分片必须 st=0。
    for _, style in ipairs(styles) do Assert.is_false(style) end
end

do
    -- TXT：range 按解码后的纯文本逐 rune 计，段落化后的 HTML 只用于显示。
    txt = true
    local body, range_source, format
    Chapter.fetchHtmlAsync("book", { uid = "c2" }, function(html, err, raw, fmt)
        Assert.is_nil(err)
        body, range_source, format = html, raw, fmt
    end)
    txt = false
    Assert.eq(range_source, PLAIN)
    Assert.eq(format, "txt")
    Assert.is_true(body:find("<p>", 1, true) ~= nil)
    -- 段首空白只在显示用 HTML 里剥掉，缩进统一由 CSS 给。
    Assert.is_true(body:find("<p>第二行</p>", 1, true) ~= nil)
    Assert.eq(gets, 0)
end

do
    -- 交给宿主：EPUB 是整份 document，只改资源引用；TXT 仍是 html 片段走外壳。
    local payload
    styles = {}
    Chapter.fetchContentAsync("book", { idx = 1, uid = "chapter", title = "第一章" }, function(p) payload = p end)
    -- e_0/e_1/e_3 正文 st=0，最后 e_2 拉整书样式表 st=1。
    Assert.eq(table.concat({ tostring(styles[1]), tostring(styles[2]), tostring(styles[3]), tostring(styles[4]) }, ","),
        "false,false,false,true")
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

    txt = true
    Chapter.fetchContentAsync("book", { idx = 2, uid = "c2", title = "第2章 想<整>我" }, function(p) payload = p end)
    txt = false
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
    -- e_0 偶发回 "{}"（同一章稍后重拉就有正文）：延时重拉，不直接判失败。
    local delays = {}
    Chapter._schedule = function(sec, fn) delays[#delays + 1] = sec; fn() end
    empty_e0 = 2
    local html_out, err
    Chapter.fetchHtmlAsync("book", { uid = "flaky" }, function(h, e) html_out, err = h, e end)
    Assert.is_nil(err)
    Assert.eq(html_out, FULL)
    Assert.len(delays, 2)

    -- 退避：0.5s 起翻倍，单次封顶 8s，抖动不超过 0.2s。
    local base = { 0.5, 1, 2, 4, 8, 8, 8, 8, 8, 8 }
    for i, b in ipairs(base) do
        local d = Chapter._retryDelay(i - 1)
        Assert.is_true(d >= b and d <= b + 0.2, "delay " .. i)
    end

    -- 重试 10 次用尽仍为空才报错。
    delays = {}
    empty_e0 = 11
    html_out, err = nil, nil
    Chapter.fetchHtmlAsync("book", { uid = "flaky" }, function(h, e) html_out, err = h, e end)
    Assert.is_nil(html_out)
    Assert.matches(err, "empty")
    Assert.len(delays, 10)
    empty_e0 = 0

    -- 取消后不再重拉。
    local pending
    Chapter._schedule = function(_, fn) pending = fn end
    empty_e0 = 1
    local called = false
    local job = Chapter.fetchHtmlAsync("book", { uid = "flaky" }, function() called = true end)
    job:cancel()
    pending()
    Assert.is_false(called)
    empty_e0 = 0
end
