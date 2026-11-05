--[[--
Kavita 一次性迁移：卷行继承容器元数据并退出书架。

@module tests.source.kavita.migration_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

local db_path = Config.dir() .. "/kavita_migration_spec.sqlite3"
local state_path = Config.dir() .. "/settings/moonsource_kavita_meta.lua"
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
for _idx, suffix in ipairs({ "", ".old" }) do os.remove(state_path .. suffix) end

package.loaded["utils.paths"] = nil
package.preload["utils.paths"] = function()
    return { dbPath = function() return db_path end, ensureSettings = function() end,
        sanitizeSourceId = function(id) return id end }
end

local DB = require("utils.db")
require("book.books_db")
Assert.not_nil(DB.open())

local function insert(source_id, stable_id, authors, intro, deleted, sync_status, path)
    Assert.is_true(DB.exec([[
        INSERT INTO books (source_id, stable_id, title, authors, intro, deleted, sync_status, path)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
    ]], source_id, stable_id, "书 " .. stable_id, authors, intro, deleted, sync_status, path))
end

insert("kavita", "10", "容器作者", "容器简介", 0, 1, nil)
insert("kavita", "10:100", nil, "", 0, 0, "/books/volume.epub")
insert("kavita", "10:101", "卷作者", "卷简介", 0, 0, nil)
insert("kavita", "10:102", nil, nil, 1, 0, nil)
insert("other", "10:100", nil, "", 0, 0, nil)

local cfg = { base_url = "http://kavita/", api_key = "key" }
package.loaded["utils.settings"] = {
    getSource = function() return cfg end,
    saveSource = function() end,
}
package.loaded["source.base"] = {
    loadMeta = function(id) return { id = id, name = "Kavita", type = "book" } end,
    capabilities = function() return {} end,
    defer = function(_self, cb, ...)
        local args = { ... }
        cb(unpack(args))
        return { cancel = function() end }
    end,
}
package.loaded["source.kavita.client"] = { new = function(options) return options end }
package.loaded["source.kavita.annotation"] = {}
package.loaded["source.kavita.position"] = {}
package.loaded["source.kavita.stats"] = {}
package.loaded["source.kavita.cache"] = { resetShelf = function() end }
package.loaded["source.kavita.volume_list"] = {}
package.loaded["book.note.normalize"] = {}

local Source = dofile(Config.root() .. "/book.koplugin/source/kavita/init.lua")
Source.new()

local function row(source_id, stable_id)
    local authors, intro, deleted, sync_status, path = DB.rowexec([[
        SELECT authors, intro, deleted, sync_status, path FROM books
        WHERE source_id=? AND stable_id=?;
    ]], source_id, stable_id)
    return authors, intro, tonumber(deleted), tonumber(sync_status), path
end

local authors, intro, deleted, sync_status, path = row("kavita", "10:100")
Assert.eq(authors, "容器作者")
Assert.eq(intro, "容器简介")
Assert.eq(deleted, 1, "卷行从书架隐藏")
Assert.eq(sync_status, 1, "迁移后的远端卷行标为已同步")
Assert.eq(path, "/books/volume.epub", "保留已下载文件路径")

authors, intro, deleted, sync_status = row("kavita", "10:101")
Assert.eq(authors, "卷作者", "保留已有作者")
Assert.eq(intro, "卷简介", "保留已有简介")
Assert.eq(deleted, 1, "所有旧卷行都从书架隐藏")
Assert.eq(sync_status, 1)

authors, intro, deleted, sync_status = row("kavita", "10:102")
Assert.eq(authors, "容器作者", "已隐藏卷行也补齐元数据")
Assert.eq(intro, "容器简介")
Assert.eq(deleted, 1)
Assert.eq(sync_status, 0, "不改原本已隐藏行的脏状态")

authors, intro, deleted = row("other", "10:100")
Assert.is_nil(authors, "迁移只影响 Kavita")
Assert.eq(intro, "")
Assert.eq(deleted, 0)

local state = require("luasettings"):open(
    require("datastorage"):getSettingsDir() .. "/moonsource_kavita_meta.lua")
Assert.eq(tonumber(state:readSetting("schema_version")), 1)

insert("kavita", "10:103", nil, nil, 0, 0, nil)
Source.new()
local _, _, still_visible = row("kavita", "10:103")
Assert.eq(still_visible, 0, "schema_version 阻止重复迁移")

DB.close()
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
for _idx, suffix in ipairs({ "", ".old" }) do os.remove(state_path .. suffix) end

return true
