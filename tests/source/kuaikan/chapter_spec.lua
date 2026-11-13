--[[--
快看章节：以服务端权限为准，分阶段取消不能覆盖在飞下载。

@module tests.source.kuaikan.chapter_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch, inject-field

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Config = require("support.config")
local paths = {}
package.loaded["utils.paths"] = {
    bookWorkDir = function() return Config.dir() .. "/kuaikan-chapter" end,
    ensureBookWork = function() end,
    ensureDir = function() end,
}
package.loaded["source.cbz"] = {
    ready = function() return false end,
    build = function(files, archive, _state, cb) paths = files; cb(archive) end,
}
package.loaded["utils.image"] = {
    suffix = function() return ".jpg" end,
    ok = function(path) return paths[path] == true end,
}
local fetched, pending, cancelled = false, nil, {}
package.loaded["source.kuaikan.client"] = {
    imagesAsync = function(_uid, cb)
        fetched = true
        cb({ "https://img/1.jpg", "https://img/2.jpg" })
        return { cancel = function() cancelled.images = true end }
    end,
}
package.loaded["http.request"] = {
    download = function(_opts, path, cb)
        pending = function(ok, err) paths[path] = ok; cb(ok, err) end
        return { cancel = function() cancelled.download = true end }
    end,
}
local Chapter = require("source.kuaikan.chapter")
local called = false
local identity = { source_id = "kuaikan", stable_id = "book" }
local handle = Chapter.materializeAsync(identity, { uid = "1", vip = true }, nil, function() called = true end)
Assert.is_true(fetched)
handle.cancel()
Assert.is_true(cancelled.download)
Assert.is_nil(cancelled.images)
pending(true)
Stubs.flush()
Assert.is_false(called)

paths = {}
local downloaded, progress, result = 0, {}, nil
require("http.request").download = function(_opts, path, cb)
    downloaded = downloaded + 1
    paths[path] = true
    cb(true)
    return { cancel = function() end }
end
Chapter.materializeAsync(identity, { uid = "1", vip = true }, function(done, total)
    progress[#progress + 1] = { done, total }
end, function(path) result = path end)
Stubs.flush()
Assert.eq(downloaded, 2)
Assert.len(progress, 2)
Assert.eq(progress[2][1], 2)
Assert.eq(progress[2][2], 2)
Assert.matches(result, "/1%.cbz$")
Assert.len(paths, 2)

require("source.kuaikan.client").imagesAsync = function(_uid, cb)
    cb(nil, "本章未购买")
    return { cancel = function() end }
end
Chapter.materializeAsync(identity, { uid = "2", vip = true }, nil, function(path, err)
    Assert.is_nil(path)
    Assert.eq(err, "本章未购买")
end)

-- 已有 CBZ 只复用缓存，不取页图、不重新组装。
require("source.cbz").ready = function() return true end
require("source.cbz").build = function() error("缓存 CBZ 不得重新组装") end
require("source.kuaikan.client").imagesAsync = function() error("缓存命中不得下载页图") end
local cached
Chapter.materializeAsync(identity, { uid = "cached" }, nil, function(path) cached = path end)
Stubs.flush()
Assert.matches(cached, "/cached%.cbz$")
local cancelled_cache = false
local cached_handle = Chapter.materializeAsync(identity, { uid = "cached" }, nil,
    function() cancelled_cache = true end)
cached_handle.cancel()
Stubs.flush()
Assert.is_false(cancelled_cache, "缓存交接也尊重取消")
