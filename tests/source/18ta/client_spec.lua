--[[--
source.18ta.client 离线用例：WAF 403 → Set-Cookie → 重发的兜底逻辑。

@module tests.source.18ta.client_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")

-- 脚本化 http.request：get 按序消费 script，headerAll 从 res.headers 取 Set-Cookie。
local calls = {}
local script = {}
package.preload["http.request"] = function()
    return {
        get = function(url, opts, cb)
            local call = { url = url, headers = opts and opts.headers or {}, cb = cb }
            calls[#calls + 1] = call
            local step = table.remove(script, 1) or { code = 200, body = "" }
            local handle = { cancel = function() call.cancelled = true end }
            if step.delayed then return handle end
            if step.err then
                cb(nil, step.err, nil)
            elseif step.code and step.code ~= 200 then
                cb(nil, "HTTP " .. step.code, { code = step.code, headers = step.headers or {} })
            else
                cb(step.body, nil, { code = 200, body = step.body, headers = step.headers or {} })
            end
            return handle
        end,
        headerAll = function(res, name)
            local out = {}
            if name == "Set-Cookie" and res and res.headers then
                local raw = res.headers["Set-Cookie"]
                if type(raw) == "table" then
                    for _idx, line in ipairs(raw) do out[#out + 1] = line end
                elseif type(raw) == "string" then
                    out[1] = raw
                end

            end
            return out
        end,
    }
end

local Client = require("source.18ta.client")

local function run(client, path)
    local out_body, out_err
    client:get(path, function(body, err)
        out_body, out_err = body, err
    end)
    return out_body, out_err
end

-- 首次 403 下发 Cookie：收 Cookie 重发一次，拿到正文。
do
    script = {
        { code = 403, headers = { ["Set-Cookie"] = { "a1345448228df7d678feec207bf34007=abc; Path=/", "server_session_8ab1edd4=xyz; Path=/; HttpOnly" } } },
        { code = 200, body = "LISTING" },
    }
    calls = {}
    local client = Client.new()
    local body, err = run(client, "/sort/1/1.html")
    Assert.is_nil(err)
    Assert.eq(body, "LISTING")
    Assert.eq(#calls, 2, "403 后重发一次")
    Assert.eq(calls[1].url, "https://www.18ta.com/sort/1/1.html")
    Assert.is_nil(calls[1].headers.Cookie, "首请求不带 Cookie")
    Assert.is_true(calls[2].headers.Cookie:find("a1345448228df7d678feec207bf34007=abc", 1, true), "重发带首个 Cookie")
    Assert.is_true(calls[2].headers.Cookie:find("server_session_8ab1edd4=xyz", 1, true), "重发带全部 Cookie")
end

-- 已有 Cookie 直通 200：不重发。
do
    script = { { code = 200, body = "OK" } }
    calls = {}
    local client = Client.new()
    client.cookies.k = "v"
    local body = run(client, "/akshtml123.html")
    Assert.eq(body, "OK")
    Assert.eq(#calls, 1)
    Assert.is_true(calls[1].headers.Cookie:find("k=v", 1, true), "自带 Cookie 头")
end

-- 403 但没下发 Cookie：不重发，错误透传。
do
    script = { { code = 403 } }
    calls = {}
    local body, err = run(Client.new(), "/sort/1/1.html")
    Assert.is_nil(body)
    Assert.eq(err, "HTTP 403")
    Assert.eq(#calls, 1, "没有 Cookie 不重发")
end

-- 传输错误：不重发，错误透传。
do
    script = { { err = "timeout" } }
    calls = {}
    local body, err = run(Client.new(), "/sort/1/1.html")
    Assert.is_nil(body)
    Assert.eq(err, "timeout")
    Assert.eq(#calls, 1)
end

-- Cookie 随成功响应刷新：下一个请求带上新 Cookie。
do
    script = {
        { code = 200, body = "A", headers = { ["Set-Cookie"] = { "sess=1; Path=/" } } },
        { code = 200, body = "B" },
    }
    calls = {}
    local client = Client.new()
    run(client, "/sort/1/1.html")
    local body = run(client, "/sort/1/2.html")
    Assert.eq(body, "B")
    Assert.is_true(calls[2].headers.Cookie:find("sess=1", 1, true), "刷新后的 Cookie 参与后续请求")
end

-- 完整 URL 原样透传（目录 href 的 origin 是绝对地址）。
do
    script = { { code = 200, body = "CH" } }
    calls = {}
    local body = run(Client.new(), "https://www.18ta.com/aks/287/287895/5447961.html")
    Assert.eq(body, "CH")
    Assert.eq(calls[1].url, "https://www.18ta.com/aks/287/287895/5447961.html")
end

-- 首请求同步 403、重试异步：取消须作用于重试，不接受迟到 Cookie 和正文。
do
    script = {
        { code = 403, headers = { ["Set-Cookie"] = "waf=pending; Path=/" } },
        { delayed = true },
    }
    calls = {}
    local client, completed = Client.new(), 0
    local handle = client:get("/sort/", function() completed = completed + 1 end)
    handle.cancel()
    Assert.is_true(calls[2].cancelled)
    calls[2].cb("late", nil, { headers = { ["Set-Cookie"] = "waf=late; Path=/" } })
    Assert.eq(completed, 0)
    Assert.eq(client.cookies.waf, "pending")
end
