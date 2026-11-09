--[[--
图书馆文件夹视图：子文件夹先列（按名称）；约定 cover.jpg/png 优先，否则用夹内最近阅读书封面；再列目录里直接放的书。真实 sqlite。

@module tests.book.catalog_folder_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")
local Stubs = require("support.stubs")

local sqlite_ok = pcall(require, "lua-ljsqlite3/init")
if not sqlite_ok then
    Assert.skip("当前离线环境没有 ljsqlite3 Lua 模块")
end

local db_path = Config.dir() .. "/catalog_folder_spec.sqlite3"
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end

package.loaded["utils.paths"] = nil
package.preload["utils.paths"] = function()
    return {
        dbPath = function() return db_path end,
        ensureSettings = function() end,
        sanitizeSourceId = function(id) return id end,
        coverPath = function(stable_id, id)
            return Config.dir() .. "/covers/" .. tostring(id) .. "/" .. tostring(stable_id):gsub("/", "_") .. ".png"
        end,
    }
end
package.preload["utils.settings"] = function()
    return { get = function() return { library_mixed = false } end }
end
package.preload["source.registry"] = function()
    return { list = function() return {} end, listEnabled = function() return {} end, resolve = function() return nil end }
end
local mods = { "utils.db", "utils.event", "book.books_db", "book.chapters_db", "book.progress_db", "book.catalog" }
for _idx, name in ipairs(mods) do package.loaded[name] = nil end

local Base = require("utils.db")
local BookDB = require("book.books_db")
require("book.progress_db")
local Catalog = require("book.catalog")
Assert.not_nil(Base.open())

local lfs = require("libs/libkoreader-lfs")
local root = Config.dir() .. "/folder_spec_root"
os.execute("rm -rf '" .. root .. "' && mkdir -p '" .. root .. "/科幻/三体' '" .. root .. "/Alpha'")
local f = io.open(root .. "/科幻/cover.png", "wb")
f:write("x")
f:close()
Assert.is_true(lfs.attributes(root .. "/科幻/cover.png", "mode") == "file")

local function add(rel)
    local path = root .. "/" .. rel
    Assert.is_true(BookDB.upsertRemote({ source_id = "local", stable_id = path, title = rel, path = path,
        deleted = 0, inserted_at = 1 }, false, true))
end
add("top.epub")
add("Alpha/a.epub")
add("科幻/b.epub")
add("科幻/三体/c.epub")
add("科幻/三体/d.epub")

local function page(dir, n, size)
    local out
    Catalog.folderPageAsync("local", { dir = dir, page = n, page_size = size or 10, sort = "title" },
        function(res) out = res end)
    Stubs.flush()
    return out
end

local res = page(root, 1)
Assert.eq(res.count, 3, "两个子文件夹 + 一本直接放的书")
Assert.eq(res.data[1].title, "Alpha")
Assert.is_true(res.data[1].is_folder)
Assert.eq(res.data[1].cover, nil, "没约定封面、夹内书也没封面时仍为空")
Assert.eq(res.data[2].title, "科幻")
Assert.eq(res.data[2].cover, root .. "/科幻/cover.png", "目录里的 cover.png 当文件夹封面")
Assert.eq(res.data[3].title, "top.epub")

-- 无约定封面时：夹内最近阅读（含子目录）那本有封面的书顶上
local alpha = root .. "/Alpha/a.epub"
local nested = root .. "/科幻/三体/c.epub"
Assert.is_true(BookDB.upsertRemote({
    source_id = "local", stable_id = alpha, title = "Alpha/a.epub", path = alpha,
    cover = "file://" .. alpha .. ".cover", read_at = 100, deleted = 0, inserted_at = 1,
}, false, true))
Assert.is_true(BookDB.upsertRemote({
    source_id = "local", stable_id = nested, title = "科幻/三体/c.epub", path = nested,
    cover = "file://" .. nested .. ".cover", read_at = 200, deleted = 0, inserted_at = 1,
}, false, true))
res = page(root, 1)
Assert.eq(res.data[1].cover, "file://" .. alpha .. ".cover", "Alpha 无 cover.jpg，用夹内最近阅读书封面")
Assert.eq(res.data[2].cover, root .. "/科幻/cover.png", "约定封面压过最近阅读书封面")

res = page(root .. "/科幻", 1)
Assert.eq(res.count, 2, "三体文件夹 + b.epub，三体里的书不算直接子项")
Assert.is_true(res.data[1].is_folder)
Assert.eq(res.data[1].cover, "file://" .. nested .. ".cover",
    "三体无约定封面，用子目录里最近阅读书封面")
Assert.eq(res.data[2].title, "科幻/b.epub")

-- 跨页：文件夹排满第一页后，书从第二页开始
res = page(root, 2, 2)
Assert.eq(#res.data, 1)
Assert.eq(res.data[1].title, "top.epub")

-- WebDAV 远端还没下载的书 path 为空，按下载后会在的 root/相对路径归入文件夹
Assert.is_true(BookDB.upsertRemote({ source_id = "local", stable_id = "webdav://儿童/笑猫/x.epub", title = "x",
    deleted = 0, inserted_at = 1 }, false, true))
local function pageRoot(dir)
    local out
    Catalog.folderPageAsync("local", { dir = dir, root = root, page = 1, page_size = 10, sort = "title" },
        function(r) out = r end)
    Stubs.flush()
    return out
end
res = pageRoot(root)
local names = {}
for _idx, e in ipairs(res.data) do names[e.title] = true end
Assert.is_true(names["儿童"], "未下载的 webdav 书所在文件夹也要列出")
res = pageRoot(root .. "/儿童/笑猫")
Assert.eq(res.count, 1)
Assert.eq(res.data[1].title, "x")

Base.close()
os.execute("rm -rf '" .. root .. "'")
for _idx, name in ipairs(mods) do package.loaded[name] = nil end
package.preload["utils.paths"] = nil
package.loaded["utils.paths"] = nil
package.preload["utils.settings"], package.preload["source.registry"] = nil, nil
package.loaded["utils.settings"], package.loaded["source.registry"] = nil, nil
