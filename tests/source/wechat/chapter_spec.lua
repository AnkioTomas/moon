--[[--
微信章节正文的 range 坐标原文与 reader 状态回归测试。

@module tests.source.wechat.chapter_spec
--]]

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
            else
                cb(url:match("/e_1$") and "e1" or url:match("/t_0$") and "t0" or url:match("/t_1$") and "t1" or "e3")
            end
            return { cancel = function() end }
        end,
    }
end

local FULL = '<?xml version="1.0"?><html><head><title>t</title></head><body><title>重复标题</title>'
    .. '<p><span class="wr-underline">正文</span></p></body></html>'
local PLAIN = "\239\187\191第一行 <b>\n  第二行"
local signed_with = {}

package.preload["source.wechat.protocol"] = function()
    return {
        readerUrl = function() return "https://weread.qq.com/web/reader/id" end,
        contentParams = function(_, _, psvts) signed_with[#signed_with + 1] = psvts return {} end,
        decodeShards = function() return txt and PLAIN or FULL end,
    }
end

package.preload["source.wechat.context"] = function()
    return {
        reader = function(book_id, uid) return { psvts = "ps-" .. book_id .. ":" .. uid } end,
    }
end

package.preload["source.wechat.assets"] = function()
    return {}
end

package.loaded["source.wechat.chapter"] = nil
local Chapter = require("source.wechat.chapter")

do
    -- EPUB：正文清理虚线与 title；range 坐标原文是解码后的完整 xhtml，不能裁成 body 片段。
    local cleaned, range_source, format
    Chapter.fetchHtmlAsync("book", { uid = "chapter" }, function(html, err, raw, fmt)
        Assert.is_nil(err)
        cleaned, range_source, format = html, raw, fmt
    end)
    Assert.eq(cleaned, "<p>正文</p>")
    Assert.eq(range_source, FULL)
    Assert.eq(format, "html")
    -- 不下载阅读页：分片直接用 Context 本地生成的 psvts 签名。
    Assert.eq(gets, 0, "不再请求阅读页")
    Assert.len(signed_with, 3)
    for _, ps in ipairs(signed_with) do Assert.eq(ps, "ps-book:chapter") end
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
