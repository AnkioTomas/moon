--[[-- source.local.client:testWebdavAsync：写入探针、读回比对、删除 --]]

local Assert = require("support.assert")

package.loaded["source.local.client"] = nil
local Client = require("source.local.client")

--- 内存 WebDAV：PUT 存内容，GET 写回 dest，DELETE 移除。
local function fakeDav(store, fail)
    fail = fail or {}
    local calls = {}
    return {
        calls = calls,
        ensurePathAsync = function(_, path, cb)
            calls[#calls + 1] = "MKCOL " .. path
            if fail.mkcol then cb(nil, fail.mkcol) else cb(true) end
        end,
        putFileAsync = function(_, path, local_path, cb)
            calls[#calls + 1] = "PUT " .. path
            if fail.put then cb(nil, fail.put); return end
            local f = assert(io.open(local_path, "rb"))
            store[path] = f:read("*a")
            f:close()
            cb(true)
        end,
        getAsync = function(_, path, dest, _, cb)
            calls[#calls + 1] = "GET " .. path
            if fail.get then cb(nil, fail.get); return end
            local f = assert(io.open(dest, "wb"))
            f:write(fail.corrupt and "garbage" or store[path])
            f:close()
            cb(true)
        end,
        deleteAsync = function(_, path, cb)
            calls[#calls + 1] = "DELETE " .. path
            if fail.delete then cb(nil, fail.delete); return end
            store[path] = nil
            cb(true)
        end,
    }
end

local function run(cfg, fail)
    local store = {}
    local client = Client.new(cfg)
    client.dav = fakeDav(store, fail)
    local ok, err
    client:testWebdavAsync(function(v, e) ok, err = v, e end)
    return ok, err, store, client
end

local CFG = { webdav_url = "https://dav.example", webdav_path = "Books" }
local PROBE = "Books/.moon-webdav-test"

-- 正常：建目录 → 写 → 读 → 删，远端不留探针，本地不留临时文件。
do
    local ok, err, store, client = run(CFG)
    Assert.is_true(ok)
    Assert.is_nil(err)
    Assert.is_nil(store[PROBE], "探针已删除")
    Assert.eq(table.concat(client.dav.calls, "|"),
        "MKCOL Books|PUT " .. PROBE .. "|GET " .. PROBE .. "|DELETE " .. PROBE)
    local root = client:webdavCacheRoot()
    Assert.is_nil(io.open(root .. "/.test.upload", "rb"), "上传临时文件已清理")
    Assert.is_nil(io.open(root .. "/.test.download", "rb"), "下载临时文件已清理")
end

-- 未配置 WebDAV：不发任何请求。
do
    local ok, err, _, client = run({})
    Assert.is_false(ok)
    Assert.eq(err, "未配置 WebDAV 地址")
    Assert.len(client.dav.calls, 0)
end

-- 地址非法：走 validatePath 的错误文案。
do
    local ok, err = run({ webdav_url = "dav.example" })
    Assert.is_false(ok)
    Assert.eq(err, "WebDAV 地址必须以 http:// 或 https:// 开头")
end

-- 各步骤失败：错误带阶段前缀，并在失败处停止。
do
    local ok, err, _, client = run(CFG, { mkcol = "HTTP 500" })
    Assert.is_false(ok)
    Assert.eq(err, "创建目录失败：HTTP 500")
    Assert.len(client.dav.calls, 1)

    ok, err, _, client = run(CFG, { put = "认证失败，请检查用户名或密码" })
    Assert.is_false(ok)
    Assert.eq(err, "写入失败：认证失败，请检查用户名或密码")
    Assert.len(client.dav.calls, 2)

    ok, err = run(CFG, { get = "HTTP 404" })
    Assert.is_false(ok)
    Assert.eq(err, "读取失败：HTTP 404")

    ok, err = run(CFG, { delete = "HTTP 403" })
    Assert.is_false(ok)
    Assert.eq(err, "删除失败：HTTP 403")
end

-- 读回内容不一致：判失败，不再删除。
do
    local ok, err, store, client = run(CFG, { corrupt = true })
    Assert.is_false(ok)
    Assert.eq(err, "读回内容与写入不一致")
    Assert.not_nil(store[PROBE])
    Assert.len(client.dav.calls, 3)
end

-- 目录缺省：落在 Apps/Books。
do
    local _, _, _, client = run({ webdav_url = "http://dav.example" })
    Assert.eq(client.dav.calls[1], "MKCOL Apps/Books")
end

-- 设置页/远程配置原地改共享 cfg：已建好的客户端必须用新地址与账号，不能沿用构造时的空地址。
do
    local cfg = {}
    local client = Client.new(cfg)
    cfg.webdav_url = "http://dav.example:8088/"
    cfg.webdav_username = "moon"
    cfg.webdav_password = "pw"
    Assert.eq(client.dav:join("books", true), "http://dav.example:8088/books/")
    Assert.eq(client.dav.username, "moon")
    Assert.eq(client.dav.password, "pw")
end

return true
