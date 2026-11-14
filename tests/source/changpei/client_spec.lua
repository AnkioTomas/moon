--[[--
长佩客户端续期与正文权限回归用例。

@module tests.source.changpei.client_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

package.preload["json"] = function() return require("support.json_stub") end

local Assert = require("support.assert")
local Json = require("support.json_stub")
local requests, posts, jobs = {}, {}, {}
local settings = { cookie = "PHPSESSID=s; _c_n_=device; _c_n_n_=device; moon_refresh=refresh; moon_token=old" }
local expired
local check = 3
local read_check_code = 200
local get_cookies, post_cookies
local content_text = "chapter text"
local renewed_token = "new"
local defer_content, delayed_content
local signed
package.preload["ffi/sha2"] = function()
    return { md5 = function(value) signed = value; return "signature" end }
end
package.preload["source.changpei.mapper"] = function()
    return {
        content = function(wire)
            local level = wire.data.check
            if level > 1 then return content_text, nil, "verify" end
            return content_text
        end,
    }
end

package.preload["utils.settings"] = function()
    return {
        getSource = function() return settings end,
        saveSource = function() end,
    }
end
package.preload["source.auth"] = function()
    return {
        expire = function(_id, message) expired = message; return message end,
        ok = function() end,
    }
end
package.preload["workers.job"] = function()
    return {
        run = function(run, options)
            jobs[#jobs + 1] = function() options.on_done(run()) end
            return { cancel = function() end }
        end,
    }
end
package.preload["source.changpei.qrlogin"] = function()
    return {
        frame = function() return "refresh-request" end,
        decode = function() return { [3] = renewed_token } end,
    }
end
-- 模拟 Request.request 的 opts.jar 接线：发前带 Cookie，回包收 Set-Cookie
local function viaJar(url, options, callback, deliver)
    local jar, since = options.jar, options.jar and options.jar.seq
    local headers = {}
    for key, value in pairs(options.headers or {}) do headers[key] = value end
    headers.Cookie = headers.Cookie or (jar and jar:header(url))
    return headers, function(body, err, res)
        if jar and res then jar:absorb(url, res.headers["Set-Cookie"] or {}, since) end
        callback(body, err, res)
    end
end
package.preload["http.request"] = function()
    return {
        get = function(url, options, callback)
            local headers
            headers, callback = viaJar(url, options, callback)
            requests[#requests + 1] = { url = url, headers = headers }
            local body = Json.encode({ code = 200, data = url:find("/system/init", 1, true)
                and { timestamp = 123456 } or { check = check } })
            local cookies = get_cookies
            local function respond() callback(body, nil, { headers = { ["Set-Cookie"] = cookies } }) end
            if defer_content and url:find("/novel/chapterGetInfo", 1, true) then delayed_content = respond
            else respond() end
            return { cancel = function() end }
        end,
        post = function(_url, _body, options, callback)
            local headers
            headers, callback = viaJar(_url, options, callback)
            posts[#posts + 1] = { url = _url, body = _body, headers = headers }
            if _url:find("/novel/readCheck", 1, true) then
                callback(Json.encode({ code = 200, data = { code = read_check_code } }),
                    nil, { headers = { ["Set-Cookie"] = post_cookies } })
            else
                callback("grpc-body", nil, { headers = {} })
            end
            return { cancel = function() end }
        end,
        header = function() return "0" end,
        headerAll = function(res) return res.headers and res.headers["Set-Cookie"] or {} end,
    }
end

local Client = require("source.changpei.client")
local result, message, result_kind
Client.contentAsync("n", "c", function(text, err, kind) result, message, result_kind = text, err, kind end)
Assert.eq(#requests, 1)
Assert.eq(requests[1].headers.token, "old")
jobs[1]()
Assert.is_nil(result)
Assert.eq(#requests, 1, "check > 1 不是 token 过期信号，不应重试章节请求")
Assert.eq(#posts, 0, "不可读章节不应触发 token 续期")
Assert.eq(message, Client.VERIFY_REQUIRED)
Assert.eq(result_kind, "verify")
Assert.is_nil(expired, "check > 1 不应把有效登录标记为失效")

local renewed
Client.renewAsync(function(ok) renewed = ok end)
Assert.is_true(renewed, "refresh token 可单独续期")
Assert.eq(settings.cookie, "PHPSESSID=s; _c_n_=device; _c_n_n_=device; moon_refresh=refresh; moon_token=new")
Assert.eq(#posts, 1, "显式续期请求一次")
Assert.eq(posts[1].headers.token, "old")
Assert.eq(posts[1].headers.Cookie, "PHPSESSID=s; _c_n_=device; _c_n_n_=device")
Assert.eq(posts[1].headers.imei, "device")
Assert.eq(posts[1].headers["_c_n_"], "device")
Assert.eq(posts[1].headers["X-Grpc-Web"], "1")

local verified, verify_err
Client.readCheckAsync('proof"value', function(ok, err) verified, verify_err = ok, err end)
Assert.is_true(verified)
Assert.is_nil(verify_err)
Assert.eq(posts[2].url, "https://www.gongzicp.com/webapi/novel/readCheck")
Assert.eq(Json.decode(posts[2].body).token, 'proof"value')
Assert.eq(posts[2].headers.token, "new", "验证用设备登录态，浏览器不用重新登录")
Assert.eq(posts[2].headers.Timestamp, "123456")
Assert.eq(posts[2].headers["Rand-Str"], "signature")
Assert.eq(signed, 'SIa7xu0LRrbu$En3*I1T3EiO^40cN49D&token=proof"value&123456')
read_check_code = 400
Client.readCheckAsync("invalid-proof", function(ok, err) verified, verify_err = ok, err end)
Assert.is_false(verified, "外层 200 不代表滑块验证成功")
Assert.eq(verify_err, "验证失败，请重新滑动验证")

local verification_done, verification_cancelled
package.preload["source.changpei.verify"] = function()
    return {
        new = function(cb)
            verification_done = cb
            return { cancel = function() verification_cancelled = true end }
        end,
    }
end
-- check == 2 也必须重取，不能把验证前的可疑正文写进缓存。
check, result, message, verification_done = 2, nil, nil, nil
content_text = "untrusted before verification"
local first_job = #jobs + 1
local before = #requests
Client.openContentAsync("n", "c", function(text, err) result, message = text, err end)
jobs[first_job]()
Assert.not_nil(verification_done, "用户开章遇验证才打开扫码页")
Assert.is_nil(message, "等待验证时不提前结束开书")
check, content_text = 1, "chapter text"
verification_done(true)
Assert.eq(#requests, before + 2, "check < 3 验完也重取章节")
jobs[first_job + 1]()
Assert.eq(result, "chapter text", "只能交付验证后重新取得的正文")
Assert.is_nil(message)

-- check >= 3：验完像官网 reload，重取一次；重取降到 1 则成功。
check, result, message, verification_done = 3, nil, nil, nil
first_job = #jobs + 1
Client.openContentAsync("n", "c", function(text, err) result, message = text, err end)
jobs[first_job]()
Assert.not_nil(verification_done)
check = 1
verification_done(true)
jobs[first_job + 1]()
Assert.eq(result, "chapter text", "check >= 3 验证后自动重新取章")
Assert.is_nil(message)

check, result, verification_done, verification_cancelled = 3, nil, nil, nil
first_job = #jobs + 1
local handle = Client.openContentAsync("n", "c", function(text) result = text end)
jobs[first_job]()
handle:cancel()
Assert.is_true(verification_cancelled)
before = #requests
verification_done(true)
Assert.eq(#requests, before, "取消后迟到的验证结果不能重开章节")
Assert.is_nil(result)

verification_done, message = nil, nil
first_job = #jobs + 1
Client.openContentAsync("n", "c", function(_text, err) message = err end)
jobs[first_job]()
verification_done(false, "verification cancelled")
Assert.eq(message, "verification cancelled")

-- check >= 3 且重取仍被门控：即使有正文也不收下，只报错、不反复弹二维码。
check, result, message, verification_done = 3, nil, nil, nil
first_job = #jobs + 1
Client.openContentAsync("n", "c", function(_text, err) message = err end)
jobs[first_job]()
verification_done(true)
verification_done = nil
jobs[first_job + 1]()
Assert.is_nil(verification_done, "验证后仍被拦截只报错，不反复弹二维码")
Assert.eq(message, Client.VERIFY_REQUIRED)

-- 后台预取遇验证不回正文，避免未验证章进缓存。
result, message, result_kind = nil, nil, nil
Client.contentAsync("n", "c", function(text, err, kind) result, message, result_kind = text, err, kind end)
jobs[#jobs]()
Assert.is_nil(result)
Assert.eq(message, Client.VERIFY_REQUIRED)
Assert.eq(result_kind, "verify")

-- 普通登录请求与 readCheck 回包轮换会话；后续每章复用，不要求用户重扫。
check, read_check_code, verification_done = 1, 200, nil
local saved_cookie = settings.cookie
get_cookies = { "PHPSESSID=bootstrap; Path=/; HttpOnly" }
Client.chaptersAsync("n", function() end)
get_cookies = { "PHPSESSID=anonymous-init; Path=/" }
post_cookies = { "PHPSESSID=verified; Path=/; HttpOnly", "reader_pass=ok; Path=/" }
Client.readCheckAsync("proof", function(ok) verified = ok end)
Assert.is_true(verified)
Assert.matches(posts[#posts].headers.Cookie, "PHPSESSID=bootstrap", "验证沿用登录请求建立的会话")
Assert.eq(settings.cookie, saved_cookie, "会话轮换不修改保存的登录凭据")
get_cookies, post_cookies = nil, nil
first_job = #jobs + 1
Client.openContentAsync("n", "next", function(text, err) result, message = text, err end)
Assert.matches(requests[#requests].headers.Cookie, "PHPSESSID=verified")
Assert.matches(requests[#requests].headers.Cookie, "reader_pass=ok")
jobs[first_job]()
Assert.is_nil(verification_done)
Assert.eq(result, "chapter text")

-- 验证前发出的预取回包不能把已验证的新会话覆盖回旧会话。
defer_content = true
get_cookies = { "PHPSESSID=stale-prefetch; Path=/" }
Client.contentAsync("n", "prefetch", function() end)
defer_content, get_cookies = false, nil
post_cookies = { "PHPSESSID=verified-new; Path=/" }
Client.readCheckAsync("new-proof", function(ok) verified = ok end)
post_cookies = nil
delayed_content()
jobs[#jobs]()
Client.contentAsync("n", "next", function() end)
Assert.matches(requests[#requests].headers.Cookie, "PHPSESSID=verified%-new",
    "旧请求迟到时不得回滚扫码后建立的会话")
jobs[#jobs]()

get_cookies = { "PHPSESSID=anonymous; Path=/" }
Client.detailAsync("n", function() end)
get_cookies = nil
renewed_token = "newer"
Client.renewAsync(function(ok) renewed = ok end)
Assert.is_true(renewed)
Client.contentAsync("n", "next", function() end)
Assert.matches(requests[#requests].headers.Cookie, "PHPSESSID=verified%-new",
    "匿名请求不能覆盖已验证会话，token 续期也要保留它")
Assert.eq(requests[#requests].headers.token, "newer")
jobs[#jobs]()

for _idx, age in ipairs({ "060", "-1", "0" }) do
    get_cookies = { "reader_pass=value; Max-Age=" .. age .. "; Path=/" }
    Client.contentAsync("n", "next", function() end)
    jobs[#jobs]()
    get_cookies = nil
    Client.contentAsync("n", "next", function() end)
    Assert.eq(requests[#requests].headers.Cookie:find("reader_pass=", 1, true) ~= nil, tonumber(age) > 0,
        "仅保留正 Max-Age 会话 Cookie")
    jobs[#jobs]()
end
settings.cookie = "PHPSESSID=another-account; moon_token=other"
Client.contentAsync("n", "next", function() end)
Assert.eq(requests[#requests].headers.Cookie, "PHPSESSID=another-account", "换号不能继承旧验证 Cookie")
Assert.eq(requests[#requests].headers.token, "other")
jobs[#jobs]()
