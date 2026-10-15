--[[--
source.fanqie.qrlogin：预热 → 取码 → 轮询 → 跟跳拿 sessionid → 落盘；过期与取消不落盘。
@module tests.source.fanqie.qrlogin_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

package.preload["json"] = function()
    return { decode = require("support.json_stub").decode, encode = function() return "{}" end }
end

-- 按 URL 前缀排队的罐头响应
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
            function o:close() self.closed = true; if self.close_callback then self.close_callback() end end
            return o
        end }
    end
end
package.preload["ui.themes.widgets.qr"] = widget("qr")
package.preload["ui.themes.widgets.confirm"] = widget("confirm")
package.preload["ui.themes.widgets.toast"] = widget("toast")

local QRLogin = require("source.fanqie.qrlogin")

local function newLogin()
    local saved = {}
    local settings = { set = function(_, k, v) saved[k] = v end, flush = function() saved.flushed = true end }
    local plugin = { showBusy = function() end, closeBusy = function() end,
        onLoginSuccess = function() saved.success = true end }
    return QRLogin:new(settings, plugin), saved
end

local function find(kind)
    for i = #shown, 1, -1 do if shown[i].kind == kind then return shown[i] end end
end

local QR_OK = { code = 200, headers = { ["Set-Cookie"] = "ttwid=t; Path=/" },
    body = '{"message":"success","data":{"token":"tok","qrcode_index_url":"https://qr/x"}}' }

do -- 成功：确认后 redirect_url 第二跳下发 sessionid（相对 Location 拼回原 host）
    script, requested, shown = {}, {}, {}
    respond("https://fanqienovel.com/main/writer/login",
        { code = 200, headers = { ["Set-Cookie"] = "passport_csrf_token=c1; Path=/; HttpOnly" } })
    respond("https://fanqienovel.com/passport/web/get_qrcode/", QR_OK)
    respond("https://fanqienovel.com/passport/web/check_qrconnect/",
        { code = 200, body = '{"data":{"status":"scanned"}}' })
    respond("https://fanqienovel.com/passport/web/check_qrconnect/",
        { code = 200, body = '{"data":{"status":"confirmed","redirect_url":"https://sso.fanqie/a"}}' })
    respond("https://sso.fanqie/a", { code = 302, headers = { Location = "/b" } })
    respond("https://sso.fanqie/b", { code = 200, headers = { ["Set-Cookie"] = "sessionid=S; Path=/; Secure" } })
    local login, saved = newLogin()
    login:start()
    Stubs.flush()
    Assert.eq(find("qr").text, "https://qr/x")
    Assert.eq(saved.cookies.sessionid, "S")
    Assert.eq(saved.cookies.passport_csrf_token, "c1")
    Assert.is_nil(saved.cookies.Path, "Set-Cookie 属性不当 cookie 存")
    Assert.is_true(saved.success)
    Assert.is_true(find("qr").closed)
    -- 轮询带上 csrf 头
    Assert.eq(requested[3].headers["x-tt-passport-csrf-token"], "c1")
    Assert.len(script, 0)
end

do -- 过期：弹重试框，不落盘
    script, requested, shown = {}, {}, {}
    respond("https://fanqienovel.com/main/writer/login", { code = 200, headers = {} })
    respond("https://fanqienovel.com/passport/web/get_qrcode/", QR_OK)
    respond("https://fanqienovel.com/passport/web/check_qrconnect/",
        { code = 200, body = '{"data":{"status":"expired"}}' })
    local login, saved = newLogin()
    login:start()
    Stubs.flush()
    Assert.is_nil(saved.cookies)
    Assert.eq(find("confirm").ok_text ~= nil, true)
end

do -- 用户关掉二维码（轮询在途时）：迟到的 sessionid 不落盘，也不再轮询
    script, requested, shown = {}, {}, {}
    respond("https://fanqienovel.com/main/writer/login", { code = 200, headers = {} })
    respond("https://fanqienovel.com/passport/web/get_qrcode/", QR_OK)
    respond("https://fanqienovel.com/passport/web/check_qrconnect/",
        { code = 200, headers = { ["Set-Cookie"] = "sessionid=LATE" }, hook = function() find("qr"):close() end })
    local login, saved = newLogin()
    login:start()
    Stubs.flush()
    Assert.is_nil(saved.cookies)
    Assert.eq(#requested, 3, "关闭后不再轮询")
end
