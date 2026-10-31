--[[--
一次性迁移：kavita / bookorbit 由第三方拓展（id `ext.kavita` / `ext.bookorbit`）并入内置源（id 去掉前缀）。

所有带 source_id 列的表、源配置文件、缓存目录、书里记的缓存路径、活跃源与启用表、
首页组件放置里的 id 一并改成新 id；做完在 settings/source.lua 记 `legacy_ext_done`，之后不再扫表。
新 id 下已有同主键行时保留新的，旧残留删除。

@module koplugin.book.source.legacy_ext
--]]

local DB = require("utils.db")
local Paths = require("utils.paths")
local Settings = require("utils.settings")
local lfs = require("libs/libkoreader-lfs")
local logger = require("utils.log")

local LegacyExt = {}

---@type table<string, string>
local RENAMES = { { "ext.kavita", "kavita" }, { "ext.bookorbit", "bookorbit" } }

--- 有 source_id 列的全部表（含 feature 自己的表，不点名）。
---@return string[]
local function sourceTables()
    local tables = {}
    local names, count = DB.query("SELECT name FROM sqlite_master WHERE type='table';")
    for i = 1, count do
        local name = names[1][i]
        local columns, ncols = DB.query("PRAGMA table_info(" .. name .. ");")
        for j = 1, ncols do
            if columns[2][j] == "source_id" then
                tables[#tables + 1] = name
                break
            end
        end
    end
    return tables
end

---@param tables string[]
---@param old string
---@param new string
local function migrateRows(tables, old, new)
    for _idx, name in ipairs(tables) do
        DB.exec("UPDATE OR IGNORE " .. name .. " SET source_id=? WHERE source_id=?;", new, old)
        DB.exec("DELETE FROM " .. name .. " WHERE source_id=?;", old)
    end
    -- 书和章节文件记的是绝对路径，缓存目录改名后要跟着换。
    local from, to = "/cache/" .. old .. "/", "/cache/" .. new .. "/"
    for _idx, name in ipairs({ "books", "chapters" }) do
        DB.exec("UPDATE " .. name .. " SET path=replace(path, ?, ?) WHERE path LIKE ?;",
            from, to, "%" .. from .. "%")
    end
end

--- 目标不存在才改名：新 id 下已有数据时不覆盖。
---@param from string
---@param to string
local function rename(from, to)
    if lfs.attributes(from, "mode") and not lfs.attributes(to, "mode") then
        local ok, err = os.rename(from, to)
        if not ok then logger.warn("book.legacy_ext rename failed", from, to, err) end
    end
end

---@param old string
---@param new string
local function migrateSettings(old, new)
    local source = Settings.get("source")
    if source.active_source == old then source.active_source = new end
    local enabled = source.enabled_sources
    if type(enabled) == "table" and enabled[old] ~= nil then
        if enabled[new] == nil then enabled[new] = enabled[old] end
        enabled[old] = nil
    end
    local home = Settings.get("desktop.pages.home")
    if type(home.home_widgets) == "table" then
        for _idx, item in ipairs(home.home_widgets) do
            if type(item) == "table" and type(item.id) == "string" and item.id:sub(1, #old + 1) == old .. "." then
                item.id = new .. item.id:sub(#old + 1)
            end
        end
        Settings.save("desktop.pages.home")
    end
end

--- 启动时调一次（重复调用只在第一次做事）。
function LegacyExt.run()
    local source = Settings.get("source")
    if source.legacy_ext_done then return end
    local tables = sourceTables()
    for _idx, pair in ipairs(RENAMES) do
        local old, new = pair[1], pair[2]
        migrateRows(tables, old, new)
        rename(Paths.sourcePath(old), Paths.sourcePath(new))
        rename(Paths.sourceCacheDir(old), Paths.sourceCacheDir(new))
        migrateSettings(old, new)
    end
    source.legacy_ext_done = true
    Settings.save("source")
end

return LegacyExt
