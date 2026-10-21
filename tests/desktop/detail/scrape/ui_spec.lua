--[[--
desktop.detail.scrape.ui 离线用例：本地元数据写入、失败收口与封面原子替换。

@module tests.desktop.detail.scrape.ui_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Config = require("support.config")

local shown = {}
local db_ok = true
local db_row
local fetch_calls = 0
local image_path
local cover_path = Config.dir() .. "/scrape-cover.png"

package.preload["ui/uimanager"] = function()
    return {
        show = function(_, widget) shown[#shown + 1] = widget end,
        close = function() end,
        setDirty = function() end,
    }
end
local Themed = require("support.theme_stubs")
Themed.install()
Themed.on_show = function(o) shown[#shown + 1] = o end
package.preload["desktop.detail.scrape.results"] = function()
    return {
        new = function(_, o)
            function o:show() shown[#shown + 1] = self end
            return o
        end,
    }
end
local search_pending
package.preload["desktop.detail.scrape.search"] = function()
    return {
        SOURCES = { { id = "douban", name = "豆瓣" } },
        searchAsync = function(_, cb)
            if search_pending then
                search_pending.cb = cb
                return { cancel = function() search_pending.cancelled = true end }
            end
            cb({ {
                title = "刮削标题",
                author = "刮削作者",
                intro = "简介",
                series = "系列",
                publisher = "重庆出版社",
                year = "2008-1",
                rating = "8.8",
                source = "douban",
                cover_url = "https://example.test/cover",
                cover_headers = { Referer = "https://example.test/" },
            } }, nil, "douban")
            return { cancel = function() end }
        end,
    }
end
local invalidated = {}
local cover_at_fetch
package.preload["ui.themes.widgets.image"] = function()
    return {
        fetchAsync = function(_, _, cb)
            fetch_calls = fetch_calls + 1
            cover_at_fetch = io.open(cover_path, "rb")
            if cover_at_fetch then cover_at_fetch:close() end
            cb(image_path)
            return { cancel = function() end }
        end,
        invalidate = function(path) invalidated[#invalidated + 1] = path end,
    }
end
package.preload["book.books_db"] = function()
    return {
        get = function()
            return { category = "原分类", percent = 37, md5 = "digest" }
        end,
        upsert = function()
            error("scrape must use upsertLocal", 2)
        end,
        upsertLocal = function(row)
            db_row = row
            return db_ok
        end,
    }
end
package.preload["utils.paths"] = function()
    return {
        coverPath = function() return cover_path end,
        ensureLayout = function() end,
    }
end
package.preload["source.base"] = function()
    return {
        SourceCapabilities = {
            supportsScrape = function() return true end,
        },
    }
end
local events = {}
package.preload["source.registry"] = function()
    return { resolve = function()
        return { onEvent = function(_, event, payload)
            local f = io.open(cover_path, "rb")
            if f then f:close() end
            events[#events + 1] = { event = event, payload = payload, cover_ready = f ~= nil }
        end }
    end }
end

for _, name in ipairs({
    "ui/uimanager",
    "desktop.detail.scrape.results", "desktop.detail.scrape.search", "ui.themes.widgets.image", "book.books_db",
    "utils.paths", "source.base", "source.registry", "desktop.detail.scrape.ui",
}) do
    package.loaded[name] = nil
end

local ScrapeUI = require("desktop.detail.scrape.ui")
local identity = { source_id = "local", stable_id = "/books/a.epub" }

local function write(path, data)
    local f = assert(io.open(path, "wb"))
    assert(f:write(data))
    assert(f:close())
end

local function read(path)
    local f = assert(io.open(path, "rb"))
    local data = assert(f:read("*a"))
    assert(f:close())
    return data
end

local owner = {}

local function startAndPick()
    shown = {}
    ScrapeUI.start(identity, "原书名", nil, owner)
    local list = shown[#shown]
    Assert.eq(list.items[1].mandatory, "原书名", "顶部是书名行")
    list.items[2].callback()
    local results = shown[#shown]
    results.on_pick(results.results[1])
    Assert.is_nil(owner.scrape_job, "同步完成的搜索不留句柄")
end

local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close() end
    return f ~= nil
end

-- 成功路径必须写本地元数据，并保留分类、进度和摘要；
-- 旧封面在下载前删掉，新图移入封面路径，下载缓存不留副本。
image_path = Config.dir() .. "/scrape-source.png"
write(image_path, "new-cover")
write(cover_path, "old-cover")
db_ok = true
db_row = nil
fetch_calls = 0
startAndPick()
Assert.not_nil(db_row)
Assert.eq(db_row.source_id, "local")
Assert.eq(db_row.stable_id, "/books/a.epub")
Assert.eq(db_row.title, "刮削标题")
Assert.eq(db_row.category, "原分类")
Assert.eq(db_row.md5, "digest")
Assert.is_nil(db_row.percent, "upsertLocal 不再写 percent")
Assert.eq(db_row.meta.publisher, "重庆出版社")
Assert.eq(db_row.meta.published, "2008-1")
Assert.eq(db_row.meta.rating.score, "8.8")
Assert.eq(db_row.meta.rating.by, "douban", "评分记下来源")
Assert.is_nil(db_row.meta.isbn)
Assert.eq(fetch_calls, 1)
Assert.is_nil(cover_at_fetch, "下载前必须先删旧封面")
Assert.eq(read(cover_path), "new-cover")
Assert.is_false(exists(image_path), "下载缓存的图要移走，不留副本")
Assert.eq(invalidated[#invalidated], cover_path, "换封面必须让位图缓存失效")
Assert.eq(shown[#shown].text, "元数据已更新")
Assert.len(events, 1, "落库与封面完成后通知属主源上行")
Assert.eq(events[1].event, "book_meta_changed")
Assert.eq(events[1].payload.identity, identity)
Assert.is_true(events[1].payload.cover)
Assert.is_true(events[1].cover_ready, "上行时新封面已经落地")

-- 数据库失败不能继续下载封面，更不能谎报更新成功。
db_ok = false
fetch_calls = 0
startAndPick()
Assert.eq(fetch_calls, 0)
Assert.eq(shown[#shown].text, "元数据更新失败")
Assert.len(events, 1, "落库失败不得上行")

-- 下载失败：旧封面照样删掉，不能继续展示和元数据不符的图，也不谎报失败。
db_ok = true
write(cover_path, "old-cover")
image_path = nil
startAndPick()
Assert.is_false(exists(cover_path))
Assert.eq(shown[#shown].text, "元数据已更新")

-- 搜索在飞时详情页关闭：取消搜索并收起「搜索中」提示，之后不再弹结果页。
search_pending = {}
shown = {}
ScrapeUI.start(identity, "原书名", nil, owner)
shown[#shown].items[2].callback()
local searching = shown[#shown]
Assert.eq(searching.text, "搜索中...")
owner.scrape_job.cancel()
Assert.is_true(search_pending.cancelled)
Assert.is_true(searching.closed)
search_pending = nil

-- 书名行改写后列表跟着更新；书名为空不发搜索。
shown = {}
ScrapeUI.start(identity, "原书名", nil, owner)
local list = shown[#shown]
list.items[1].callback()
local input = shown[#shown]
Assert.eq(input.fields[1].text, "原书名")
input.callback("  ")
Assert.eq(list.items[1].mandatory, "点按输入")
list.items[2].callback()
Assert.eq(shown[#shown].text, "书名不能为空")

pcall(os.remove, Config.dir() .. "/scrape-source.png")
pcall(os.remove, cover_path)
