--[[--
http.request 离线用例：ok / header / writeResponseToFile / SNI 补丁（纯本地，无网络）

request/get/post/download/ensureTurbo 的真实网络路径不在离线范围；
SNI 补丁经 stub 的 turbo/turbo.crypto 间接验证。

@module tests.http.request_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Config = require("support.config")

local Request = require("http.request")

-- ── ok：2xx 判定边界 ─────────────────────────────────────
do
    Assert.is_true(Request.ok(200))
    Assert.is_true(Request.ok(207)) -- WebDAV Multi-Status
    Assert.is_true(Request.ok(299))
    Assert.is_false(Request.ok(300))
    Assert.is_false(Request.ok(199))
    Assert.is_false(Request.ok(404))
    Assert.is_true(Request.ok("201")) -- 字符串数字经 tonumber
    Assert.is_false(Request.ok("abc"))
    Assert.is_false(Request.ok(nil))
    Assert.is_false(Request.ok(true))
end

-- ── header：Turbo headers 对象 / 普通 table 双兼容 ────────
do
    -- Turbo HTTPHeaders 风格：get(name, true) 忽略大小写命中
    local turbo_ci = {
        get = function(_, name, ci)
            if ci and name:lower() == "content-type" then
                return "text/html"
            end
            return nil
        end,
    }
    Assert.eq(Request.header({ headers = turbo_ci }, "Content-Type"), "text/html")

    -- Turbo 风格：ci 查询未命中时回退精确 get(name)
    local turbo_exact = {
        get = function(_, name, ci)
            if ci then
                return nil
            end
            if name == "ETag" then
                return '"abc"'
            end
            return nil
        end,
    }
    Assert.eq(Request.header({ headers = turbo_exact }, "ETag"), '"abc"')
    Assert.is_nil(Request.header({ headers = turbo_exact }, "X-Missing"))

    -- 普通 table：精确键
    Assert.eq(
        Request.header({ headers = { ["Content-Type"] = "application/epub" } }, "Content-Type"),
        "application/epub"
    )
    -- 普通 table：大小写回退 name:lower()
    Assert.eq(
        Request.header({ headers = { ["content-type"] = "text/plain" } }, "Content-Type"),
        "text/plain"
    )
    Assert.is_nil(Request.header({ headers = {} }, "X-Missing"))
    Assert.is_nil(Request.header({}, "X-Missing")) -- 无 headers 字段
    Assert.is_nil(Request.header(nil, "X-Missing")) -- 无 res
end

-- ── writeResponseToFile ──────────────────────────────────
local TMP_DIR = Config.dir() .. "/.moon"
local TMP_PREFIX = TMP_DIR .. "/test_request_spec_"

local function tmp(name)
    return TMP_PREFIX .. name
end

-- 预清理上次中途失败可能留下的临时文件
for _, name in ipairs({
    "nostring.tmp",
    "chunked.tmp",
    "empty.tmp",
    "cancel.tmp",
    "writefail.tmp",
}) do
    pcall(os.remove, tmp(name))
end

-- body 非字符串：nextTick 报 empty response
do
    local ok_r, err_r
    Request.writeResponseToFile({ body = nil }, tmp("nostring.tmp"), nil, function(ok, err)
        ok_r, err_r = ok, err
    end)
    Stubs.flush()
    Assert.is_false(ok_r)
    Assert.eq(err_r, "empty response")

    ok_r, err_r = nil, nil
    Request.writeResponseToFile(nil, tmp("nostring.tmp"), nil, function(ok, err)
        ok_r, err_r = ok, err
    end)
    Stubs.flush()
    Assert.is_false(ok_r)
    Assert.eq(err_r, "empty response")
end

-- dest 父目录不存在：open 失败
do
    local ok_r, err_r
    Request.writeResponseToFile(
        { body = "abc" },
        tmp("no_such_dir/x.tmp"),
        nil,
        function(ok, err)
            ok_r, err_r = ok, err
        end
    )
    Stubs.flush()
    Assert.is_false(ok_r)
    Assert.not_nil(err_r)
end

-- >64KB 数据分片写盘 + on_progress 累计序列 + 内容校验
do
    local CHUNK = 64 * 1024
    local body = string.rep("a", CHUNK) .. string.rep("b", CHUNK) .. string.rep("c", 100)
    local dest = tmp("chunked.tmp")
    local progress = {}
    local ok_w, err_w
    Request.writeResponseToFile({ body = body }, dest, {
        on_progress = function(n)
            progress[#progress + 1] = n
        end,
    }, function(ok, err)
        ok_w, err_w = ok, err
    end)
    Stubs.flush()

    Assert.is_true(ok_w)
    Assert.is_nil(err_w)
    Assert.len(progress, 3) -- 64K + 64K + 100 三片
    Assert.eq(progress[1], CHUNK)
    Assert.eq(progress[2], CHUNK * 2)
    Assert.eq(progress[3], CHUNK * 2 + 100)

    local fh = io.open(dest, "rb")
    Assert.not_nil(fh)
    local data = fh:read("*a")
    fh:close()
    Assert.eq(#data, #body)
    Assert.eq(data, body)
    pcall(os.remove, dest)
end

-- 空 body 字符串：立即成功，无 progress，写出空文件
do
    local dest = tmp("empty.tmp")
    local progress = {}
    local ok_w
    Request.writeResponseToFile({ body = "" }, dest, {
        on_progress = function(n)
            progress[#progress + 1] = n
        end,
    }, function(ok)
        ok_w = ok
    end)
    Stubs.flush()
    Assert.is_true(ok_w)
    Assert.len(progress, 0)
    local fh = io.open(dest, "rb")
    Assert.not_nil(fh)
    Assert.eq(fh:read("*a"), "")
    fh:close()
    pcall(os.remove, dest)
end

-- cancel：冲刷前取消 → 不再回调，残留文件删除；cancel 幂等
do
    local dest = tmp("cancel.tmp")
    local calls = 0
    local job = Request.writeResponseToFile({ body = string.rep("x", 64 * 1024 * 2) }, dest, nil, function()
        calls = calls + 1
    end)
    job.cancel()
    job.cancel() -- 二次取消无副作用
    Stubs.flush()
    Assert.eq(calls, 0)
    Assert.is_nil(io.open(dest, "rb")) -- 残留已删
end

-- 写失败（假句柄）：finish(false) 删除预先存在的残留文件
do
    local dest = tmp("writefail.tmp")
    local fh = io.open(dest, "wb")
    fh:write("stale")
    fh:close()

    local real_open = io.open
    io.open = function(path, mode)
        if path == dest then
            return {
                write = function()
                    return nil, "disk full"
                end,
                close = function() end,
            }
        end
        return real_open(path, mode)
    end
    local ok_f, err_f
    Request.writeResponseToFile({ body = "data" }, dest, nil, function(ok, err)
        ok_f, err_f = ok, err
    end)
    io.open = real_open
    Stubs.flush()

    Assert.is_false(ok_f)
    Assert.eq(err_f, "disk full")
    Assert.is_nil(io.open(dest, "rb")) -- 残留已删
end

-- 兜底清理（正常路径均已自删，防中途失败留渣）
for _, name in ipairs({
    "nostring.tmp",
    "chunked.tmp",
    "empty.tmp",
    "cancel.tmp",
    "writefail.tmp",
}) do
    pcall(os.remove, tmp(name))
end

-- ── SNI 补丁：turbo 握手前对域名补 SNI（无 SNI 时 Cloudflare 类主机直接挂起到超时）──
do
    local UIManager = require("ui/uimanager")
    UIManager.setInputTimeout = function() end
    UIManager.resetInputTimeout = function() end
    -- looper:add_callback 里的 fn 会 yield fetch 结果，用协程模拟 turbo 的 _resume_coroutine
    UIManager.looper = {
        add_callback = function(_, fn)
            local co = coroutine.create(fn)
            local _, res = coroutine.resume(co)
            if coroutine.status(co) == "suspended" then
                coroutine.resume(co, res)
            end
        end,
    }
    package.preload["turbo"] = function()
        return {
            log = { categories = {} },
            async = {
                HTTPClient = function()
                    return {
                        fetch = function(self, _url, opts)
                            local fields = {
                                { "Host", "api.ankio.net" },
                                { "User-Agent", "Turbo Client v2.0.0" },
                            }
                            local headers = {
                                get = function(_, name, ci)
                                    for _, field in ipairs(fields) do
                                        if (ci and field[1]:lower() == name:lower())
                                                or (not ci and field[1] == name) then
                                            return field[2]
                                        end
                                    end
                                end,
                                set = function(_, name, value, ci)
                                    for i = #fields, 1, -1 do
                                        if (ci and fields[i][1]:lower() == name:lower())
                                                or (not ci and fields[i][1] == name) then
                                            table.remove(fields, i)
                                        end
                                    end
                                    fields[#fields + 1] = { name, value }
                                end,
                                add = function(_, name, value)
                                    fields[#fields + 1] = { name, value }
                                end,
                            }
                            opts.on_headers(headers)
                            Assert.eq(opts.user_agent, "BookTestAgent")
                            Assert.eq(headers:get("Accept", true), "application/json")
                            Assert.eq(headers:get("X-Test", true), "yes")
                            Assert.eq(headers:get("User-Agent", true), "BookTestAgent")
                            Assert.is_nil(headers:get("Content-Length", true))
                            return { code = 200, body = "ok" }
                        end,
                    }
                end,
            },
        }
    end
    local handshake_calls = 0
    package.preload["turbo.crypto"] = function()
        return {
            ssl_create_client_context = function()
                return 0, {}
            end,
            ssl_do_handshake = function()
                handshake_calls = handshake_calls + 1
                return true
            end,
        }
    end

    -- 触发一次请求让 patchTurboSsl 装上补丁
    local got_code
    Request.request({
        url = "https://api.ankio.net/myrl",
        headers = {
            ["Accept"] = "application/json",
            ["User-Agent"] = "BookTestAgent",
            ["Content-Length"] = "3",
            ["X-Test"] = "yes",
        },
    }, function(res)
        got_code = res and res.code
    end)
    Assert.eq(got_code, 200)

    local crypto = require("turbo.crypto")
    local sni_hosts = {}
    local fake_sock = {
        sni = function(_, host)
            sni_hosts[#sni_hosts + 1] = host
        end,
    }
    -- 域名：握手前设 SNI，且只设一次
    local stream = { _ssl = fake_sock, _ssl_hostname = "api.ankio.net" }
    crypto.ssl_do_handshake(stream)
    crypto.ssl_do_handshake(stream)
    Assert.eq(#sni_hosts, 1)
    Assert.eq(sni_hosts[1], "api.ankio.net")
    -- IPv4 / IPv6 字面量不发 SNI
    crypto.ssl_do_handshake({ _ssl = fake_sock, _ssl_hostname = "1.2.3.4" })
    crypto.ssl_do_handshake({ _ssl = fake_sock, _ssl_hostname = "2001:db8::1" })
    Assert.eq(#sni_hosts, 1)
    -- 原始握手都被透传
    Assert.eq(handshake_calls, 4)

    -- 普通请求在 yield 后取消必须立即关连接，不能只抑制回调却继续占用网络。
    local queued
    UIManager.looper = {
        add_callback = function(_, fn)
            queued = fn
        end,
    }
    local turbo = require("turbo")
    local closed = 0
    turbo.async.HTTPClient = function()
        return {
            iostream = {
                closed = function() return false end,
                close = function() closed = closed + 1 end,
            },
            fetch = function()
                return {}
            end,
        }
    end
    local calls = 0
    local job = Request.request({ url = "https://api.ankio.net/pending" }, function()
        calls = calls + 1
    end)
    local co = coroutine.create(queued)
    Assert.is_true(coroutine.resume(co))
    Assert.eq(coroutine.status(co), "suspended")
    job.cancel()
    Assert.eq(closed, 1)
    Assert.eq(calls, 0)
end
