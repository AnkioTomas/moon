--[[-- RSS 正文缓存后断网：首次打开、切章与重开都走本地，未缓存立即报错。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
require("support.theme_stubs").install()

local connected, fetches = true, 0
package.loaded["ui/network/manager"] = { isConnected = function() return connected end }
package.loaded["http.request"] = { stream = function() error("离线打开不得发 HTTP 请求") end }
local settings = { images = true }
package.loaded["utils.settings"] = { get = function() return settings end, save = function() end }
package.loaded["reader.session"] = { current = function() return nil end }
package.loaded["book.progress_db"] = { get = function() return nil end }
package.loaded["book.note_db"] = { all = function() return {} end }

local feed = { id = 87654321, kind = "rss", title = "离线订阅" }
local items = {
    { feed_id = feed.id, guid = "cached", title = "已缓存", link = "https://rss.test/1" },
    { feed_id = feed.id, guid = "missing", title = "未缓存", link = "https://rss.test/2" },
}
package.loaded["features.subscribe.db"] = {
    feed = function() return feed end,
    scopeOf = function() return { feed = feed.id, mode = "all" } end,
    stream = function() return items end,
}
local toc
package.loaded["source.toc"] = {
    read = function() return toc end,
    put = function(_source, _id, value) toc = value; return true end,
    setWords = function() return true end,
}
local touched
package.loaded["book.store"] = { touch = function(path, identity, opts)
    touched = { path = path, identity = identity, chapter_idx = opts.chapter_idx }
    return true
end }

local Paths = require("utils.paths")
local Subscribe = require("features.subscribe")
local Source = require("features.subscribe.source")
local identity = {
    source_id = "subscribe", stable_id = tostring(feed.id),
    book = Source.book(tostring(feed.id), feed.title),
}
local source = Source.new()
local dir = Paths.bookWorkDir(identity.stable_id, identity.source_id)
require("ffi/util").purgeDir(dir)
Subscribe.providers.rss.content = function(_feed, _item, _images, cb)
    fetches = fetches + 1
    cb('<p>离线正文</p><img src="https://rss.test/not-downloaded.jpg"/>')
end

-- 批量缓存只有 articles/ 正文，没有阅读器章节文件；图片下载失败也不能挡住离线读文字。
local cached
Subscribe.cacheUnread({ items[1] }, function() end, function(count) cached = count end)
Stubs.flush()
Assert.eq(cached, 1)
Assert.eq(fetches, 1)
local origin = Paths.chapterPath(identity.stable_id, 1, identity.source_id)
Assert.is_nil(io.open(origin, "rb"), "批量缓存尚未生成章节")
connected = false

local function open(idx)
    local result = { calls = 0 }
    source:openBookAsync(identity, { chapter_idx = idx }, function(path, err)
        result.calls = result.calls + 1
        result.path, result.err = path, err
    end)
    Stubs.flush()
    Assert.eq(result.calls, 1, "离线打开必须结束回调")
    return result
end

local first = open(1)
Assert.eq(first.path, origin, "从已缓存正文生成章节并打开")
Assert.is_nil(first.err)
Assert.eq(touched.path, origin)
Assert.eq(touched.chapter_idx, 1)
local file = assert(io.open(origin, "rb"))
local html = file:read("*a")
file:close()
Assert.matches(html, "离线正文")
Assert.matches(html, "not%-downloaded.jpg", "缺图仍可读缓存正文")
Assert.eq(fetches, 1, "不得为缺图重抓正文")

local missing = open(2)
Assert.is_nil(missing.path)
Assert.eq(missing.err, "网络不可用，请先连接 Wi-Fi")
Assert.eq(fetches, 1, "未缓存离线立即失败，不调用 provider")

local again = open(1)
Assert.eq(again.path, origin, "离线重开同样可用")
Assert.eq(fetches, 1)

-- 正文没变的重建不能刷新原章时间戳，否则已生成的双语章会被误判过期。
local ChapterBi = require("features.translate.chapter")
require("source.chapter").variant = ChapterBi.resolve
ChapterBi.set(identity, { engine = "edge", lang = "zh" })
local bi = ChapterBi.pathFor(origin, ChapterBi.get(identity))
local translated = assert(io.open(bi, "wb"))
assert(translated:write(html .. "<!-- translated -->"))
translated:close()
local lfs = require("libs/libkoreader-lfs")
assert(lfs.touch(origin, 1000, 1000))
assert(lfs.touch(bi, 2000, 2000))
local bilingual = open(1)
Assert.eq(bilingual.path, bi, "重开未变化的文章继续用双语版")
Assert.eq(lfs.attributes(origin, "modification"), 1000, "不因重建改变原章时间戳")
Assert.eq(fetches, 1, "复用双语不发请求")

-- 真正更新正文仍要使旧双语章失效。
local article = assert(io.open(Subscribe.articlePath(feed.id, items[1].guid), "wb"))
assert(article:write("<h1>已缓存</h1><p>更新后的正文</p>"))
article:close()
local updated = open(1)
Assert.eq(updated.path, origin, "正文变了不能继续用旧译文")
Assert.is_nil(ChapterBi.resolve(identity, 1, origin))
local changed = assert(io.open(origin, "rb"))
Assert.matches(changed:read("*a"), "更新后的正文")
changed:close()

-- 换筛选范围后，仍能从所属订阅的文章缓存重建章节。
identity.stable_id = "subscribe-offline-scope-spec"
identity.book = Source.book(identity.stable_id, "筛选范围")
toc = nil
local scoped = open(1)
Assert.eq(scoped.path, Paths.chapterPath(identity.stable_id, 1, identity.source_id))
Assert.is_nil(scoped.err)
Assert.eq(fetches, 1)

local result
local job = source:openBookAsync(identity, { chapter_idx = 1 }, function() result = true end)
job.cancel()
Stubs.flush()
Assert.is_nil(result, "取消后不再交付章节")

require("ffi/util").purgeDir(dir)
require("ffi/util").purgeDir(Paths.bookWorkDir(identity.stable_id, identity.source_id))
