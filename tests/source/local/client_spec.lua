--[[-- source.local.client：隐藏项过滤 / 后缀白名单 / 元数据解析缓存 / .moon 拒绝 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local BookRef = require("types.book").BookRef

-- 虚拟目录树：.moon（插件配置/缓存）与 .hidden 都不该被扫进书库
local TREE = {
    ["/books"] = { "a.epub", ".moon", ".hidden", "sub", "note.md", "old.cbr", "x.azw3" },
    ["/books/.moon"] = { "cache" },
    ["/books/.moon/cache"] = { "cached.epub" },
    ["/books/.hidden"] = { "b.epub" },
    ["/books/sub"] = { "c.pdf", "d.djvu" },
}
local DIRS = {
    ["/books"] = true,
    ["/books/.moon"] = true,
    ["/books/.moon/cache"] = true,
    ["/books/.hidden"] = true,
    ["/books/sub"] = true,
}

package.preload["libs/libkoreader-lfs"] = function()
    return {
        dir = function(path)
            local entries = TREE[path] or {}
            local i = 0
            return function()
                i = i + 1
                return entries[i]
            end, {}
        end,
        attributes = function(path)
            if DIRS[path] then
                return { mode = "directory", size = 0, modification = 0 }
            end
            for dir, entries in pairs(TREE) do
                for _, name in ipairs(entries) do
                    if dir .. "/" .. name == path then
                        return { mode = "file", size = 10, modification = 0 }
                    end
                end
            end
            return nil
        end,
    }
end

package.preload["utils.paths"] = function()
    return {
        root = function()
            return "/data/.moon"
        end,
    }
end

local opened = {}
package.preload["document/documentregistry"] = function()
    return {
        hasProvider = function()
            return true
        end,
        openDocument = function(path)
            opened[#opened + 1] = path
            return {
                getProps = function()
                    return { title = "T:" .. path, authors = "A:" .. path, description = "D:" .. path }
                end,
                close = function() end,
            }
        end,
    }
end

local db_rows = {}
local upserts = {}
package.preload["utils.db.book"] = function()
    return {
        get = function(key)
            return db_rows[key]
        end,
        upsert = function(row)
            upserts[#upserts + 1] = row
            return true
        end,
    }
end
package.preload["utils.db.queue"] = function()
    return {
        run = function(worker)
            worker()
        end,
    }
end
package.loaded["source.local.client"] = nil

local Client = require("source.local.client")

-- ── 扫描：隐藏项过滤 + 后缀白名单 + 解析并写缓存 ──────
do
    local result, result_err
    Client.new({ path = "/books" }):listAsync(nil, function(files, err)
        result, result_err = files, err
    end)
    Stubs.flush()

    Assert.is_nil(result_err)
    Assert.is_true(result ~= nil)
    local by_path = {}
    for _, f in ipairs(result) do
        by_path[f.path] = f
    end
    -- 白名单内：epub/md/pdf/djvu 入库
    Assert.is_true(by_path["/books/a.epub"] ~= nil)
    Assert.is_true(by_path["/books/note.md"] ~= nil)
    Assert.is_true(by_path["/books/sub/c.pdf"] ~= nil)
    Assert.is_true(by_path["/books/sub/d.djvu"] ~= nil)
    Assert.eq(#result, 4)
    -- 白名单外：cbr/azw3 被限定排除
    Assert.is_nil(by_path["/books/old.cbr"])
    Assert.is_nil(by_path["/books/x.azw3"])
    -- 隐藏目录数据不入库
    Assert.is_nil(by_path["/books/.moon/cache/cached.epub"])
    Assert.is_nil(by_path["/books/.hidden/b.epub"])
    -- 每本都解析并缓存
    Assert.eq(#opened, 4)
    Assert.eq(by_path["/books/a.epub"].title, "T:/books/a.epub")
    Assert.eq(by_path["/books/a.epub"].authors, "A:/books/a.epub")
    Assert.eq(by_path["/books/a.epub"].intro, "D:/books/a.epub")
    Assert.eq(#upserts, 4)
    Assert.eq(upserts[1].source_id, "local")
    Assert.is_true(upserts[1].fetched_at > 0)
end

-- ── 缓存命中：跳过解析 ──────────────────────────────
do
    opened = {}
    upserts = {}
    for _, path in ipairs({ "/books/a.epub", "/books/note.md", "/books/sub/c.pdf", "/books/sub/d.djvu" }) do
        db_rows[BookRef.new("local", path).book_key] = {
            title = "cached:" .. path,
            authors = "ca",
            intro = "ci",
        }
    end
    local result
    Client.new({ path = "/books" }):listAsync(nil, function(files)
        result = files
    end)
    Stubs.flush()
    Assert.eq(#result, 4)
    Assert.eq(#opened, 0)
    Assert.eq(#upserts, 0)
    Assert.eq(result[1].title, "cached:/books/a.epub")
end

-- ── 书库目录不得落在插件数据目录内 ────────────────────
do
    local result, result_err
    Client.new({ path = "/data/.moon" }):listAsync(nil, function(files, err)
        result, result_err = files, err
    end)
    Stubs.flush()
    Assert.is_nil(result)
    Assert.eq(result_err, "书库目录不能是插件数据目录")

    result, result_err = nil, nil
    Client.new({ path = "/data/.moon/cache" }):listAsync(nil, function(files, err)
        result, result_err = files, err
    end)
    Stubs.flush()
    Assert.is_nil(result)
    Assert.eq(result_err, "书库目录不能是插件数据目录")
end

for _, name in ipairs({
    "libs/libkoreader-lfs",
    "utils.paths",
    "document/documentregistry",
    "utils.db.book",
    "utils.db.queue",
    "source.local.client",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
