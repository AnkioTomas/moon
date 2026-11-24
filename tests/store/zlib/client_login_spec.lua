--[[--
zlib 登录：先走 /rpc.php（会话在 response），被拒再试 /eapi/user/login，只发到一个镜像。

@module tests.store.zlib.client_login_spec
--]]

local Assert = require("support.assert")

package.loaded["json"] = nil
package.preload["json"] = function()
    return { decode = require("support.json_stub").decode }
end

local replies, urls, sent = {}, {}, {}
package.loaded["http.request"] = nil
package.preload["http.request"] = function()
    return {
        ok = function(code) return code >= 200 and code < 300 end,
        header = function() end,
        request = function(opts, cb)
            urls[#urls + 1] = opts.url
            sent[#urls] = opts.headers
            cb({ code = 200, body = replies[#urls] })
            return { cancel = function() end }
        end,
    }
end
package.loaded["http.cache"] = nil
package.preload["http.cache"] = function()
    return { key = function() return "k" end, fetch = function(_key, _ttl, load, cb) return load(cb) or { cancel = function() end } end }
end
package.loaded["utils.settings"] = nil
package.preload["utils.settings"] = function() return { saveSource = function() end } end

package.loaded["store.zlib.client"] = nil
local Client = require("store.zlib.client")

local function login(first, second)
    replies, urls = { first, second }, {}
    local cfg = { email = "a@b.c", password = "p", base_url = "https://m.example" }
    local ok, err
    Client.new(cfg):loginAsync(function(o, e) ok, err = o, e end)
    return ok, err, cfg
end

local ok, _err, cfg = login('{"errors":[],"response":{"user_id":21,"user_key":"k1"}}')
Assert.is_true(ok)
Assert.eq(cfg.user_id, "21")
Assert.eq(cfg.user_key, "k1")
Assert.eq(#urls, 1)
Assert.eq(urls[1], "https://m.example/rpc.php")

ok, _err, cfg = login('{"response":{"validationError":true,"message":"Authorization failed"}}',
    '{"success":1,"user":{"id":7,"remix_userkey":"k2"}}')
Assert.is_true(ok, "rpc.php 被拒后回退 eapi")
Assert.eq(cfg.user_id, "7")
Assert.eq(urls[2], "https://m.example/eapi/user/login")

local err
ok, err = login('{"response":{"validationError":true,"message":"Incorrect email or password"}}', '{"success":0}')
Assert.is_nil(ok)
Assert.eq(err, "Incorrect email or password")

ok, err = login('{"errors":["Too many logins #2. Try again later."]}')
Assert.is_nil(ok)
Assert.eq(#urls, 1, "被限流不再试第二个入口")

-- eAPI 携带 source: android，/rpc.php 不带；不再发已废弃的 Basic 认证
local function loginAt(base, first, second)
    replies, urls, sent = { first, second }, {}, {}
    Client.new({ email = "a", password = "p", base_url = base }):loginAsync(function() end)
end
loginAt("https://iread.ink", '{"response":{"user_id":1,"user_key":"k"}}')
Assert.is_nil(sent[1].Authorization)
Assert.is_nil(sent[1].source)
loginAt("https://m.example", '{"response":{"validationError":true,"message":"fail"}}',
    '{"success":1,"user":{"id":9,"remix_user_key":"legacy"}}')
Assert.eq(sent[2].source, "android")
Assert.eq(sent[2].Accept, "application/json")

return true
