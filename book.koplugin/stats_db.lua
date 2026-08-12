--[[--
从 KOReader statistics.sqlite3 读取书籍与 page_stat，
并解析为服务端 filename（书库相对路径）。

@module koplugin.book.stats_db
--]]

local DataStorage = require("datastorage")
local logger = require("logger")
local _ = require("gettext")

local StatsDb = {}

local DB_PATH = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
local STATMAP_KEY = "book_plugin_statmap_v2"
local METAMAP_KEY = "book_plugin_meta_v2"
local FILEMAP_KEY = "book_plugin_filemap_v2"

local function openDb()
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok or not SQ3 then
        return nil, _("无 sqlite 模块")
    end
    local attr_ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if attr_ok and lfs and lfs.attributes(DB_PATH, "mode") ~= "file" then
        return nil, _("无统计数据库")
    end
    local conn = SQ3.open(DB_PATH)
    if not conn then
        return nil, _("打开统计库失败")
    end
    return conn
end

local function flushStatisticsToDb()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok or not ReaderUI or not ReaderUI.instance then
        return
    end
    local ui = ReaderUI.instance
    if ui and ui.statistics and ui.statistics.is_doc and ui.statistics.insertDB then
        local flushed, err = pcall(function()
            ui.statistics:insertDB()
        end)
        if flushed then
            logger.dbg("book.stats_db flushed statistics to DB")
        else
            logger.warn("book.stats_db flush failed", err)
        end
    end
end

local function readStatMap()
    local map = G_reader_settings:readSetting(STATMAP_KEY)
    return type(map) == "table" and map or {}
end

local function writeStatMap(map)
    G_reader_settings:saveSetting(STATMAP_KEY, map)
end

--- 打开书时记录 md5 -> filename，供上报解析
local function rememberMd5Filename(md5, filename)
    if type(md5) ~= "string" or md5 == "" then
        return
    end
    if type(filename) ~= "string" or filename == "" then
        return
    end
    filename = filename:match("([^/\\]+)$") or filename
    local map = readStatMap()
    if map[md5] ~= filename then
        map[md5] = filename
        writeStatMap(map)
    end
end

local function partialMd5(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local ok, util = pcall(require, "util")
    if ok and util and util.partialMD5 then
        local mok, md5 = pcall(util.partialMD5, path)
        if mok and type(md5) == "string" and md5 ~= "" then
            return md5
        end
    end
    return nil
end

function StatsDb.rememberPathFilename(path, filename)
    local md5 = partialMd5(path)
    if md5 then
        rememberMd5Filename(md5, filename)
    end
end

--- 用 metamap / filemap / statmap 把 title|md5 解析成 filename
local function buildResolvers()
    local by_md5 = readStatMap()
    local by_title = {}

    local meta = G_reader_settings:readSetting(METAMAP_KEY)
    if type(meta) == "table" then
        for filename, m in pairs(meta) do
            if type(m) == "table" then
                local title = m.bookName or m.title
                if type(title) == "string" and title ~= "" then
                    by_title[title] = filename
                end
            end
        end
    end

    local filemap = G_reader_settings:readSetting(FILEMAP_KEY)
    if type(filemap) == "table" then
        for path, v in pairs(filemap) do
            local filename
            if type(v) == "table" then
                filename = v.filename
            elseif type(v) == "string" then
                filename = v
            end
            if type(filename) == "string" and filename ~= "" then
                local md5 = partialMd5(path)
                if md5 then
                    by_md5[md5] = filename
                end
            end
        end
    end

    return by_md5, by_title
end

local function resolveFilename(book, by_md5, by_title)
    if type(book.md5) == "string" and book.md5 ~= "" and by_md5[book.md5] then
        return by_md5[book.md5]
    end
    if type(book.title) == "string" and book.title ~= "" and by_title[book.title] then
        return by_title[book.title]
    end
    return nil
end

--- @return table[] books（含 filename；解析失败的条目被丢弃）
function StatsDb.bookData()
    flushStatisticsToDb()
    local conn, err = openDb()
    if not conn then
        logger.dbg("book.stats_db bookData:", err)
        return {}
    end

    local by_md5, by_title = buildResolvers()
    -- 只需解析 filename + 元数据回退；md5 仅本地映射用，不上报
    local result, rows = conn:exec([[
        SELECT id, title, authors, md5
        FROM book
    ]])
    local books = {}
    if rows and rows > 0 and result then
        for i = 1, rows do
            local md5 = result[4][i] or ""
            local title = result[2][i] or ""
            local raw = {
                id = tonumber(result[1][i]) or 0,
                title = title,
                authors = result[3][i] or "",
                md5 = md5,
            }
            local filename = resolveFilename(raw, by_md5, by_title)
            if filename and filename ~= "" then
                raw.filename = filename
                table.insert(books, raw)
            else
                logger.dbg("book.stats_db skip book without filename", title, md5)
            end
        end
    end
    conn:close()
    return books
end

local function filenameById(books, id)
    for _, book in ipairs(books) do
        if book.id == id then
            return book.filename
        end
    end
    return nil
end

--- @param device_id string
--- @param books table[]|nil
function StatsDb.pageStatData(device_id, books)
    books = books or StatsDb.bookData()
    local conn, err = openDb()
    if not conn then
        logger.dbg("book.stats_db pageStatData:", err)
        return {}
    end

    local result, rows = conn:exec([[
        SELECT id_book, page, start_time, duration, total_pages
        FROM page_stat_data
    ]])
    local stats = {}
    if rows and rows > 0 and result then
        for i = 1, rows do
            local book_id = tonumber(result[1][i])
            local filename = filenameById(books, book_id)
            if filename and filename ~= "" then
                local duration = tonumber(result[4][i]) or 0
                local total_pages = tonumber(result[5][i]) or 0
                if duration > 0 and total_pages > 0 then
                    table.insert(stats, {
                        page = tonumber(result[2][i]) or 0,
                        start_time = tonumber(result[3][i]) or 0,
                        duration = duration,
                        total_pages = total_pages,
                        filename = filename,
                        device_id = device_id,
                    })
                end
            end
        end
    end
    conn:close()
    return stats
end

function StatsDb.available()
    local attr_ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not attr_ok or not lfs then
        return false
    end
    return lfs.attributes(DB_PATH, "mode") == "file"
end

return StatsDb
