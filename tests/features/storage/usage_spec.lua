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
    ["/data/.moon/fonts/used.ttf"] = 10, ["/data/.moon/fonts/used.woff"] = 1,
    ["/data/.moon/dictionary.sqlite3"] = 20, ["/data/.moon/dictionary.sqlite3-wal"] = 3,
    ["/data/.moon/rare/zh-pinyin.tsv"] = 4,
    ["/data/.moon/ime_pinyin_dict.dl/a"] = 8,
    ["/data/.moon/rare/zh-pinyin.tsv.dl/b"] = 2,
    ["/data/.moon/cache/local/image/a.png.part"] = 6,
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
Assert.eq(cls("settings/ui.lua")[1], "settings")
Assert.eq(cls("cache/local/image/a.png")[1], "image")
Assert.eq(cls("cache/image/a.png")[1], "image")
Assert.eq(cls("cache/local/image/a.png.part")[1], "leftover")
Assert.eq(cls("cache/local/other.bin")[1], "cache")
Assert.eq(cls("cache/online/w.json")[1], "online")
Assert.eq(cls("cache/.trash/old/1.html")[1], "trash")
Assert.eq(cls("backups/patches/x/f.lua")[1], "backup")
Assert.eq(cls("dictionary-wubi.sqlite3")[1], "dict")
Assert.eq(cls("ime_pinyin_dict.dl/a")[1], "leftover")
Assert.eq(cls("dict-stardict.dl/part.bin")[1], "leftover")
Assert.eq(cls("plugin-update.zip")[1], "leftover")
Assert.eq(cls("kamare-update.zip")[1], "leftover")
Assert.eq(Usage.itemKey("leftover", "kindle-plugin-update.zip.part"), "kindle-plugin-update.zip")
local archive_body = Usage.leftoverTargets("kamare-update.zip")
Assert.eq(archive_body, "kamare-update.zip")
Assert.eq(cls("fonts/a.ttf")[1], "fonts")
Assert.eq(cls("rare/x.tsv")[1], "rare")
Assert.eq(cls("rare/zh-pinyin.tsv.dl/b")[1], "leftover")
Assert.eq(Usage.itemKey("fonts", "fonts/used.ttf"), "used")
Assert.eq(Usage.itemKey("fonts", "fonts/used.woff"), "used")
Assert.eq(Usage.itemKey("dict", "dictionary.sqlite3-wal"), "pinyin")
Assert.eq(Usage.itemKey("dict", "dictionary-wubi.sqlite3-shm"), "wubi")
Assert.eq(Usage.itemKey("rare", "rare/zh-pinyin.tsv"), "zh-pinyin")
Assert.eq(Usage.itemKey("leftover", "ime_pinyin_dict.dl/a"), "ime_pinyin_dict.dl")
Assert.eq(Usage.itemKey("leftover", "rare/zh-pinyin.tsv.dl/b"), "rare/zh-pinyin.tsv.dl")
Assert.eq(Usage.itemKey("leftover", "plugin-update.zip.part"), "plugin-update.zip")
Assert.eq(Usage.itemKey("leftover", "cache/local/image/a.png.part"), "cache/local/image/a.png")
local body, part = Usage.leftoverTargets("cache/local/image/a.png")
Assert.is_nil(body)
Assert.eq(part, "cache/local/image/a.png.part")
body, part = Usage.leftoverTargets("ime_pinyin_dict.dl")
Assert.eq(body, "ime_pinyin_dict.dl")
Assert.eq(part, "ime_pinyin_dict.dl.part")
body, part = Usage.leftoverTargets("plugin-update.zip")
Assert.eq(body, "plugin-update.zip")
Assert.eq(part, "plugin-update.zip.part")
Assert.eq(cls("screensaver/a.png")[1], "screensaver")
for _, cat in ipairs(Usage.CATEGORIES) do
    Assert.is_true(cat.icon ~= nil and cat.icon ~= "", cat.id)
    Assert.is_true(cat.note ~= nil and cat.note ~= "", cat.id)
end
local cat, source, slug = Usage.classify("cache/local/book/x/1.html")
Assert.eq(cat, "book")
Assert.eq(source, "local")
Assert.eq(slug, "x")

local got
Usage.measureAsync(function(result) got = result end)
Assert.eq(got.total, 249)
Assert.eq(got.cats.image, 150)
Assert.eq(got.cats.database, 35)
Assert.eq(got.cats.book, 7)
Assert.eq(got.books["local"].x, 7)
Assert.eq(got.items.fonts.used, 11)
Assert.eq(got.items.dict.pinyin, 23)
Assert.eq(got.items.rare["zh-pinyin"], 4)
Assert.eq(got.items.leftover["ime_pinyin_dict.dl"], 8)
Assert.eq(got.items.leftover["rare/zh-pinyin.tsv.dl"], 2)
Assert.eq(got.items.leftover["cache/local/image/a.png"], 6)
Assert.eq(got.cats.rare, 4)
Assert.eq(got.cats.leftover, 16)
