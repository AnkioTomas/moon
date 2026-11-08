--[[--
潇湘账号失效、换号竞态、写后确认和多阶段取消。

@module tests.source.xiaoxiang.client_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local A = require("support.assert")
package.loaded["json"] = require("support.json_stub")
local cfg = { cookie = "csrfToken=x%26; ywguid=42" }
package.loaded["utils.settings"] = { getSource = function() return cfg end }
local network, pending, posts, cancelled, shelf = "sync", nil, 0, false, {}
local function json(value) return require("json").encode(value) end
package.loaded["http.request"] = {
    get = function(url, opts, cb)
        A.eq(opts.cache_ttl, 0)
        if url:find("/user/auth/personal", 1, true) then
            if network == "wait" then pending = cb
            elseif network == "failure" then cb(nil, "timeout")
            elseif network == "expired" then cb('{"code":0,"data":{"isLogin":0}}')
            else cb('{"code":0,"data":{"isLogin":1,"user":{"guid":42}}}') end
        else
            if network == "shelf-wait" then pending = cb
            else cb(json({ code = 0, data = { data = shelf, pageCount = 1 } })) end
        end
        return { cancel = function() cancelled = true end }
    end,
    post = function(url, _body, opts, cb)
        posts = posts + 1
        A.matches(url, "_csrfToken=x%%2526")
        A.eq(opts.cache_ttl, 0)
        cb('{"code":0,"data":null}')
        return { cancel = function() end }
    end,
}
package.loaded["source.xiaoxiang.client"] = nil
local C = require("source.xiaoxiang.client")
local Auth = require("source.auth")
Auth.reset()
local info, err, result
C.userAsync(cfg.cookie, function(value) info = value end)
A.eq(info.id, "42")
network = "failure"
C.shelfAsync(function(value, reason) result, err = value, reason end)
A.is_nil(result)
A.eq(err, "timeout")
A.is_false(Auth.expired("xiaoxiang"), "暂时网络失败保留登录")
network = "expired"
C.shelfAsync(function(value, reason) result, err = value, reason end)
A.is_true(Auth.expired("xiaoxiang"))
A.eq(posts, 0)
Auth.reset()
network = "wait"
C.shelfAsync(function(value, reason) result, err = value, reason end)
cfg.cookie = "csrfToken=new; ywguid=43"
pending('{"code":0,"data":{"isLogin":0}}')
A.is_false(Auth.expired("xiaoxiang"), "旧请求不能注销新账号")
A.eq(err, "账号已变化，请重新登录")
cfg.cookie = "csrfToken=x%26; ywguid=42"
network, cancelled, info = "wait", false, nil
local user = C.userAsync(cfg.cookie, function(value) info = value end)
user.cancel()
pending('{"code":0,"data":{"isLogin":1,"user":{"guid":42}}}')
A.is_nil(info)
A.is_true(cancelled)
network = "sync"
shelf = { { bookid = "123", ccid = "77", restype = 1, groupId = -100 } }
C.shelfAddAsync("123", function(value, reason) result, err = value, reason end)
A.is_true(result ~= nil)
C.shelfRemoveAsync("123", function(value, reason) result, err = value, reason end)
A.is_nil(result)
A.eq(err, "潇湘远端状态未更新，请稍后重试")
C.progressAsync("123", "77", function(value) result = value end)
A.is_true(result ~= nil)
C.progressAsync("123", "78", function(value, reason) result, err = value, reason end)
A.is_nil(result)
A.eq(err, "潇湘远端状态未更新，请稍后重试")
shelf = {}
C.shelfRemoveAsync("123", function(value) result = value end)
A.is_true(result ~= nil)
network, cancelled, result = "shelf-wait", false, nil
local writing = C.shelfRemoveAsync("123", function(value) result = value end)
writing.cancel()
A.is_true(cancelled, "同步 POST 后取消实际回读请求")
pending('{"code":0,"data":{"data":[],"pageCount":1}}')
A.is_nil(result)
network = "sync"
shelf = { { restype = 1, groupId = -100, title = "缺身份" } }
C.shelfAsync(function(value, reason) result, err = value, reason end)
A.is_nil(result)
A.eq(err, "响应无效", "坏书架行不能变成身份为 nil 的书")
