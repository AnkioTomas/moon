---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[-- source.local 删除：纯本地书删原文件即确认、立即撕墓碑；WebDAV 书本地优先，远端留给同步推删 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

local Config = require("support.config")
local dir = Config.dir() .. "/local-delete"
require("utils.paths").ensureDir(dir)
local function touchFile(path)
    local f = assert(io.open(path, "wb"))
    f:write("x")
    f:close()
end
local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close() end
    return f ~= nil
end

local rec = {}
local connected = true
local webdav = true
local enqueued = {}
package.preload["workers.tasks"] = function()
    return { enqueue = function(spec) enqueued[#enqueued + 1] = spec.key; return spec end }
end
package.preload["book.store"] = function()
    return { markDeleted = function(source_id, stable_id)
        rec.marked = { source_id, stable_id }
        return true
    end }
end
package.preload["book.books_db"] = function()
    return { remove = function(source_id, stable_id)
        rec.removed = { source_id, stable_id }
        return true
    end }
end
package.preload["source.local.client"] = function()
    local Client = {}
    function Client.new() return Client end
    function Client.isRemote(id) return id:sub(1, 9) == "webdav://" end
    function Client:isWebdav() return webdav end
    function Client:configured() return true end
    function Client:webdavBookRoot() return dir end
    function Client:scanWebdavAsync(cb, opts)
        if opts.dirty_only then rec.pushes = (rec.pushes or 0) + 1 end
        cb(true)
        return { cancel = function() end }
    end
    return Client
end
package.preload["ui/network/manager"] = function()
    return { isConnected = function() return connected end }
end
for _idx, name in ipairs({ "book.store", "book.books_db", "source.local.client", "ui/network/manager",
    "workers.tasks", "source.base", "source.local" }) do
    package.loaded[name] = nil
end

local Local = require("source.local")
local src = Local.new()

-- 纯本地书：删原文件 → 标删 → 立即撕墓碑，不需要网络
do
    connected = false
    local path = dir .. "/plain.epub"
    touchFile(path)
    local ok
    src:deleteBookAsync({ source_id = "local", stable_id = path }, function(v) ok = v end)
    Stubs.flush()
    Assert.is_true(ok)
    Assert.is_false(exists(path))
    Assert.eq(rec.marked[2], path)
    Assert.eq(rec.removed[2], path)
end

-- 原文件已被外部删掉：同样算确认，照常标删并撕墓碑
do
    rec = {}
    local ok
    local path = dir .. "/missing.epub"
    src:deleteBookAsync({ source_id = "local", stable_id = path }, function(v) ok = v end)
    Stubs.flush()
    Assert.is_true(ok)
    Assert.eq(rec.marked[2], path)
    Assert.eq(rec.removed[2], path)
end

-- 原文件在但删不掉（这里用非空目录模拟）：失败且库里什么都不动
do
    rec = {}
    local stuck = dir .. "/stuck.epub"
    require("utils.paths").ensureDir(stuck)
    touchFile(stuck .. "/x")
    local ok, err
    src:deleteBookAsync({ source_id = "local", stable_id = stuck }, function(v, e) ok, err = v, e end)
    Stubs.flush()
    Assert.is_false(ok)
    Assert.not_nil(err)
    Assert.is_nil(rec.marked)
    Assert.is_nil(rec.removed)
    os.remove(stuck .. "/x")
    os.remove(stuck)
end

-- WebDAV 离线：删本地镜像、留墓碑、立即成功，不推远端
do
    rec = {}
    connected = false
    touchFile(dir .. "/云.epub")
    local ok
    src:deleteBookAsync({ source_id = "local", stable_id = "webdav://云.epub" }, function(v) ok = v end)
    Stubs.flush()
    Assert.is_true(ok)
    Assert.is_false(exists(dir .. "/云.epub"))
    Assert.eq(rec.marked[2], "webdav://云.epub")
    Assert.is_nil(rec.removed, "远端没确认前不撕墓碑")
    Assert.len(enqueued, 0)
end

-- WebDAV 已连网：顺手入队推脏，不直接跑同步（和桌面同步、别的推脏抢 books.sync）
do
    rec = {}
    connected = true
    local ok
    src:deleteBookAsync({ source_id = "local", stable_id = "webdav://云2.epub" }, function(v) ok = v end)
    Stubs.flush()
    Assert.is_true(ok)
    Assert.eq(enqueued[1], "dirty\0local")
    Assert.is_nil(rec.pushes)
end

-- 推脏：WebDAV 照常入队；纯本地目录没有远端，不入队
do
    enqueued = {}
    src:pushDirty()
    Assert.eq(enqueued[1], "dirty\0local")
    webdav = false
    src:pushDirty()
    Assert.len(enqueued, 1, "纯本地不空跑")
    webdav = true
end

-- 纯本地：dirty_only / 进度 / 笔记都没有远端，下一帧回调 skipped（不同步回调）
do
    webdav = false
    local got = {}
    src:syncBooksAsync({ dirty_only = true }, function(r) got.books = r end)
    src:syncProgressAsync({}, function(r) got.progress = r end)
    src:syncNotesAsync({}, function(r) got.notes = r end)
    Assert.is_nil(got.books)
    Assert.is_nil(got.progress)
    Assert.is_nil(got.notes)
    Stubs.flush()
    Assert.is_true(got.books.skipped)
    Assert.is_true(got.progress.skipped)
    Assert.is_true(got.notes.skipped)
    webdav = true
end

-- 自动同步（打开桌面）节流：窗口内跳过；失败不占窗口，下次立即重试；force / dirty_only 不受节流
do
    local real_time, now = os.time, 1000
    os.time = function() return now end
    local runs, fail = 0, false
    local Client = require("source.local.client")
    local scan = Client.scanWebdavAsync
    Client.scanWebdavAsync = function(_, cb)
        runs = runs + 1
        if fail then cb(false, "WebDAV 认证失败") else cb(true) end
        return { cancel = function() end }
    end
    local s = Local.new()
    local result, err
    local function auto(opts)
        result, err = nil, nil
        s:syncBooksAsync(opts or {}, function(r, e) result, err = r, e end)
        Stubs.flush()
    end
    auto()
    Assert.eq(runs, 1)
    Assert.is_false(result.skipped)
    now = 1030
    auto()
    Assert.eq(runs, 1, "节流窗口内不跑")
    Assert.eq(result.reason, "throttled")
    auto({ force = true })
    Assert.eq(runs, 2, "手动刷新不节流")
    now = 1061
    fail = true
    auto()
    Assert.eq(runs, 3)
    Assert.eq(err, "WebDAV 认证失败")
    now = 1062
    fail = false
    auto()
    Assert.eq(runs, 4, "失败后不等节流窗口")
    Client.scanWebdavAsync = scan
    os.time = real_time
end

os.remove(dir)
