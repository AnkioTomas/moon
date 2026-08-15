--[[--
http.request 离线用例：ok / header / writeResponseToFile（纯本地，无网络）

request/get/post/download/ensureTurbo/patchTurboSsl/randomUA/randomIP
依赖 Turbo 与网络，不在离线范围。

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
