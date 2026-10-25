--[[-- source.wechat.mp：公众号文章列表（新到旧）、书架里的公众号与分组、文章页 → 正文、图片改写。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
package.loaded["json"] = { decode = require("support.json_stub").decode }

local pages, urls = {}, {}
local localized = {}
local renewals = 0
package.loaded["source.wechat.auth"] = {
    sessionHeaders = function(extra)
        local h = { Cookie = "wr_vid=1; wr_skey=2" }
        if extra then for k, v in pairs(extra) do h[k] = v end end
        return h
    end,
    webPostAsync = function(url, _body, _opts, cb)
        renewals = renewals + 1
        Assert.matches(url, "/web/login/renewal")
        cb("{}", nil, { headers = { ["X-WR-Ticket"] = "T1", ["x-wrpa-0"] = "W1" } })
        return { cancel = function() end }
    end,
    webGetAsync = function(url, _opts, cb)
        urls[#urls + 1] = url
        cb(pages[url:match("reviewId=(.*)$") or "list"])
        return { cancel = function() end }
    end,
}
-- 正文改走 Request.stream：按 reviewId 吐 pages，超大页边吐边让调用方断开。
local stream_override = nil
package.loaded["http.request"] = {
    stream = function(opts, h)
        if stream_override then return stream_override(opts, h) end
        local job = { stopped = false }
        function job:cancel() self.stopped = true end
        urls[#urls + 1] = opts.url
        local key = opts.url:match("reviewId=(.*)$") or "list"
        local body = pages[key]
        if body == nil then
            if h.on_headers then h.on_headers(404, {}) end
            h.on_done("HTTP 404")
            return job
        end
        if h.on_headers then h.on_headers(200, {}) end
        local CHUNK = 256 * 1024
        for i = 1, #body, CHUNK do
            if job.stopped then break end
            h.on_data(body:sub(i, i + CHUNK - 1))
        end
        h.on_done(job.stopped and "cancelled" or nil)
        return job
    end,
    header = function(res, name)
        local headers = res and res.headers
        if not headers then return nil end
        if type(headers.get) == "function" then return headers:get(name, true) end
        local lower = name:lower()
        for k, v in pairs(headers) do
            if type(k) == "string" and k:lower() == lower then return v end
        end
    end,
}
package.loaded["http.timeout"] = { net = function() return 1 end }
package.loaded["http.request.header"] = { forRequest = function(e) return e or {} end, merge = function(a, b)
    local o = {}
    for k, v in pairs(b or {}) do o[k] = v end
    for k, v in pairs(a or {}) do o[k] = v end
    return o
end }
package.loaded["source.wechat.assets"] = {
    localizeArticleAsync = function(dir, html, cb)
        localized[#localized + 1] = dir
        cb(html)
        return { cancel = function() end }
    end,
}
package.loaded["source.wechat.mp"] = nil
local Mp = require("source.wechat.mp")

local function wire(items)
    local subs = {}
    for i, item in ipairs(items) do
        subs[i] = { reviewId = item[1], review = { reviewId = item[1], createTime = item[2], mpInfo = { title = item[3] } } }
    end
    return { reviews = { { createTime = 0, subReviews = subs } } }
end

-- 文章列表：新到旧、去重、无标题用日期。
local list = Mp.articles(wire({ { "r1", 100, "一" }, { "r2", 200, "" }, { "r1", 100, "一" } }))
Assert.len(list, 2)
Assert.eq(list[1].guid, "r2")
Assert.eq(list[1].title, os.date("%Y-%m-%d", 200))
Assert.eq(list[2].title, "一")
Assert.len(Mp.articles({}), 0)

-- 分页：offset 以推送组为单位（maxIdx 被服务端无视），第三个回调参数是这页的组数。
pages.list = '{"reviews":[{"createTime":9,"subReviews":[{"reviewId":"r9","review":{"reviewId":"r9","createTime":9,"mpInfo":{"title":"九"}}}]}]}'
local got, groups
Mp.fetchArticlesAsync("MP_WXS_1", 40, function(items, _e, n) got, groups = items, n end)
Assert.eq(got[1].guid, "r9")
Assert.eq(groups, 1)
Assert.matches(urls[#urls], "offset=40")
Assert.matches(urls[#urls], "count=20")
Assert.is_true(not urls[#urls]:find("maxIdx", 1, true))
pages.list = '{"errcode":-2010,"errmsg":"登录超时"}'
local err
Mp.fetchArticlesAsync("MP_WXS_1", 0, function(items, e) got, err = items, e end)
Assert.eq(got, nil)
Assert.eq(err, "登录超时")
-- -2041（会话层续期后仍被拒，cb 给的是 err + res）：换成公众号授权失效提示
pages.list = nil
local auth = package.loaded["source.wechat.auth"]
local orig = auth.webGetAsync
auth.webGetAsync = function(_url, _opts, cb)
    cb(nil, "微信读书拒绝了请求，请稍后再试", { body = '{"errCode":-2041,"errMsg":"-2041"}' })
    return { cancel = function() end }
end
Mp.fetchArticlesAsync("MP_WXS_1", 0, function(items, e) got, err = items, e end)
Assert.eq(got, nil)
Assert.eq(err, Mp.AUTH_EXPIRED)
auth.webGetAsync = orig

-- 书架里的公众号：books 行、mp.book 单对象、data.officialAccounts 都收，去重；分组取 archive 名。
local accounts = Mp.accounts({
    books = { { bookId = "1", title = "书" }, { bookId = "MP_WXS_3", title = "号三" } },
    mp = { book = { bookId = "MP_WXS_1", title = "号一" }, show = 1 },
    data = { officialAccounts = { { bookId = "MP_WXS_2", title = "号二" }, { bookId = "MP_WXS_1", title = "重复" } } },
    archive = { { name = "科技", bookIds = { "MP_WXS_1", "1" } } },
})
local by = {}
for _idx, a in ipairs(accounts) do by[a.id] = a end
Assert.len(accounts, 3)
Assert.eq(by["MP_WXS_1"].title, "号一")
Assert.eq(by["MP_WXS_1"].group, "科技")
Assert.eq(by["MP_WXS_2"].group, "")
Assert.eq(by["1"], nil, "普通书不收")
Assert.eq(Mp.isMp("MP_WXS_9"), true)
Assert.eq(Mp.isMp("3300"), false)

-- 正文：只取 js_content，去脚本 / svg，剥内联字号（两种引号），懒加载图换 src 并降档。
local html = '<html><body><div id="js_content" style="visibility:hidden">'
    .. '<p style="font-size: 15px;color:red">正文</p><span style=\'font-size:17px\'>二</span>'
    .. '<svg viewBox="0 0 1 1"><rect/></svg><script>x()</script>'
    .. '<img data-src="https://mmbiz.qpic.cn/mmbiz_jpg/abc/0?wx_fmt=jpeg&amp;tp=webp" src="data:x" width="1080" style="width:1080px">'
    .. '</div><script>var a</script></body></html>'
local body = Mp.extractBody(html)
Assert.not_nil(body:find("<p style=\"color:red\">正文</p>", 1, true), "字号剥掉、其余样式保留")
Assert.not_nil(body:find("<span>二</span>", 1, true), "单引号样式也剥")
Assert.is_nil(body:find("svg", 1, true))
Assert.is_nil(body:find("script", 1, true))
Assert.not_nil(body:find('<img src="https://mmbiz.qpic.cn/mmbiz_jpg/abc/640?wx_fmt=jpeg"/>', 1, true), body)
Assert.eq(Mp.extractBody("<html>没有正文</html>"), nil)
local many = '<div id="js_content">' .. string.rep('<img data-src="https://x/a.png">', 40) .. "</div><script>"
local _n, imgs = Mp.extractBody(many):gsub("<img", "")
Assert.eq(imgs, 40, "图片不设上限")

-- 实测页面形状（脱敏）：class 在 id 前、属性跨行、正文前有几百 KB 脚本；正文后的 JS 里另有一份 content_noencode。
local real = "<!DOCTYPE html>\n<html class=\"\n\">\n<head><script>" .. string.rep("var a=1;", 20000) .. "</script></head><body>\n"
    .. '<div class="rich_media_content js_underline_content\n                autoTypeSetting24psection\n            "\n'
    .. '            id="js_content" style="visibility: hidden; opacity: 0; "><section><span leaf="">图文正文</span></section>\n'
    .. "</div>\n<script>var x = { content_noencode: '\\x3cp\\x3e不该用这份\\x3c/p\\x3e' };</script></body></html>"
Assert.matches(Mp.extractBody(real), "图文正文")
Assert.is_nil(Mp.extractBody(real):find("不该用这份", 1, true))

-- 图片 / 纯文字消息没有 js_content：正文取脚本里的 content_noencode（解 \x / \u / \n 转义），图片取 picture_page_info_list。
local picture = "<html><body><div id=\"js_image_content\"></div><script>var data = {\n"
    .. "  title: '标题',\n  content_noencode: '第一行\\n\\u7b2c\\u4e8c\\u884c \\x26 \\'引号\\'',\n"
    .. "  picture_page_info_list: [ { cdn_url: 'https://mmbiz.qpic.cn/sz_mmbiz_jpg/a/0?wx_fmt=jpeg', width: '1080' },\n"
    .. "    { cdn_url: 'https://mmbiz.qpic.cn/sz_mmbiz_png/b/0?wx_fmt=png', watermark_info: { x: 1 } } ],\n"
    .. "  other_list: [ { cdn_url: 'https://evil/c.png' } ]\n};</script></body></html>"
local pic = Mp.extractBody(picture)
Assert.matches(pic, "第一行")
Assert.matches(pic, "第二行 &amp; '引号'")
Assert.not_nil(pic:find('<img src="https://mmbiz.qpic.cn/sz_mmbiz_jpg/a/640?wx_fmt=jpeg"/>', 1, true), pic)
Assert.not_nil(pic:find("sz_mmbiz_png/b/640", 1, true))
Assert.is_nil(pic:find("evil", 1, true), "只取 picture_page_info_list 里的图")
Assert.matches(Mp.extractBody("<script>x = { content_noencode: '\\x3cp\\x3eHTML 正文\\x3c/p\\x3e' }</script>"), "<p>HTML 正文</p>")
Assert.is_nil(Mp.extractBody("<script>x = { content_noencode: '' }</script>"))
local sto = Mp.extractBody("<script>x = { content_noencode: 'a', picture_page_info_list: [{ cdn_url: 'http://320.wxapp.tc.qq.com/s?m=1\\x26amp;k=2' }] }</script>")
Assert.not_nil(sto:find('src="http://320.wxapp.tc.qq.com/s?m=1&amp;k=2"', 1, true), sto)

-- emoji：KOReader 字体画不出，一律去掉（不留方块）。脚本正文里的代理对先合成码点再去掉，不能留下两段非法 UTF-8
local GRIN = "\240\159\152\128"
Assert.eq(Mp.extractBody("<script>x = { content_noencode: 'A\\uD83D\\uDE00B\\u4E2D' }</script>"), "<p>AB中</p>")
Assert.is_nil(Mp.extractBody("<script>x = { content_noencode: 'A\\uD83D\\uDE00B' }</script>"):find("\237", 1, true))
-- 正文里的码点（含 ZWJ 序列、肤色、VS16）去掉、★ 保留；雪碧图空 span 删；QQ 表情透明占位图去掉、留 alt
local family = "\240\159\145\168\226\128\141\240\159\145\169" -- 👨‍👩
local thumb = "\240\159\145\141\240\159\143\189"                 -- 👍🏽
local emo = Mp.extractBody('<div id="js_content"><p>好' .. GRIN .. family .. thumb .. "\226\157\164\239\184\143" .. "\226\152\133"
    .. '<span class="emoji emoji1f600"></span>'
    .. '<img class="qqemoji qqemoji1" alt="[微笑]" src="https://res.wx.qq.com/mpres/pic_blank.gif">'
    .. '<img class="qqemoji" src="https://res.wx.qq.com/mpres/pic_blank.gif"></p></div><script></script>')
Assert.eq(emo, "<p>好\226\157\164\226\152\133[微笑]</p>")

-- 拉正文：图片交给 assets 落到给定目录；不给目录不落地。
pages["r1"] = html
Mp.fetchContentAsync("r1", "/tmp/x/images", function(h) got = h end)
Assert.matches(got, "正文")
Assert.eq(localized[1], "/tmp/x/images")
Mp.fetchContentAsync("r1", nil, function(h) got = h end)
Assert.len(localized, 1, "不给目录不下图")
pages["big"] = html .. string.rep("x", 9 * 1024 * 1024)
Mp.fetchContentAsync("big", nil, function(p, e) got, err = p, e end)
Assert.matches(got, "正文", "页面大小不设上限")
Mp.fetchContentAsync("none", nil, function(p, e) got, err = p, e end)
Assert.eq(got, nil)

-- 「验证」反爬页：重拉，最多 VERIFY_TRIES 次；一直是验证页给专门的提示。
local verify_page = "<html><head><title>验证</title></head><body>x</body></html>"
local seq = { verify_page, html }
local calls = 0
stream_override = function(_opts, h)
    calls = calls + 1
    local body = seq[calls] or verify_page
    local job = { cancel = function() end }
    if h.on_headers then h.on_headers(200, {}) end
    h.on_data(body)
    h.on_done(nil)
    return job
end
local delays = {}
Mp.later = function(sec, fn) delays[#delays + 1] = sec; fn() end
got = nil
Mp.fetchContentAsync("v", nil, function(h) got = h end)
Assert.eq(calls, 2); Assert.matches(got, "正文"); Assert.eq(delays[1], 2, "退避再拉")
calls, seq = 0, {}
Mp.fetchContentAsync("v", nil, function(p, e) got, err = p, e end)
Assert.eq(calls, Mp.VERIFY_TRIES); Assert.eq(got, nil); Assert.matches(err, "验证")
stream_override = nil

-- 回 -2041：续期拿到 ticket / wrpa 头后带头重试；之后的请求直接带头。
do
    local real = package.loaded["source.wechat.auth"].webGetAsync
    local sent = {}
    package.loaded["source.wechat.auth"].webGetAsync = function(_url, opts, cb)
        sent[#sent + 1] = opts.headers or {}
        if #sent == 1 then
            cb(nil, "x", { json = { errcode = -2041 } })
        else
            cb("{...}", nil, { json = wire({ { "r6", 6, "六" } }) })
        end
        return { cancel = function() end }
    end
    local items
    renewals = 0
    Mp.fetchArticlesAsync("MP_WXS_1", 0, function(list) items = list end)
    Assert.eq(renewals, 1)
    Assert.eq(items[1].guid, "r6")
    Assert.eq(sent[2]["x-wr-ticket"], "T1")
    Assert.eq(sent[2]["x-wrpa-0"], "W1")
    package.loaded["source.wechat.auth"].webGetAsync = real
end

-- 会话层续期重试后仍被拒：raw=nil、res 只有 body，也要走公众号凭据续期再重试。
do
    local real = package.loaded["source.wechat.auth"].webGetAsync
    local sent = {}
    package.loaded["source.wechat.auth"].webGetAsync = function(_url, opts, cb)
        sent[#sent + 1] = opts.headers or {}
        if #sent == 1 then
            cb(nil, "微信读书拒绝了请求，请稍后再试", { body = '{"errCode":-2041,"errMsg":"-2041"}' })
        else
            cb("{...}", nil, { json = wire({ { "r7", 7, "七" } }) })
        end
        return { cancel = function() end }
    end
    local items
    renewals = 0
    Mp.fetchArticlesAsync("MP_WXS_1", 0, function(list) items = list end)
    Assert.eq(renewals, 1)
    Assert.eq(items[1].guid, "r7")
    Assert.eq(sent[2]["x-wr-ticket"], "T1")
    package.loaded["source.wechat.auth"].webGetAsync = real
end

-- 只解一次：会话层已解过（res.json）就直接用，不再 decode。
do
    local real = package.loaded["source.wechat.auth"].webGetAsync
    local decodes = 0
    local real_decode = package.loaded["json"].decode
    package.loaded["json"].decode = function(...) decodes = decodes + 1; return real_decode(...) end
    package.loaded["source.wechat.auth"].webGetAsync = function(_url, _opts, cb)
        cb("{...}", nil, { json = wire({ { "r5", 5, "五" } }) })
        return { cancel = function() end }
    end
    local items
    Mp.fetchArticlesAsync("MP_WXS_1", 0, function(list) items = list end)
    Assert.eq(items[1].guid, "r5")
    Assert.eq(decodes, 0, "res.json 已解过，不再解")
    package.loaded["source.wechat.auth"].webGetAsync = real
    package.loaded["json"].decode = real_decode
end

-- 正文先按 id 切片：js_content 之前的大段脚本不参与匹配；属性顺序不同也认。
do
    local page = "<html><script>" .. string.rep("var a='<div id=\"x\">';", 1000) .. "</script>"
        .. '<div class="rich_media_content" id="js_content" style="visibility:hidden"><p>切片正文</p></div><script>z()</script>'
    Assert.eq(Mp.extractBody(page), "<p>切片正文</p>")
end

-- 旧版本同步进书库的公众号行：只撕 MP_WXS_ 的，普通书不动。
do
    local removed = {}
    local n = Mp.dropLegacyBooks({
        stableIdsBySource = function(source) Assert.eq(source, "wechat"); return { "100", "MP_WXS_1", "MP_WXS_2" } end,
        remove = function(source, id) removed[#removed + 1] = source .. ":" .. id end,
    })
    Assert.eq(n, 2)
    Assert.eq(table.concat(removed, ","), "wechat:MP_WXS_1,wechat:MP_WXS_2")
end
