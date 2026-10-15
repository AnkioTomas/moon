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

package.preload["source.wechat.auth"] = function()
    return {
        hasSession = function() return true end,
        webGetAsync = function()
            gets = gets + 1
            return { cancel = function() end }
        end,
        webPostAsync = function(url, _, _, cb)
            if url:match("/e_0$") then
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
    Assert.eq(gets, 0)
end

do
    -- 交给宿主：EPUB 是整份 document，只改资源引用；TXT 仍是 html 片段走外壳。
    local payload
    styles = {}
    Chapter.fetchContentAsync("book", { uid = "chapter", title = "第一章" }, function(p) payload = p end)
    -- e_0/e_1/e_3 正文 st=0，最后 e_2 拉整书样式表 st=1。
    Assert.eq(table.concat({ tostring(styles[1]), tostring(styles[2]), tostring(styles[3]), tostring(styles[4]) }, ","),
        "false,false,false,true")
    Assert.is_nil(payload.html)
    local note = '<img class="qqreader-footnote" alt="注" src="../Images/note.png" />'
    local expected = FULL:gsub("https://res%.weread%.qq%.com/x%.png", "images/x.png")
        :gsub(note:gsub("%p", "%%%0"), '<a href="#wr-fn1" id="wr-fnref1" epub:type="noteref">'
            .. '<img class="qqreader-footnote" alt="注" src="../Images/note.png" style="height:0.8em;width:auto;vertical-align:super;border:0" /></a>')
        -- 两份拼接文档：aside 进最后一个 body。
        :gsub("<p>第二段文档</p></body>", '<p>第二段文档</p><aside id="wr-fn1" epub:type="footnote">注</aside>\n</body>')
    Assert.eq(payload.document, expected)
    -- 脚注图标尺寸不依赖整书样式表：行内 style 压到 0.8em 上标，原有 style 被替换。
    Assert.is_true(payload.document:find('height:0.8em', 1, true) ~= nil)

    txt = true
    Chapter.fetchContentAsync("book", { uid = "c2", title = "第2章 想<整>我" }, function(p) payload = p end)
    txt = false
    Assert.is_nil(payload.document)
    -- TXT 正文不带章名：章首补 h1（转义），EPUB 原文自带标题不补。
    local heading = "<h1>第2章 想&lt;整&gt;我</h1>"
    Assert.eq(payload.html:sub(1, #heading), heading)
    Assert.is_true(payload.html:find("<p>", 1, true) ~= nil)
end

do
    -- 无权阅读的付费章：EPUB 通道回纯文本试读片段，必须报错，不能当正文落盘。
    trial = true
    local payload, err = "untouched", nil
    Chapter.fetchContentAsync("book", { uid = "paid", title = "第二章" }, function(p, e) payload, err = p, e end)
    trial = false
    Assert.is_nil(payload)
    Assert.matches(err, "试读")
end
