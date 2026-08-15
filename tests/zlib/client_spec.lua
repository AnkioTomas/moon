--[[--
Z-Library client 离线用例：镜像选择、30x 手动跟随、bot 挑战、故障转移、会话。

@module tests.zlib.client_spec
--]]

local Assert = require("support.assert")

-- 队列式假 http.request：每个请求出队一个响应；响应可为
--   { code = N, body = "...", headers = {...} } 或 { err = { error = { code = -5, message = "..." } } }
local captured = {}
local queue = {}
local function enqueue(res) queue[#queue + 1] = res end

local saved
package.preload["json"] = function()
    return { decode = require("support.json_stub").decode }
end
package.preload["http.request"] = function()
    return {
        ok = function(code) return tonumber(code) >= 200 and tonumber(code) < 300 end,
        header = function(res, name)
            local headers = res and res.headers
            if not headers then return nil end
            return headers[name] or headers[name:lower()]
        end,
        request = function(opts, cb)
            captured[#captured + 1] = opts
            local res = table.remove(queue, 1) or { code = 200, body = '{"success":1}' }
            if res.err then
                cb(res.err, "network error")
            else
                cb(res, nil)
            end
            return { cancel = function() end }
        end,
    }
end
package.preload["utils.settings"] = function()
    return { saveSource = function(id, cfg) saved = { id = id, cfg = cfg } end }
end
package.loaded["http.request"] = nil
package.loaded["utils.settings"] = nil
package.loaded["json"] = nil
package.loaded["zlib.client"] = nil

local Client
-- 钉住的镜像是模块级状态：fresh 重 require 清状态，避免用例间串味
local function fresh(cfg)
    package.loaded["zlib.client"] = nil
    Client = require("zlib.client")
    return Client.new(cfg or { email = "me@example.com", password = "secret" })
end

local SEED1 = "https://z-library.sk"
local SEED2 = "https://thai-books.sk"

-- 默认走第一个种子镜像，无 Basic 门禁
do
    captured = {}
    queue = {}
    enqueue({ code = 200, body = '{"success":1}' })
    local client = fresh()
    local wire
    client:listPopularAsync(function(v) wire = v end)
    Assert.not_nil(wire)
    Assert.eq(captured[1].url, SEED1 .. "/eapi/book/most-popular")
    Assert.is_nil(captured[1].auth_username)
    Assert.eq(captured[1].method, "GET")
end

-- 用户配置的镜像优先于种子
do
    captured = {}
    queue = {}
    enqueue({ code = 200, body = '{"success":1}' })
    local client = fresh({ base_url = "https://my-mirror.example.com/" })
    local wire
    client:listPopularAsync(function(v) wire = v end)
    Assert.not_nil(wire)
    Assert.eq(captured[1].url, "https://my-mirror.example.com/eapi/book/most-popular")
end

-- 传输失败 → 故障转移到下一个种子；成功的镜像被钉住（后续请求直接用它）
do
    captured = {}
    queue = {}
    enqueue({ err = { error = { code = -5, message = "Connect timed out after 30 secs" } } })
    enqueue({ code = 200, body = '{"success":1}' })
    local client = fresh()
    local wire
    client:listPopularAsync(function(v) wire = v end)
    Assert.not_nil(wire)
    Assert.eq(captured[1].url, SEED1 .. "/eapi/book/most-popular")
    Assert.eq(captured[2].url, SEED2 .. "/eapi/book/most-popular")

    -- 钉住生效：同一模块内的新客户端直接用成功的镜像
    enqueue({ code = 200, body = '{"success":1}' })
    local client2 = Client.new({})
    client2:listPopularAsync(function(v) wire = v end)
    Assert.eq(captured[3].url, SEED2 .. "/eapi/book/most-popular")
end

-- 全部候选都失败：报最后的传输错误
do
    captured = {}
    queue = {}
    for _ = 1, 3 do
        enqueue({ err = { error = { code = -5, message = "Connect timed out" } } })
    end
    local client = fresh()
    local ok, err
    client:listPopularAsync(function(v, e) ok, err = v, e end)
    Assert.is_nil(ok)
    Assert.eq(err, "连接超时，请检查网络")
end

-- 302 跨主机：镜像迁移，POST 在新 origin 上原样重发（不退化成 GET），并钉住新镜像
do
    captured = {}
    queue = {}
    enqueue({ code = 302, headers = { location = "https://z-lib.fm/eapi/user/login" } })
    enqueue({ code = 200, body = '{"success":1,"user":{"id":42,"remix_userkey":"key42"}}' })
    local client = fresh()
    local ok
    client:loginAsync(function(v) ok = v end)
    Assert.is_true(ok)
    Assert.len(captured, 2)
    Assert.eq(captured[2].url, "https://z-lib.fm/eapi/user/login")
    Assert.eq(captured[2].method, "POST") -- 镜像迁移保持 POST
    Assert.not_nil(captured[2].body)
    Assert.eq(client.user_id, "42")
    Assert.eq(client.user_key, "key42")
    Assert.eq(saved.id, "zlib")
    Assert.eq(saved.cfg.user_key, "key42")
end

-- 307 站内跳转：保持方法与 body，跟随 Location
do
    captured = {}
    queue = {}
    enqueue({ code = 307, headers = { location = "/eapi/book/search2" } })
    enqueue({ code = 200, body = '{"success":1,"books":[],"pagination":{"total_items":0}}' })
    local client = fresh()
    local wire
    client:searchAsync("Lua", 1, 12, function(data) wire = data end)
    Assert.not_nil(wire)
    Assert.eq(captured[2].url, SEED1 .. "/eapi/book/search2")
    Assert.eq(captured[2].method, "POST")
    Assert.matches(captured[2].body, "message=Lua")
end

-- 301 站内跳转 POST：转 GET 丢 body
do
    captured = {}
    queue = {}
    enqueue({ code = 301, headers = { location = "/eapi/info/ok2" } })
    enqueue({ code = 200, body = '{"success":1}' })
    local client = fresh()
    local wire
    client:searchAsync("x", 1, 12, function(data) wire = data end)
    Assert.not_nil(wire)
    Assert.eq(captured[2].method, "GET")
    Assert.is_nil(captured[2].body)
end

-- 重定向循环：报「重定向过多」而不是无限转
do
    captured = {}
    queue = {}
    for _ = 1, 8 do
        enqueue({ code = 302, headers = { location = "/eapi/loop" } })
    end
    local client = fresh()
    local ok, err
    client:listPopularAsync(function(v, e) ok, err = v, e end)
    Assert.is_nil(ok)
    Assert.eq(err, "重定向过多")
end

-- bot 挑战页：换下一个镜像
do
    captured = {}
    queue = {}
    enqueue({ code = 513, body = '<html><head>Just a moment...</head><script>__cf_chl</script></html>' })
    enqueue({ code = 200, body = '{"success":1}' })
    local client = fresh()
    local wire
    client:listPopularAsync(function(v) wire = v end)
    Assert.not_nil(wire)
    Assert.eq(captured[2].url, SEED2 .. "/eapi/book/most-popular")
end

-- 200 但内容是挑战页（WAF 用 200 回拦截页）：同样换镜像
do
    captured = {}
    queue = {}
    enqueue({ code = 200, body = '<html>Verifying your browser</html>' })
    enqueue({ code = 200, body = '{"success":1}' })
    local client = fresh()
    local wire
    client:listPopularAsync(function(v) wire = v end)
    Assert.not_nil(wire)
    Assert.len(captured, 2)
end

-- 登录失败：success=0 时错误文案透传
do
    captured = {}
    queue = {}
    enqueue({ code = 200, body = '{"success":0,"error":{"message":"Incorrect email or password"}}' })
    local client = fresh()
    local ok, err
    client:loginAsync(function(v, e) ok, err = v, e end)
    Assert.is_nil(ok)
    Assert.eq(err, "Incorrect email or password")
end

-- 未填凭据：不发请求直接报错
do
    captured = {}
    queue = {}
    local client = fresh({ email = "", password = "" })
    local ok, err
    client:loginAsync(function(v, e) ok, err = v, e end)
    Assert.is_nil(ok)
    Assert.matches(err, "邮箱")
    Assert.len(captured, 0)
end

-- 搜索请求体：表单字段编码与分页
do
    captured = {}
    queue = {}
    enqueue({ code = 200, body = '{"success":1,"books":[],"pagination":{"total_items":5}}' })
    local client = fresh()
    local wire
    client:searchAsync("Lua 书", 2, 12, function(data) wire = data end)
    Assert.eq(wire.pagination.total_items, 5)
    Assert.eq(captured[1].method, "POST")
    Assert.matches(captured[1].body, "message=Lua%%20%%E4%%B9%%A6")
    Assert.matches(captured[1].body, "page=2")
    Assert.matches(captured[1].body, "limit=12")
end

-- 下载链接：会话 cookie + allowDownload=false 拦截
do
    captured = {}
    queue = {}
    enqueue({ code = 200, body = '{"success":1,"file":{"downloadLink":"https://cdn.example/book.epub"}}' })
    local client = fresh({ user_id = "42", user_key = "key42" })
    local link
    client:downloadLinkAsync("1", "abc", function(v) link = v end)
    Assert.eq(link, "https://cdn.example/book.epub")
    Assert.matches(captured[1].headers.Cookie, "remix_userid=42")

    enqueue({ code = 200, body = '{"success":1,"file":{"allowDownload":false}}' })
    local ok, err
    client:downloadLinkAsync("1", "abc", function(v, e) ok, err = v, e end)
    Assert.is_nil(ok)
    Assert.matches(err, "限额")
end

for _, name in ipairs({ "json", "http.request", "utils.settings" }) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
package.loaded["zlib.client"] = nil
