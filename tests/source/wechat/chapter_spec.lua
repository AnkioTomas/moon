--[[--
微信章节正文的 range HTML 回归测试。

@module tests.source.wechat.chapter_spec
--]]

local Assert = require("support.assert")

package.preload["json"] = function()
    return {
        encode = require("support.json_stub").encode,
        decode = require("support.json_stub").decode,
    }
end

package.preload["source.wechat.auth"] = function()
    return {
        hasSession = function() return true end,
        webGetAsync = function(_, _, cb)
            cb([[window.__INITIAL_STATE__ = {"reader":{"psvts":"token"}};(function]])
            return { cancel = function() end }
        end,
        webPostAsync = function(url, _, _, cb)
            cb(url:match("/e_0$") and "e0" or url:match("/e_1$") and "e1" or "e3")
            return { cancel = function() end }
        end,
    }
end

package.preload["source.wechat.protocol"] = function()
    return {
        readerUrl = function() return "https://weread.qq.com/web/reader/id" end,
        contentParams = function() return {} end,
        decodeShards = function()
            return '<html><body><title>重复标题</title>'
                .. '<p><span class="wr-underline">正文</span></p></body></html>'
        end,
    }
end

package.preload["source.wechat.context"] = function()
    return { rememberPsvts = function() end }
end

package.preload["source.wechat.assets"] = function()
    return {}
end

package.loaded["source.wechat.chapter"] = nil
local Chapter = require("source.wechat.chapter")

local cleaned, range_html
Chapter.fetchHtmlAsync("book", { uid = "chapter" }, function(html, err, raw)
    Assert.is_nil(err)
    cleaned, range_html = html, raw
end)

Assert.eq(cleaned, "<p>正文</p>")
Assert.is_true(range_html:find("<title>重复标题</title>", 1, true) ~= nil)
Assert.is_true(range_html:find('class="wr-underline"', 1, true) ~= nil)
