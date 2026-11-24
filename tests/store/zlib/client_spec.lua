--[[--
zlib 镜像监测、反机器人拦截判定、故障转移与凭据安全用例。

@module tests.store.zlib.client_spec
--]]

local Assert = require("support.assert")

package.loaded["json"] = nil
package.preload["json"] = function()
    return { decode = require("support.json_stub").decode }
end

local handler
local download_handler
local urls, req_opts = {}, {}
package.loaded["http.request"] = nil
package.preload["http.request"] = function()
    return {
        ok = function(code) return code >= 200 and code < 300 end,
        header = function(res, name)
            local h = res and res.headers
            if not h then return nil end
            local lower = name:lower()
            for k, v in pairs(h) do
                if type(k) == "string" and k:lower() == lower then return v end
            end
        end,
        headerAll = function(res, name)
            local h = res and res.headers
            if not h then return {} end
            local lower, out = name:lower(), {}
            for k, v in pairs(h) do
                if type(k) == "string" and k:lower() == lower then
                    if type(v) == "table" then
                        for _idx, item in ipairs(v) do out[#out + 1] = item end
                    else
                        out[#out + 1] = v
                    end
                end
            end
            return out
        end,
        request = function(opts, cb)
            urls[#urls + 1] = opts.url
            req_opts[#req_opts + 1] = opts
            cb(handler(opts))
            return { cancel = function() end }
        end,
        download = function(opts, dest, cb)
            download_handler(opts, dest, cb)
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

local function freshClient(cfg)
    urls, req_opts = {}, {}
    package.loaded["store.zlib.client"] = nil
    local Client = require("store.zlib.client")
    local merged = cfg or {
        base_url = "https://bad.example",
        mirrors = { "https://m1.example", "https://m2.example", "https://m3.example" },
    }
    return Client.new(merged)
end

-- 1. 重定向环：无 __diamwall 判为重定向过多并换镜像
do
    handler = function(opts)
        if opts.url:find("^https://bad%.example") then
            return { code = 302, headers = { location = opts.url } }
        end
        return { code = 200, headers = { ["content-type"] = "application/json" }, body = '{"success":1}' }
    end
    local data, err
    freshClient():_jsonAsync("GET", "/eapi/info/ok", {}, function(d, e) data, err = d, e end)
    Assert.is_nil(err)
    Assert.eq(data.success, 1)
    Assert.eq(urls[1], "https://bad.example/eapi/info/ok")
    Assert.is_true(#urls >= 2)
    Assert.is_nil(urls[#urls]:find("bad.example", 1, true), "重定向环后应换镜像")
end

-- 2. DiamWall 状态码 513/517：归类为反机器人拦截（而非普通 5xx）并故障转移
for _idx, code in ipairs({ 513, 517 }) do
    handler = function()
        return {
            code = code,
            headers = { ["content-type"] = "text/html" },
            body = "<html><title>Verifying your browser | DiamWall</title></html>",
        }
    end
    local data, err
    freshClient():_jsonAsync("GET", "/eapi/x", { serial = true }, function(d, e) data, err = d, e end)
    Assert.is_nil(data)
    Assert.matches(err, "拒绝自动访问")
    Assert.eq(#urls, 3)
end

-- 3. DiamWall 200 HTML <title> 拦截页：故障转移到健康镜像
do
    handler = function(opts)
        if opts.url:find("^https://bad%.example") then
            return {
                code = 200,
                headers = { ["content-type"] = "text/html; charset=utf-8" },
                body = "<html><head><title>Verifying your browser | DiamWall</title></head></html>",
            }
        end
        return { code = 200, headers = { ["content-type"] = "application/json" }, body = '{"success":1}' }
    end
    local data, err
    freshClient():_jsonAsync("GET", "/eapi/x", { serial = true }, function(d, e) data, err = d, e end)
    Assert.is_nil(err)
    Assert.eq(data.success, 1)
    Assert.eq(#urls, 2)
end

-- 4. 关键防误判：application/json 响应正文含 DiamWall / Just a moment / <p> 标签绝不判为拦截
do
    handler = function()
        return {
            code = 200,
            headers = { ["content-type"] = "application/json; charset=utf-8" },
            body = '{"success":1,"books":[{"id":1,"hash":"h","title":"Defeating DiamWall","description":"<p>Just a moment</p><title>DiamWall</title>"}]}',
        }
    end
    local data, err
    freshClient({ base_url = "https://good.example" }):searchAsync("diamwall", 1, 10, function(d, e) data, err = d, e end)
    Assert.is_nil(err)
    Assert.eq(data.success, 1)
    Assert.eq(data.books[1].title, "Defeating DiamWall")
    Assert.eq(req_opts[1].headers.source, "android")
end

-- 5. __diamwall Cookie 规则：正常 200 JSON 带 __diamwall 是放行凭证（健康）；自指 307 带 __diamwall 才是反机器人拦截
do
    handler = function()
        return {
            code = 200,
            headers = {
                ["content-type"] = "application/json",
                ["set-cookie"] = { "__diamwall=cleared; Path=/" },
            },
            body = '{"success":1}',
        }
    end
    local data, err
    freshClient({ base_url = "https://good.example" }):_jsonAsync("GET", "/eapi/x", { serial = true }, function(d, e) data, err = d, e end)
    Assert.is_nil(err)
    Assert.eq(data.success, 1)
    Assert.eq(#urls, 1, "放行凭证 __diamwall 不应误报")
end

do
    handler = function()
        return {
            code = 307,
            headers = {
                location = "/eapi/x",
                ["set-cookie"] = "__diamwall=challenge; Path=/",
            },
            body = "",
        }
    end
    local data, err
    freshClient():_jsonAsync("GET", "/eapi/x", { serial = true }, function(d, e) data, err = d, e end)
    Assert.is_nil(data)
    Assert.matches(err, "拒绝自动访问")
end

-- 6. Z-Library JS 挑战页（HTTP 503 + 40 位 hex c_token）：优先于 5xx 判为挑战并故障转移
do
    handler = function()
        return {
            code = 503,
            headers = { ["content-type"] = "text/html" },
            body = "<html><body><script>var a=['6f1e2d3c4b5a69788796a5b4c3d2e1f009182736','c_token=','array'];</script></body></html>",
        }
    end
    local data, err
    freshClient():_jsonAsync("GET", "/eapi/x", { serial = true }, function(d, e) data, err = d, e end)
    Assert.is_nil(data)
    Assert.matches(err, "拒绝自动访问")
end

-- 7. 非 JSON 200 HTML 与非信封 403 HTML：不钉死坏镜像，自动换下一个镜像
do
    handler = function(opts)
        if opts.url:find("^https://bad%.example") then
            return {
                code = 200,
                headers = { ["content-type"] = "text/html" },
                body = "<html><title>Search</title><body>Defeating DiamWall, 2nd ed.</body></html>",
            }
        end
        return { code = 200, headers = { ["content-type"] = "application/json" }, body = '{"success":1}' }
    end
    local data, err
    freshClient():_jsonAsync("GET", "/eapi/x", { serial = true }, function(d, e) data, err = d, e end)
    Assert.is_nil(err)
    Assert.eq(data.success, 1)
    Assert.eq(#urls, 2, "200 HTML 应故障转移而不是直接失败")
end

do
    handler = function(opts)
        if opts.url:find("^https://bad%.example") then
            return { code = 403, headers = { ["content-type"] = "text/html" }, body = "<html><body>403 Forbidden</body></html>" }
        end
        return { code = 200, headers = { ["content-type"] = "application/json" }, body = '{"success":1}' }
    end
    local data, err
    freshClient():_jsonAsync("GET", "/eapi/x", { serial = true }, function(d, e) data, err = d, e end)
    Assert.is_nil(err)
    Assert.eq(data.success, 1)
    Assert.eq(#urls, 2, "403 HTML 应故障转移而不是把坏镜像钉死")
end

-- 8. 非 2xx 但带合法 eAPI 错误信封：保留服务端业务错误文案，不再盲目故障转移
do
    handler = function()
        return {
            code = 403,
            headers = { ["content-type"] = "application/json" },
            body = '{"success":0,"error":"Daily download limit reached"}',
        }
    end
    local data, err
    freshClient({ base_url = "https://good.example" }):_jsonAsync("GET", "/eapi/x", { serial = true }, function(d, e) data, err = d, e end)
    Assert.is_nil(data)
    Assert.eq(err, "Daily download limit reached")
    Assert.eq(#urls, 1)
end

-- 9. eAPI 会话头与 HTTPS->HTTP 降级重定向剥离凭据
do
    handler = function(opts)
        if opts.url == "https://good.example/eapi/book/search" then
            return { code = 302, headers = { location = "http://good.example/eapi/book/search" } }
        end
        return { code = 200, headers = { ["content-type"] = "application/json" }, body = '{"success":1,"books":[]}' }
    end
    local c = freshClient({ base_url = "https://good.example", user_id = "123", user_key = "secret" })
    c:_jsonAsync("POST", "/eapi/book/search", { session = true, serial = true, form = { message = "lua" } }, function() end)
    Assert.eq(req_opts[1].headers["remix-userid"], "123")
    Assert.eq(req_opts[1].headers["remix-userkey"], "secret")
    Assert.is_true(req_opts[1].jar ~= nil)
    Assert.eq(req_opts[2].method, "POST")
    Assert.is_nil(req_opts[2].headers["remix-userid"], "降级到 HTTP 必须剥离 remix-userid")
    Assert.is_nil(req_opts[2].headers["remix-userkey"], "降级到 HTTP 必须剥离 remix-userkey")
    Assert.is_nil(req_opts[2].jar, "降级到 HTTP 必须丢弃 Cookie 罐")
end

-- 9b. 同主机 302 POST -> GET 必须丢弃 body 和 Content-Type
do
    handler = function(opts)
        if opts.url == "https://good.example/eapi/book/search" then
            return { code = 302, headers = { location = "/eapi/book/search2" } }
        end
        return { code = 200, headers = { ["content-type"] = "application/json" }, body = '{"success":1,"books":[]}' }
    end
    local c = freshClient({ base_url = "https://good.example" })
    c:_jsonAsync("POST", "/eapi/book/search", { serial = true, form = { message = "lua" } }, function() end)
    Assert.eq(req_opts[2].method, "GET")
    Assert.is_nil(req_opts[2].body, "站内 302 转 GET 必须清空 body")
    Assert.is_nil(req_opts[2].headers["Content-Type"], "站内 302 转 GET 必须去掉 Content-Type")
end

-- 10. 下载：Invalid credentials 触发一次自动重登；外域 CDN 不带账号 Cookie
do
    local step = 0
    local dl_headers
    handler = function(opts)
        step = step + 1
        if step == 1 then
            return { code = 400, headers = { ["content-type"] = "application/json" }, body = '{"success":0,"error":"Invalid credentials"}' }
        elseif step == 2 then
            return { code = 200, headers = { ["content-type"] = "application/json" }, body = '{"errors":[],"response":{"user_id":9,"user_key":"fresh"}}' }
        end
        return {
            code = 200,
            headers = { ["content-type"] = "application/json" },
            body = '{"success":1,"file":{"downloadLink":"https://cdn.files.example/book.epub?md5=abc"}}',
        }
    end
    download_handler = function(opts, _dest, cb)
        dl_headers = opts.headers
        cb(true, nil, { code = 200, headers = { ["content-type"] = "application/epub+zip" } })
    end
    local cfg = { base_url = "https://good.example", email = "a@b.c", password = "p", user_id = "1", user_key = "stale" }
    local ok, err
    freshClient(cfg):downloadAsync("42", "abc", "/tmp/test.epub", nil, function(o, e) ok, err = o, e end)
    Assert.is_true(ok, err)
    Assert.eq(cfg.user_key, "fresh")
    Assert.is_nil(dl_headers.Cookie, "外域 CDN 下载不得泄露账号 Cookie")
    Assert.eq(dl_headers.Referer, "https://good.example/")
end

return true
