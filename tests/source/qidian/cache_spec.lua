--[[-- 起点升级离线缓存不删章节，启用章评时原地追加入口。 @module tests.source.qidian.cache_spec --]]
local Assert = require("support.assert")
local Config = require("support.config")
Config.setupNativePath()
local lfs = require("libs/libkoreader-lfs")
local Paths = require("utils.paths")
local source = require("source.qidian").new()
local dir = Config.dir() .. "/qidian-cache-preserve"
lfs.mkdir(dir)
local path = dir .. "/1.html"
local file = assert(io.open(path, "wb"))
file:write("<html><body><p>离线可读正文</p></body></html>")
file:close()
local work_dir = Paths.bookWorkDir
Paths.bookWorkDir = function() return dir end
source.paragraphReviewsEnabled = function() return true end
package.loaded["source.chapter"] = nil
package.preload["source.chapter"] = function()
    return {
        vipFetcher = function() return function() error("缓存命中不应拉正文") end end,
        openAsync = function(_source, _identity, _book, _opts, ops, cb)
            Assert.is_true(ops.reuse(path))
            cb(path)
            return { cancel = function() end }
        end,
    }
end
local opened
source:openBookAsync({ source_id = "qidian", stable_id = "fixture" }, { chapter_idx = 1 },
    function(value) opened = value end)
Assert.eq(opened, path)
file = assert(io.open(path, "rb"))
local html = file:read("*a")
file:close()
Assert.matches(html, "<p>离线可读正文</p>")
Assert.matches(html, 'id="moon%-chapter%-reviews"')
Paths.bookWorkDir = work_dir
os.remove(path)
lfs.rmdir(dir)
