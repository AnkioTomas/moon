--[[--
http.webdav 连通性探针：建目录、写入、读回比对、删除。临时文件用完即删。

@module tests.http.webdav_probe_spec
--]]

local Assert = require("support.assert")
local Fs = require("utils.fs")
local Paths = require("utils.paths")

package.loaded["http.webdav"] = nil
local Webdav = require("http.webdav")

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
            local file = assert(io.open(local_path, "rb"))
            store[path] = file:read("*a")
            file:close()
            cb(true)
        end,
        getAsync = function(_, path, dest, _, cb)
            calls[#calls + 1] = "GET " .. path
            if fail.get then cb(nil, fail.get); return end
            local file = assert(io.open(dest, "wb"))
            file:write(fail.corrupt and "garbage" or store[path])
            file:close()
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

local function tmpNames()
    local names = {}
    for _idx, name in ipairs(Fs.list(Paths.tmpDir())) do names[name] = true end
    return names
end

local function run(path, fail)
    local store = {}
    local dav = fakeDav(store, fail)
    setmetatable(dav, { __index = Webdav })
    local before = tmpNames()
    local ok, err
    dav:probeAsync(path, function(v, e) ok, err = v, e end)
    local leaked = {}
    for name in pairs(tmpNames()) do
        if not before[name] then leaked[#leaked + 1] = name end
    end
    table.sort(leaked)
    return ok, err, store, dav, leaked
end

local PROBE = "Books/.moon-webdav-test"

do
    local ok, err, store, dav, leaked = run("Books")
    Assert.is_true(ok)
    Assert.is_nil(err)
    Assert.is_nil(store[PROBE], "探针已删除")
    Assert.eq(table.concat(dav.calls, "|"),
        "MKCOL Books|PUT " .. PROBE .. "|GET " .. PROBE .. "|DELETE " .. PROBE)
    Assert.eq(table.concat(leaked, ","), "", "临时文件已清理")
end

do
    local ok, err, _, dav = run("Books", { mkcol = "HTTP 500" })
    Assert.is_false(ok)
    Assert.eq(err, "创建目录失败：HTTP 500")
    Assert.len(dav.calls, 1)

    ok, err, _, dav = run("Books", { put = "认证失败，请检查用户名或密码" })
    Assert.is_false(ok)
    Assert.eq(err, "写入失败：认证失败，请检查用户名或密码")
    Assert.len(dav.calls, 2)

    ok, err = run("Books", { get = "HTTP 404" })
    Assert.is_false(ok)
    Assert.eq(err, "读取失败：HTTP 404")

    ok, err = run("Books", { delete = "HTTP 403" })
    Assert.is_false(ok)
    Assert.eq(err, "删除失败：HTTP 403")
end

do
    local ok, err, store, dav = run("Books", { corrupt = true })
    Assert.is_false(ok)
    Assert.eq(err, "读回内容与写入不一致")
    Assert.not_nil(store[PROBE], "内容不对就留下探针，不再删除")
    Assert.len(dav.calls, 3)
end

do
    local _, _, _, dav = run("Apps/Books")
    Assert.eq(dav.calls[1], "MKCOL Apps/Books")
end
