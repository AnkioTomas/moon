--[[-- 长佩 HTTP 续期竞态、多阶段取消及进度确认。 @module tests.source.changpei.async_spec --]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

package.preload["json"] = function() return require("support.json_stub") end
local Assert = require("support.assert")
local Json = require("support.json_stub")
local cfg = { cookie = "PHPSESSID=old; _c_n_=device; moon_refresh=refresh; moon_token=old" }
local late, expired, cancelled, phase, history_uid = nil, false, false, "renew", "123"
local user_data
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end, saveSource = function() end }
end
package.preload["source.auth"] = function()
    return { ok = function() end, expire = function(_id, msg) expired = true; return msg end }
end
package.preload["source.changpei.qrlogin"] = function()
    return { frame = function() return "request" end, decode = function() return { [3] = "new-token" } end }
end
package.preload["http.request"] = function()
    return {
        get = function(url, opts, cb)
            Assert.eq(opts.cache_ttl, 0)
            if phase == "retry" then
                if opts.headers.token == "old" then cb(Json.encode({ code = 9996 }))
                else late = function() cb(Json.encode({ code = 200, data = { list = {} } })) end end
            elseif phase == "read" then
                if url:find("chapterGetInfo", 1, true) then
                    cb(Json.encode({ code = 200, data = { check = 1, chapterInfo = {} } }))
                else
                    cb(Json.encode({ code = 200, data = { list = {
                        { list = { { novel_id = 1, latest_read_cid = history_uid } } },
                    } } }))
                end
            elseif phase == "user" then
                cb(Json.encode({ code = 200, data = user_data }))
            elseif phase == "user_error" then
                cb(nil, "network")
            elseif phase == "post" then
                cb(Json.encode({ code = 200, data = { timestamp = 1 } }))
            else late = function() cb(Json.encode({ code = 200, data = {} })) end end
            return { cancel = function() cancelled = true end }
        end,
        post = function(_url, _body, _opts, cb)
            if phase == "retry" then cb("grpc", nil, {})
            else late = cb end
            return { cancel = function() cancelled = true end }
        end,
        header = function() return "0" end,
    }
end
local Client = require("source.changpei.client")
local ok, err
Client.renewAsync(function(value, reason) ok, err = value, reason end)
cfg.cookie = "PHPSESSID=another"
late("grpc", nil, {})
Assert.is_false(ok)
Assert.matches(err, "账号已变化")
Assert.eq(cfg.cookie, "PHPSESSID=another")

cfg.cookie = "PHPSESSID=old; _c_n_=device; moon_refresh=refresh; moon_token=old"
Client.renewAsync(function(value, reason) ok, err = value, reason end)
late(nil, "network", {})
Assert.is_false(ok)
Assert.eq(err, "network")
Assert.is_false(expired, "暂时网络故障不注销账号")

phase, cancelled = "retry", false
local called = false
local handle = Client.chaptersAsync("1", function() called = true end)
handle.cancel()
Assert.is_true(cancelled)
late()
Assert.is_false(called, "同步续期不能覆盖重发请求的句柄")

phase = "read"
Client.markReadAsync("123", function(value, reason) ok, err = value, reason end)
Assert.is_true(ok)
history_uid = "999"
Client.markReadAsync("123", function(value, reason) ok, err = value, reason end)
Assert.is_nil(ok)
Assert.eq(err, "长佩阅读进度未确认")

phase, user_data = "user", { info = { show_uid = 111, nick_name = "测试" }, verify = true }
local account
Client.userAsync(cfg.cookie, function(value, reason) account, err = value, reason end)
Assert.eq(account.uid, 111, "旧 JSON 接口的稳定身份在 data.info.show_uid，与官网 gRPC uid 一致")
Assert.is_nil(account.nick_name, "登录边界只保留身份，不传播个人资料")
user_data = { uid = 111, info = { show_uid = 0 } }
Client.userAsync(cfg.cookie, function(value, reason) account, err = value, reason end)
Assert.is_nil(account)
Assert.eq(err, "长佩账号标识缺失", "坏身份仍须拒绝，不能删掉检查绕过")
user_data = {}
Client.userAsync(cfg.cookie, function(value, reason) account, err = value, reason end)
Assert.is_nil(account)
Assert.eq(err, "长佩账号标识缺失")
phase = "user_error"
Client.userAsync(cfg.cookie, function(value, reason) account, err = value, reason end)
Assert.is_nil(account)
Assert.eq(err, "network")

phase = "post"
Client.shelfAddAsync("1", function(value, reason) ok, err = value, reason end)
cfg.cookie = "PHPSESSID=another"
late(Json.encode({ code = 200, data = {} }), nil, {})
Assert.is_nil(ok)
Assert.matches(err, "账号已变化", "旧书架请求不能被新账号当成同步成功")

local source = require("source.changpei").new()
Client.historyAsync = function(cb)
    late = cb
    return { cancel = function() cancelled = true end }
end
called, cancelled = false, false
handle = source:getProgressAsync({ stable_id = "1" }, function() called = true end)
handle.cancel()
Assert.is_true(cancelled, "取消进度拉取必须停止仍在执行的历史请求")
late({ data = { list = {} } })
Assert.is_false(called)

Client.historyAsync = function(cb)
    cb({ data = { list = { { list = { { novel_id = 1, latest_read_cid = "123" } } } } } })
    return { cancel = function() error("finished history request cancelled") end }
end
source.loadTocAsync = function(_self, _identity, cb)
    late = cb
    return { cancel = function() cancelled = true end }
end
called, cancelled = false, false
handle = source:getProgressAsync({ stable_id = "1" }, function() called = true end)
handle.cancel()
Assert.is_true(cancelled, "同步历史回调不能覆盖后续目录请求的取消句柄")
late({})
Assert.is_false(called)
