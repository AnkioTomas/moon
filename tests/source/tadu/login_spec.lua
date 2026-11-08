--[[--
塔读登录隔离、回调域限制、同步回调取消及旧账号保护。

@module tests.source.tadu.login_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local JSON = require("support.json_stub")
package.loaded["json"] = JSON
local cfg, requests, saved = {}, {}, 0
local cleared = 0
package.loaded["source.logout"] = { clear = function(_id, clear)
    clear(); cleared = cleared + 1; return true
end }
package.loaded["utils.settings"] = {
    getSource = function() return cfg end,
    saveSource = function() saved = saved + 1 end,
}
local mode = "delayed"
local user = JSON.encode({ data = { user = { nickname = "测试用户" } } })
package.loaded["http.request"] = {
    headerAll = function(res) return res and res.cookies or {} end,
    header = function(res) return res and res.location end,
    get = function(url, options, cb)
        local request = { url = url, options = options, cb = cb }
        requests[#requests + 1] = request
        local handle = { cancel = function() request.cancelled = true end }
        if mode == "redirect" then cb(nil, "HTTP 302", { code = 302, location = "https://evil.test/" })
        else cb("ok", nil, { cookies = { "session=new; Path=/; HttpOnly; SameSite=Lax" } }) end
        return handle
    end,
    post = function(url, body, options, cb)
        local request = { url = url, options = options, body = body, cb = cb }
        requests[#requests + 1] = request
        if mode == "success" then cb(user) end
        return { cancel = function() request.cancelled = true end }
    end,
}
local Client = require("source.tadu.client")
local calls = 0
local result, reason
local handle = Client.exchangeAsync("test", function(value, err) calls, result, reason = calls + 1, value, err end)
Assert.eq(requests[1].options.headers.Cookie, "", "匿名兑换不能发送旧账号 Cookie")
Assert.eq(requests[2].options.headers.Cookie, "session=new", "Cookie 属性不是额外 Cookie")
handle:cancel()
Assert.is_true(requests[2].cancelled, "同步兑换回调后取消当前校验请求")
requests[2].cb(user)
Assert.eq(calls, 0)
Assert.eq(saved, 0)

mode = "success"
Client.exchangeAsync("test", function(value) result = value end)
Assert.eq(result.name, "测试用户")
Assert.eq(cfg.cookie, "session=new")
Assert.eq(saved, 1)

cfg.cookie = "session=old"
Client.exchangeAsync("test", function(value, err) result, reason = value, err end)
Assert.is_true(result ~= nil)
Assert.is_nil(reason)
Assert.eq(cfg.cookie, "session=new")
Assert.eq(cleared, 1)
Assert.eq(saved, 3)

mode = "redirect"
Client.exchangeAsync("test", function(value, err) result, reason = value, err end)
Assert.is_nil(result)
Assert.eq(reason, "塔读登录回调无效")
Assert.eq(cfg.cookie, "session=new")

mode = "delayed"
Client.loginCheckAsync("session=old", function(value, err) result, reason = value, err end)
requests[#requests].cb(nil, "network down")
Assert.eq(result, false)
Assert.eq(reason, "network down")
Assert.eq(cfg.cookie, "session=new")

Client.loginCheckAsync("session=old", function(value, err) result, reason = value, err end)
cfg.cookie = "session=changed"
requests[#requests].cb(user)
Assert.eq(result, false)
Assert.eq(reason, "塔读登录已改变，请重试")

local Mapper = require("source.tadu.mapper")
local items, pages = Mapper.reviews([[
<h1>作品评论区</h1>
<div class="commentIntro"><h4>甲</h4><h5>标题</h5><p>评论一</p><span class="time">今天</span></div>
<div class="commentIntro"><h4>乙</h4><h5></h5><p>评论二</p><span class="time">昨天</span></div>
<a href="/v4/book/comment/9/1/3">3</a>
]])
Assert.len(items, 2)
Assert.eq(items[2].text, "评论二")
Assert.eq(pages, 3)
Assert.len(Mapper.reviews("<h1>作品评论区</h1>"), 0)
Assert.is_nil(Mapper.reviews("<title>故障</title>"))
local content, content_err, font = Mapper.content({ status = 200, data = { content = "<p>编码正文</p>", url = "https://font.test/font.ttf" } })
Assert.is_nil(content, "未解码字体不能写成成功缓存")
Assert.matches(content_err, "字体还原")
Assert.eq(font.html, "<p>编码正文</p>")
