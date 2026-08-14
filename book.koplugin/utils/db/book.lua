--[[--
books 表：BookRef + 展示元数据 + 统计 md5

@module koplugin.book.utils.db.book
--]]

local JSON = require("json")
local Base = require("utils.db.base")

local BookDB = {}

--- favorite 字段写入 DB 的字符串形式
---@param v any
---@return string|nil
local function favoriteToDb(v)
    if v == nil then
        return nil
    end
    if type(v) == "string" then
        return v
    end
    if type(v) == "number" or type(v) == "boolean" then
        return tostring(v)
    end
    local ok, encoded = pcall(JSON.encode, v)
    if ok and encoded then
        return encoded
    end
    return tostring(v)
end

--- 插入或更新 books 行
---@param row table
---@return boolean
function BookDB.upsert(row)
    if type(row) ~= "table" then
        return false
    end
    Base.ensure()
    local source_id = Base.requireSourceId(row.source_id)
    local stable_id = row.stable_id or row.filename
    if type(stable_id) == "number" then
        stable_id = tostring(stable_id)
    end
    if not source_id or type(stable_id) ~= "string" or stable_id == "" then
        return false
    end
    local book_key = row.book_key
    if type(book_key) ~= "string" or book_key == "" then
        book_key = Base.bookKeyFor(source_id, stable_id)
    end
    if not book_key then
        return false
    end
    local filename = row.filename or stable_id
    if filename ~= nil then
        filename = tostring(filename)
    end
    return Base.exec(
        [[INSERT INTO books (
            book_key, source_id, stable_id, filename, md5, title, authors,
            percent, category, favorite, series, intro, fetched_at
          ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
          ON CONFLICT(book_key) DO UPDATE SET
            source_id=excluded.source_id,
            stable_id=excluded.stable_id,
            filename=COALESCE(excluded.filename, books.filename),
            md5=COALESCE(excluded.md5, books.md5),
            title=excluded.title,
            authors=excluded.authors,
            percent=excluded.percent,
            category=excluded.category,
            favorite=excluded.favorite,
            series=excluded.series,
            intro=excluded.intro,
            fetched_at=excluded.fetched_at;]],
        book_key,
        source_id,
        stable_id,
        filename,
        row.md5,
        row.title,
        row.authors,
        tonumber(row.percent) or 0,
        row.category,
        favoriteToDb(row.favorite),
        row.series,
        row.intro,
        tonumber(row.fetched_at) or os.time()
    ) ~= nil
end

--- 按 book_key 取 books 行
---@param book_key string
---@return Book
function BookDB.get(book_key)
    if type(book_key) ~= "string" or book_key == "" then
        return nil
    end
    Base.ensure()
    local book_key_r, source_id, stable_id, filename, digest, title, authors, percent, category, favorite, series, intro, fetched_at =
        Base.rowexec(
            [[SELECT book_key, source_id, stable_id, filename, md5, title, authors,
                     percent, category, favorite, series, intro, fetched_at
              FROM books WHERE book_key=? LIMIT 1;]],
            book_key
        )
    if not book_key_r then
        return nil
    end
    return {
        book_key = book_key_r,
        source_id = source_id,
        stable_id = stable_id,
        filename = filename,
        md5 = digest,
        title = title,
        authors = authors,
        percent = tonumber(percent) or 0,
        category = category,
        favorite = favorite,
        series = series,
        intro = intro,
        fetched_at = tonumber(fetched_at) or 0,
    }
end

--- 按 filename/stable_id 写入或更新 md5
---@param filename string
---@param digest string
---@param filename_out string|nil
---@param source_id string
---@return boolean
function BookDB.setMd5(filename, digest, filename_out, source_id)
    if type(digest) ~= "string" or digest == "" then
        return false
    end
    if type(filename) ~= "string" or filename == "" then
        return false
    end
    source_id = Base.requireSourceId(source_id)
    if not source_id then
        return false
    end
    Base.ensure()
    filename_out = filename_out or filename
    local existing = Base.rowexec(
        [[SELECT book_key FROM books WHERE filename=? OR stable_id=? LIMIT 1;]],
        filename,
        filename
    )
    if existing then
        return Base.exec(
            [[UPDATE books SET md5=?, filename=? WHERE book_key=?;]],
            digest,
            filename_out,
            existing
        ) ~= nil
    end
    return BookDB.upsert({
        book_key = Base.bookKeyFor(source_id, filename),
        source_id = source_id,
        stable_id = filename,
        filename = filename_out,
        md5 = digest,
        fetched_at = 0,
    })
end

--- 按 book_key 更新 md5（可选同步 filename）
---@param book_key string
---@param digest string
---@param filename string|nil
---@return boolean
function BookDB.setMd5ByKey(book_key, digest, filename)
    if type(book_key) ~= "string" or book_key == "" then
        return false
    end
    if type(digest) ~= "string" or digest == "" then
        return false
    end
    Base.ensure()
    local n = Base.rowexec([[SELECT 1 FROM books WHERE book_key=? LIMIT 1;]], book_key)
    if n then
        if type(filename) == "string" and filename ~= "" then
            return Base.exec(
                [[UPDATE books SET md5=?, filename=? WHERE book_key=?;]],
                digest,
                filename,
                book_key
            ) ~= nil
        end
        return Base.exec([[UPDATE books SET md5=? WHERE book_key=?;]], digest, book_key) ~= nil
    end
    return false
end

--- 指定数据源的 md5 → filename 映射。
---@param source_id string
---@return table<string, string>
function BookDB.md5Map(source_id)
    if type(source_id) ~= "string" or source_id == "" then
        return {}
    end
    Base.ensure()
    local result, nrows = Base.query([[
SELECT md5, filename FROM books
WHERE source_id=? AND md5 IS NOT NULL AND md5 != '' AND filename IS NOT NULL AND filename != ''
ORDER BY fetched_at DESC, book_key ASC;
]], source_id)
    local map = {}
    if result and nrows and nrows > 0 then
        for i = 1, nrows do
            local digest = result[1][i]
            local filename = result[2][i]
            if map[digest] == nil
                and type(digest) == "string" and digest ~= ""
                and type(filename) == "string" and filename ~= "" then
                map[digest] = filename
            end
        end
    end
    return map
end

--- 清空全部书籍展示元数据（保留键与 md5）
---@return boolean
function BookDB.stripMeta()
    Base.ensure()
    return Base.exec([[
UPDATE books SET
  title=NULL, authors=NULL, percent=0, category=NULL,
  favorite=NULL, series=NULL, intro=NULL, fetched_at=0;
]]) ~= nil
end

--- 清空 fetched_at 早于 before_ts 的书籍展示元数据
---@param before_ts number
---@return boolean
function BookDB.expireBefore(before_ts)
    before_ts = tonumber(before_ts) or 0
    Base.ensure()
    return Base.exec([[
UPDATE books SET
  title=NULL, authors=NULL, percent=0, category=NULL,
  favorite=NULL, series=NULL, intro=NULL, fetched_at=0
WHERE fetched_at > 0 AND fetched_at < ?;
]], before_ts) ~= nil
end

return BookDB
