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
local signed
package.preload["ffi/sha2"] = function()
    return { md5 = function(value) signed = value; return "signature" end }
end
package.preload["source.changpei.mapper"] = function()
    return {
        content = function(wire)
            local level = wire.data.check
            if level > 1 then return "chapter text", nil, "verify", level end
            return "chapter text"
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
        decode = function() return { [3] = "new" } end,
    }
end
package.preload["http.request"] = function()
    return {
        get = function(url, options, callback)
            requests[#requests + 1] = { url = url, headers = options.headers }
            local body = Json.encode({ code = 200, data = url:find("/system/init", 1, true)
                and { timestamp = 123456 } or { check = check } })
            callback(body)
            return { cancel = function() end }
        end,
        post = function(_url, _body, options, callback)
            posts[#posts + 1] = { url = _url, body = _body, headers = options.headers }
            if _url:find("/novel/readCheck", 1, true) then
                callback(Json.encode({ code = 200, data = { code = read_check_code } }))
            else
                callback("grpc-body", nil, {})
            end
            return { cancel = function() end }
        end,
        header = function() return "0" end,
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
-- check == 2：官网验完只关弹窗，沿用已解密正文，不重拉。
check, result, message, verification_done = 2, nil, nil, nil
local first_job = #jobs + 1
local before = #requests
Client.openContentAsync("n", "c", function(text, err) result, message = text, err end)
jobs[first_job]()
Assert.not_nil(verification_done, "用户开章遇验证才打开扫码页")
Assert.is_nil(message, "等待验证时不提前结束开书")
verification_done(true)
Assert.eq(#requests, before + 1, "check < 3 验完不重取章节")
Assert.eq(#jobs, first_job, "check < 3 验完不再跑解密任务")
Assert.eq(result, "chapter text", "验完直接用开章时已解密的正文")
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
