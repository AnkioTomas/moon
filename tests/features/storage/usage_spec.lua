--[[--
storage.usage：按用途归类 .moon 下的文件并按体积降序汇总。
@module tests.features.storage.usage_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

Stubs.install()
package.loaded["utils.paths"] = { root = function() return "/data/.moon" end }
local files = {
    ["/data/.moon/book.sqlite3"] = 30, ["/data/.moon/book.sqlite3-wal"] = 5,
    ["/data/.moon/cache/local/image/a.png"] = 100, ["/data/.moon/cache/local/image/b.png"] = 50,
    ["/data/.moon/cache/local/book/x/1.html"] = 7, ["/data/.moon/cache/online/w.json"] = 1,
    ["/data/.moon/book.log"] = 2,
}
package.loaded["book.cache"] = {
    walkFiles = function(_root, visit)
        for path, size in pairs(files) do visit(path, { mode = "file", size = size }) end
    end,
}
package.loaded["workers.job"] = {
    run = function(worker, opts)
        opts.on_done(worker())
        return { cancel = function() end }
    end,
}

local Usage = require("features.storage.usage")

Assert.eq(Usage.bucket("book.sqlite3-wal"), "database")
Assert.eq(Usage.bucket("cache/local/image/a.png"), "cache/local/image")
Assert.eq(Usage.bucket("cache/local/other.bin"), "cache/local")
Assert.eq(Usage.bucket("cache/online/w.json"), "cache/online")
Assert.eq(Usage.bucket("backups/patches/x/f.lua"), "backups")
Assert.eq(Usage.label("cache/local/image"), "local 封面与图片")

local got, got_total
Usage.measureAsync(function(list, total) got, got_total = list, total end)
Assert.eq(got_total, 195)
Assert.eq(got[1][1], "cache/local/image")
Assert.eq(got[1][2], 150)
Assert.eq(got[2][1], "database")
Assert.eq(got[2][2], 35)
Assert.len(got, 5)
