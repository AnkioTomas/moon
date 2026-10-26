--[[--
导入 KOReader 自带统计插件的阅读记录（设置目录下 statistics.sqlite3 的 page_stat_data）。

KOReader 的库只读。书按内容 partialMD5 对上书库在架书（books.md5，缺 md5 的按 path 现算），
对不上再按书名唯一匹配；md5 对上多本、书名重复或都对不上的书跳过。
导入行记为 StatsDB.IMPORTED：历史数据只进本地统计，不推给任何源，源 pull 清理已同步行时也不删。
去重按分钟：本插件已有记录覆盖的分钟不再导入。KOReader 统计插件与本插件读书时同时计时，
同一段阅读两边各有一份；导入行自己也会覆盖对应分钟，所以重复导入不会重复计。

@module koplugin.book.book.stats_koreader
--]]

local BookDB = require("book.books_db")
local DB = require("utils.db")
local StatsDB = require("book.stats_db")
local Text = require("utils.text")

local KoreaderStats = {}

--- 键唯一才记书，重复的记 false：同一文件在书库里有两条时，记录导进哪本都会和另一本的本地记录算重。
---@param index table
---@param key string
---@param book Book
local function addUnique(index, key, book)
    index[key] = index[key] == nil and book or false
end

--- 书库在架书按 md5 与书名索引；md5 或书名重复的记 false，对不上就不猜。
--- 缺 md5 的书要读文件现算，只在已知 md5 对不上时算一次。
---@return fun(md5: string|nil, title: string|nil): Book|false|nil
local function libraryIndex()
    local by_md5, by_title, unhashed = {}, {}, {}
    for _idx, book in ipairs(BookDB.listLibrary()) do
        if book.md5 then
            addUnique(by_md5, book.md5, book)
        elseif book.path then
            unhashed[#unhashed + 1] = book
        end
        local title = Text.trim(book.title or "")
        if title ~= "" then addUnique(by_title, title, book) end
    end
    return function(md5, title)
        if md5 and by_md5[md5] == nil and unhashed then
            local partialMD5 = require("util").partialMD5
            for _idx, book in ipairs(unhashed) do
                local digest = partialMD5(book.path)
                ---@cast digest string|nil
                if digest then addUnique(by_md5, digest, book) end
            end
            unhashed = nil
        end
        if md5 and by_md5[md5] ~= nil then return by_md5[md5] end
        return by_title[Text.trim(title or "")]
    end
end

--- 一本书本地记录覆盖的分钟集合。
---@param book Book
---@return table<integer, true>
local function coveredMinutes(book)
    local minutes = {}
    for _idx, span in ipairs(StatsDB.localSpans(book.source_id, book.stable_id)) do
        for m = math.floor(span[1] / 60), math.floor((span[2] - 1) / 60) do minutes[m] = true end
    end
    return minutes
end

---@param minutes table<integer, true>
---@param start integer
---@param duration integer
---@return boolean
local function overlaps(minutes, start, duration)
    for m = math.floor(start / 60), math.floor((start + duration - 1) / 60) do
        if minutes[m] then return true end
    end
    return false
end

--- 把一本 KOReader 书的记录写进对上的书库书，返回写入行数；写库失败返回 nil。
---@param conn SQLiteConnection KOReader 统计库
---@param id_book any
---@param book Book
---@return integer|nil
local function importBook(conn, id_book, book)
    local stmt = conn:prepare([[SELECT page, start_time, duration, total_pages FROM page_stat_data
        WHERE id_book=? AND duration>0 ORDER BY start_time;]])
    local rows, nrows = stmt:bind(id_book):resultset()
    stmt:close()
    local minutes = coveredMinutes(book)
    local imported = 0
    for i = 1, nrows do
        local start, duration = tonumber(rows[2][i]), tonumber(rows[3][i])
        if not overlaps(minutes, start, duration) then
            if not StatsDB.add({
                source_id = book.source_id,
                stable_id = book.stable_id,
                record_type = "page",
                page = tonumber(rows[1][i]),
                start_time = start,
                duration = duration,
                total_pages = tonumber(rows[4][i]),
            }, StatsDB.IMPORTED) then
                return nil
            end
            imported = imported + 1
        end
    end
    return imported
end

---@param conn SQLiteConnection
---@return { books: integer, rows: integer, unmatched: integer }|nil
local function importFrom(conn)
    local ko, nbooks = conn:exec([[SELECT id, title, md5 FROM book b
        WHERE EXISTS (SELECT 1 FROM page_stat_data WHERE id_book=b.id AND duration>0);]])
    local match = libraryIndex()
    return DB.transaction(function()
        local counts = { books = 0, rows = 0, unmatched = 0 }
        for i = 1, nbooks do
            local book = match(ko[3][i], ko[2][i])
            if book then
                local imported = importBook(conn, ko[1][i], book)
                if not imported then return nil end
                if imported > 0 then counts.books = counts.books + 1 end
                counts.rows = counts.rows + imported
            else
                counts.unmatched = counts.unmatched + 1
            end
        end
        return counts
    end)
end

--- 导入 KOReader 统计插件的逐页阅读记录到 reading_stats。
---@param path string|nil 默认 KOReader 设置目录下的 statistics.sqlite3
---@return { books: integer, rows: integer, unmatched: integer }|nil counts books=有新记录的书数，unmatched=书库里对不上的书数
---@return "missing"|"failed"|nil err missing=没有 KOReader 统计库，failed=写库失败（已回滚）
function KoreaderStats.import(path)
    path = path or (require("datastorage"):getSettingsDir() .. "/statistics.sqlite3")
    local file = io.open(path, "rb")
    if not file then return nil, "missing" end
    file:close()
    local conn = require("lua-ljsqlite3/init").open(path, "ro")
    -- 连接是外部资源：出错也要先关掉再把错误原样抛给入口。
    local ok, counts = pcall(importFrom, conn)
    conn:close()
    if not ok then error(counts, 0) end
    if not counts then return nil, "failed" end
    return counts
end

return KoreaderStats
