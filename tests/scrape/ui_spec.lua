--[[--
scrape.ui 离线用例：本地元数据写入、失败收口与封面原子替换。

@module tests.scrape.ui_spec
--]]

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
package.preload["ui/widget/inputdialog"] = function()
    return {
        new = function(_, o)
            function o:getInputText() return self.input end
            function o:onShowKeyboard() end
            return o
        end,
    }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, o) return o end }
end
package.preload["scrape.results"] = function()
    return { new = function(_, o) return o end }
end
package.preload["scrape.search"] = function()
    return {
        searchAsync = function(_, cb)
            cb({ {
                title = "刮削标题",
                author = "刮削作者",
                intro = "简介",
                series = "系列",
                cover_url = "https://example.test/cover",
                cover_headers = { Referer = "https://example.test/" },
            } }, nil, "douban")
            return { cancel = function() end }
        end,
    }
end
local invalidated = {}
local cover_at_fetch
package.preload["ui.components.image"] = function()
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
package.preload["db.book"] = function()
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
    "ui/uimanager", "ui/widget/inputdialog", "ui/widget/infomessage",
    "scrape.results", "scrape.search", "ui.components.image", "db.book",
    "utils.paths", "source.base", "source.registry", "scrape.ui",
}) do
    package.loaded[name] = nil
end

local ScrapeUI = require("scrape.ui")
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

local function startAndPick()
    shown = {}
    ScrapeUI.start(identity, "原书名")
    local dialog = shown[#shown]
    dialog.buttons[1][2].callback()
    local results = shown[#shown]
    results.on_pick(results.results[1])
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

pcall(os.remove, Config.dir() .. "/scrape-source.png")
pcall(os.remove, cover_path)
