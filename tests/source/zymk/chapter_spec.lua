--[[--
知音漫客图片下载：同步目录回调后取消在飞下载；失败不打包、VIP 明确拒绝。

@module tests.source.zymk.chapter_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Config = require("support.config")
local downloaded, pending, cancelled, built = {}, nil, {}, nil
package.loaded["utils.paths"] = {
    bookWorkDir = function() return Config.dir() .. "/zymk-chapter" end,
    ensureBookWork = function() end,
    ensureDir = function() end,
}
package.loaded["source.cbz"] = {
    ready = function() return false end,
    build = function(files, archive, _state, cb) built = files; cb(archive) end,
}
package.loaded["utils.image"] = {
    suffix = function() return ".jpg" end,
    file = function() return ".jpg" end,
    ok = function(path) return downloaded[path] == true end,
}
package.loaded["source.zymk.client"] = {
    imagesAsync = function(_uid, cb)
        cb({ "https://img/1.jpg", "https://img/2.jpg" })
        return { cancel = function() cancelled.images = true end }
    end,
}
package.loaded["http.request"] = {
    download = function(_opts, path, cb)
        pending = function(ok, err) downloaded[path] = ok; cb(ok, err) end
        return { cancel = function() cancelled.download = true end }
    end,
}
local Chapter = require("source.zymk.chapter")
local called = false
local identity = { source_id = "zymk", stable_id = "book" }
local handle = Chapter.materializeAsync(identity, { uid = "123/first" }, nil, function() called = true end)
handle.cancel()
Assert.is_true(cancelled.download)
Assert.is_nil(cancelled.images)
pending(true)
Stubs.flush()
Assert.is_false(called)
Assert.is_nil(built)

downloaded = {}
Chapter.materializeAsync(identity, { uid = "123/failed" }, nil, function(path, err)
    Assert.is_nil(path)
    Assert.eq(err, "下载失败")
end)
pending(false, "下载失败")
Assert.is_nil(built)

local count, progress, result = 0, {}, nil
require("http.request").download = function(_opts, path, cb)
    count = count + 1
    downloaded[path] = true
    cb(true)
    return { cancel = function() end }
end
Chapter.materializeAsync(identity, { uid = "123/second" }, function(done, total)
    progress[#progress + 1] = { done, total }
end, function(path) result = path end)
Stubs.flush()
Assert.eq(count, 2)
Assert.len(built, 2)
Assert.len(progress, 2)
Assert.eq(progress[2][1], 2)
Assert.eq(progress[2][2], 2)
Assert.matches(result, "/123_second%.cbz$")

Chapter.materializeAsync(identity, { uid = "123/vip", vip = true }, nil, function(path, err)
    Assert.is_nil(path)
    Assert.eq(err, "本章未购买")
end)
Stubs.flush()
