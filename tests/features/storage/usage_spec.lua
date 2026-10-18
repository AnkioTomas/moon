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

local function cls(rel) return { Usage.classify(rel) } end
Assert.eq(cls("book.sqlite3-wal")[1], "database")
Assert.eq(cls("settings/ui.lua")[1], "database")
Assert.eq(cls("cache/local/image/a.png")[1], "image")
Assert.eq(cls("cache/image/a.png")[1], "image")
Assert.eq(cls("cache/local/other.bin")[1], "cache")
Assert.eq(cls("cache/online/w.json")[1], "online")
Assert.eq(cls("backups/patches/x/f.lua")[1], "other")
Assert.eq(cls("dictionary-wubi.sqlite3")[1], "dict")
local cat, source, slug = Usage.classify("cache/local/book/x/1.html")
Assert.eq(cat, "book")
Assert.eq(source, "local")
Assert.eq(slug, "x")

local got
Usage.measureAsync(function(result) got = result end)
Assert.eq(got.total, 195)
Assert.eq(got.cats.image, 150)
Assert.eq(got.cats.database, 35)
Assert.eq(got.cats.book, 7)
Assert.eq(got.books["local"].x, 7)
