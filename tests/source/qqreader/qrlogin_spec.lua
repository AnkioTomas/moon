--[[--
source.qqreader.qrlogin：取码 → 轮询 → ywguid/ywkey 或跟跳 Set-Cookie。
过期、关窗、手机取消刷新不把迟到的登录态交给 on_cookie。
浏览器扩展绑定仍指向 book.qq.com。
@module tests.source.qqreader.qrlogin_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

package.preload["json"] = function()
    return { decode = require("support.json_stub").decode, encode = function() return "{}" end }
end

package.preload["http.timeout"] = function()
    return { net = function() return 15 end }
end

local script, requested = {}, {}
local function respond(prefix, res) script[#script + 1] = { prefix = prefix, res = res } end
package.preload["http.request"] = function()
    return {
        request = function(opts, cb)
            requested[#requested + 1] = opts
            for i, item in ipairs(script) do
                if opts.url:sub(1, #item.prefix) == item.prefix then
                    table.remove(script, i)
                    require("ui/uimanager"):nextTick(function()
                        if item.res.hook then item.res.hook() end
                        cb(item.res)
                    end)
                    return { cancel = function() end }
                end
            end
            require("ui/uimanager"):nextTick(function() cb(nil, "no script") end)
            return { cancel = function() end }
        end,
        header = function(res, name) return res and res.headers and res.headers[name] end,
    }
end

local shown = {}
local function widget(kind)
    return function()
        return { new = function(_, o)
            o.kind = kind
            function o:show() shown[#shown + 1] = self end
            function o:close()
                self.closed = true
                if self.close_callback then self.close_callback() end
            end
            return o
        end }
    end
end
package.preload["ui.themes.widgets.qr"] = widget("qr")
package.preload["ui.themes.widgets.confirm"] = widget("confirm")
package.preload["ui.themes.widgets.toast"] = widget("toast")
package.preload["ui.themes.widgets.progress_dialog"] = widget("busy")

local QRLogin = require("source.qqreader.qrlogin")

local QR_PREFIX = "https://ptlogin.yuewen.com/login/qrcode?"
local POLL_PREFIX = "https://ptlogin.yuewen.com/login/qrcodelogin?"

local function reset()
    script, requested, shown = {}, {}, {}
end

local function find(kind)
    for i = #shown, 1, -1 do if shown[i].kind == kind then return shown[i] end end
end

local function toastCount(text)
    local n = 0
    for i = 1, #shown do
        if shown[i].kind == "toast" and shown[i].text == text then n = n + 1 end
    end
    return n
end

local function qrcode(session)
    return { code = 200, body = '{"code":0,"data":{"sessionKey":"' .. session .. '"}}' }
end

local function poll(body, extra)
    local res = { code = 200, body = body }
    if extra then
        for k, v in pairs(extra) do res[k] = v end
    end
    return res
end

do -- 扫码 URL 与官方同一组参数，顺序由 formEncode 排定
    Assert.eq(QRLogin.scanUrl("sk/1"),
        "https://ptlogin.yuewen.com/mobile/scanlogin?appid=1450000220&areaid=1"
        .. "&bookId=0&chapterId=0&sessionkey=sk%2F1")
end

do -- 等待是字符串 "0"，成功后 JSON 里的 ywGuid/ywKey 排成 Cookie
    reset()
    respond(QR_PREFIX, qrcode("sk1"))
    respond(POLL_PREFIX, poll('{"code":-11019,"scanStatus":"0"}'))
    respond(POLL_PREFIX, poll('{"code":0,"scanStatus":"5","data":{"ywGuid":"g1","ywKey":"k1","ywOpenId":"o1"}}'))
    local got
    QRLogin:new(function(cookie) got = cookie end):start()
    Stubs.flush()
    Assert.eq(find("qr").text,
        "https://ptlogin.yuewen.com/mobile/scanlogin?appid=1450000220&areaid=1"
        .. "&bookId=0&chapterId=0&sessionkey=sk1")
    Assert.eq(find("qr").caption, "用 QQ阅读或起点 App 扫一扫")
    Assert.eq(got, "ywguid=g1; ywkey=k1; ywopenid=o1")
    Assert.is_true(find("qr").closed)
    Assert.eq(toastCount("已取消登录"), 0)
    Assert.is_true(requested[1].allow_redirects == false)
    Assert.is_true(requested[2].url:find("qrcode=sk1", 1, true) ~= nil)
    Assert.len(script, 0)
end

do -- 已扫码只提示一次，确认后仍把登录态交出去
    reset()
    respond(QR_PREFIX, qrcode("sk1"))
    respond(POLL_PREFIX, poll('{"code":0,"scanStatus":"1"}'))
    respond(POLL_PREFIX, poll('{"code":0,"scanStatus":1}'))
    respond(POLL_PREFIX, poll('{"code":0,"scanStatus":"5","ywGuid":"g2","ywKey":"k2"}'))
    local got
    QRLogin:new(function(cookie) got = cookie end):start()
    Stubs.flush()
    Assert.eq(got, "ywguid=g2; ywkey=k2")
    Assert.eq(toastCount("已扫码，请在手机上确认"), 1)
end

do -- 过期：重试框，不交登录态
    reset()
    respond(QR_PREFIX, qrcode("sk1"))
    respond(POLL_PREFIX, poll('{"code":0,"scanStatus":"4"}'))
    local got
    QRLogin:new(function(cookie) got = cookie end):start()
    Stubs.flush()
    Assert.is_nil(got)
    Assert.eq(find("confirm").text, "二维码已过期")
    Assert.eq(find("confirm").ok_text, "重新获取")
    Assert.eq(#requested, 2)
end

do -- 用户关掉二维码：迟到的成功不交登录态，也不再轮询
    reset()
    respond(QR_PREFIX, qrcode("sk1"))
    respond(POLL_PREFIX, poll('{"code":0,"scanStatus":"5","data":{"ywGuid":"late","ywKey":"no"}}', {
        hook = function() find("qr"):close() end,
    }))
    local got
    QRLogin:new(function(cookie) got = cookie end):start()
    Stubs.flush()
    Assert.is_nil(got)
    Assert.eq(#requested, 2, "关闭后不再轮询")
    Assert.eq(toastCount("已取消登录"), 1)
end

do -- 只有 302url：跟跳收 Set-Cookie，相对 Location 拼回原 host；属性不当 cookie
    reset()
    respond(QR_PREFIX, qrcode("sk1"))
    respond(POLL_PREFIX, poll('{"code":0,"scanStatus":"5","data":{"302url":"https://ptlogin.yuewen.com/jump"}}'))
    respond("https://ptlogin.yuewen.com/jump", {
        code = 302, headers = { Location = "/done", ["Set-Cookie"] = "ywguid=g3; Path=/; HttpOnly" },
    })
    respond("https://ptlogin.yuewen.com/done", {
        code = 200, headers = { ["Set-Cookie"] = "ywkey=k3; Path=/, ywopenid=o3; Secure" },
    })
    local got
    QRLogin:new(function(cookie) got = cookie end):start()
    Stubs.flush()
    Assert.eq(got, "ywguid=g3; ywkey=k3; ywopenid=o3")
    Assert.is_nil(got and got:find("Path", 1, true))
    Assert.len(script, 0)
end

do -- 非 https 跳转不跟，不交登录态
    reset()
    respond(QR_PREFIX, qrcode("sk1"))
    respond(POLL_PREFIX, poll('{"code":0,"scanStatus":"5","data":{"302url":"http://evil.example/x"}}'))
    local got
    QRLogin:new(function(cookie) got = cookie end):start()
    Stubs.flush()
    Assert.is_nil(got)
    Assert.eq(find("confirm").text, "登录失败：未获取到登录态")
    Assert.eq(#requested, 2)
end

do -- 手机取消：关掉旧码不提示已取消，再要一张新码
    reset()
    respond(QR_PREFIX, qrcode("old"))
    respond(POLL_PREFIX, poll('{"code":0,"scanStatus":"3"}'))
    respond(QR_PREFIX, qrcode("new"))
    respond(POLL_PREFIX, poll('{"code":0,"scanStatus":"5","data":{"ywGuid":"g4","ywKey":"k4"}}'))
    local got
    QRLogin:new(function(cookie) got = cookie end):start()
    Stubs.flush()
    Assert.eq(got, "ywguid=g4; ywkey=k4")
    Assert.eq(toastCount("已取消登录"), 0)
    Assert.eq(requested[1].url:sub(1, #QR_PREFIX), QR_PREFIX)
    Assert.eq(requested[3].url:sub(1, #QR_PREFIX), QR_PREFIX)
    Assert.is_true(requested[4].url:find("qrcode=new", 1, true) ~= nil)
    Assert.len(script, 0)
end

do -- 浏览器扩展绑定不改到 passport
    local Setting = require("source.qqreader.setting")
    Assert.eq(Setting.browser.domain, "book.qq.com")
    Assert.eq(Setting.browser.login, "https://book.qq.com/book-shelf")
    Assert.eq(Setting.browser.check, "https://book.qq.com/book-shelf")
    Assert.eq(type(Setting.login), "function")
end
