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
package.preload["ui.components.image"] = function()
    return {
        fetchAsync = function(_, _, cb)
            fetch_calls = fetch_calls + 1
            cb(image_path)
            return { cancel = function() end }
        end,
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
    return { coverPath = function() return cover_path end }
end
package.preload["types.book_source"] = function()
    return {
        SourceCapabilities = {
            supportsScrape = function() return true end,
        },
    }
end
package.preload["source.registry"] = function()
    return { resolve = function() return {} end }
end

for _, name in ipairs({
    "ui/uimanager", "ui/widget/inputdialog", "ui/widget/infomessage",
    "scrape.results", "scrape.search", "ui.components.image", "db.book",
    "utils.paths", "types.book_source", "source.registry", "scrape.ui",
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

-- 成功路径必须写本地元数据，并保留分类、进度和摘要。
image_path = Config.dir() .. "/scrape-source.png"
write(image_path, "new-cover")
db_ok = true
db_row = nil
fetch_calls = 0
startAndPick()
Assert.not_nil(db_row)
Assert.eq(db_row.source_id, "local")
Assert.eq(db_row.stable_id, "/books/a.epub")
Assert.eq(db_row.title, "刮削标题")
Assert.eq(db_row.category, "原分类")
Assert.eq(db_row.percent, 37)
Assert.eq(db_row.md5, "digest")
Assert.eq(fetch_calls, 1)
Assert.eq(read(cover_path), "new-cover")
Assert.eq(shown[#shown].text, "元数据已更新")

-- 数据库失败不能继续下载封面，更不能谎报更新成功。
db_ok = false
fetch_calls = 0
startAndPick()
Assert.eq(fetch_calls, 0)
Assert.eq(shown[#shown].text, "元数据更新失败")

-- 临时文件改名失败时，旧封面必须仍然完整存在。
db_ok = true
write(cover_path, "old-cover")
write(image_path, "replacement")
local real_rename = os.rename
os.rename = function() return nil, "rename denied" end
startAndPick()
os.rename = real_rename
Assert.eq(read(cover_path), "old-cover")

pcall(os.remove, image_path)
pcall(os.remove, cover_path)
pcall(os.remove, cover_path .. ".part")
