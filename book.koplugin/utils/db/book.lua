--[[--
books 表：BookRef + 展示元数据 + 统计 md5

@module koplugin.book.utils.db.book
--]]

local Base = require("utils.db.base")

local BookDB = {}

--- favorite 字段写入 DB 的字符串形式（契约：nil / string / boolean，见 types/book.lua）
---@param v nil|string|boolean
---@return string|nil
local function favoriteToDb(v)
    if v == nil then
        return nil
    end
    if type(v) == "string" then
        return v
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
    local stable_id = row.stable_id
    if type(stable_id) == "number" then
        stable_id = tostring(stable_id)
    end
    if not source_id or type(stable_id) ~= "string" or stable_id == "" then
        return false
    end
    return Base.exec(
        [[INSERT INTO books (
            source_id, stable_id, md5, title, authors,
            percent, category, favorite, series, intro, fetched_at
          ) VALUES (?,?,?,?,?,?,?,?,?,?,?)
          ON CONFLICT(source_id, stable_id) DO UPDATE SET
            md5=COALESCE(excluded.md5, books.md5),
            title=excluded.title,
            authors=excluded.authors,
            percent=excluded.percent,
            category=excluded.category,
            favorite=excluded.favorite,
            series=excluded.series,
            intro=excluded.intro,
            fetched_at=excluded.fetched_at;]],
        source_id,
        stable_id,
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

--- 按 (source_id, stable_id) 取 books 行
---@param source_id string
---@param stable_id string
---@return Book|nil
function BookDB.get(source_id, stable_id)
    source_id = Base.requireSourceId(source_id)
    if not source_id or type(stable_id) ~= "string" or stable_id == "" then
        return nil
    end
    Base.ensure()
    local source_id_r, stable_id_r, digest, title, authors, percent, category, favorite, series, intro, fetched_at =
        Base.rowexec(
            [[SELECT source_id, stable_id, md5, title, authors,
                     percent, category, favorite, series, intro, fetched_at
              FROM books WHERE source_id=? AND stable_id=? LIMIT 1;]],
            source_id,
            stable_id
        )
    if not source_id_r then
        return nil
    end
    return {
        source_id = source_id_r,
        stable_id = stable_id_r,
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

--- 按 (source_id, md5) 找已入库的行（本地源用内容摘要识别文件改名/移动）。
---@param source_id string
---@param md5 string
---@return Book|nil
function BookDB.getByMd5(source_id, md5)
    source_id = Base.requireSourceId(source_id)
    if not source_id or type(md5) ~= "string" or md5 == "" then
        return nil
    end
    Base.ensure()
    local source_id_r, stable_id_r, digest, title, authors, percent, category, favorite, series, intro, fetched_at =
        Base.rowexec(
            [[SELECT source_id, stable_id, md5, title, authors,
                     percent, category, favorite, series, intro, fetched_at
              FROM books WHERE source_id=? AND md5=? LIMIT 1;]],
            source_id,
            md5
        )
    if not source_id_r then
        return nil
    end
    return {
        source_id = source_id_r,
        stable_id = stable_id_r,
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

--- 改名/移动：把某本书的 stable_id 换成新值（本地源文件路径变化，身份仍由 md5 认定）。
--- category/series 由文件所在目录派生，随新位置一并刷新（传 nil 即清除）。
--- 同步改写 opens / reading_stats / pending_progress 里对旧 stable_id 的引用。
---@param source_id string
---@param old_stable_id string
---@param new_stable_id string
---@param category string|nil
---@param series string|nil
---@return boolean
function BookDB.renameStableId(source_id, old_stable_id, new_stable_id, category, series)
    source_id = Base.requireSourceId(source_id)
    if not source_id then
        return false
    end
    if type(old_stable_id) ~= "string" or old_stable_id == "" then
        return false
    end
    if type(new_stable_id) ~= "string" or new_stable_id == "" then
        return false
    end
    if old_stable_id == new_stable_id then
        return true
    end
    Base.ensure()
    -- 四表身份必须同生共死：包事务，任何一步失败整体回滚
    if not Base.exec([[BEGIN IMMEDIATE;]]) then
        return false
    end
    local ok = Base.exec(
        [[UPDATE books SET stable_id=?, category=?, series=? WHERE source_id=? AND stable_id=?;]],
        new_stable_id, category, series, source_id, old_stable_id
    ) and Base.exec(
        [[UPDATE opens SET stable_id=? WHERE source_id=? AND stable_id=?;]],
        new_stable_id, source_id, old_stable_id
    ) and Base.exec(
        [[UPDATE reading_stats SET stable_id=? WHERE source_id=? AND stable_id=?;]],
        new_stable_id, source_id, old_stable_id
    ) and Base.exec(
        [[UPDATE pending_progress SET stable_id=? WHERE source_id=? AND stable_id=?;]],
        new_stable_id, source_id, old_stable_id
    )
    Base.exec(ok and [[COMMIT;]] or [[ROLLBACK;]])
    return ok == true
end

--- 取某源全部 stable_id
---@param source_id string
---@return string[]
function BookDB.stableIdsBySource(source_id)
    source_id = Base.requireSourceId(source_id)
    if not source_id then
        return {}
    end
    Base.ensure()
    local result, nrows = Base.query([[SELECT stable_id FROM books WHERE source_id=?;]], source_id)
    local out = {}
    if result and nrows and nrows > 0 then
        for i = 1, nrows do
            out[#out + 1] = result[1][i]
        end
    end
    return out
end

--- 按源分页查询书库（图书馆直查数据库；排序与扫盘序一致 = stable_id）。
---@param source_id string
---@param opts { category: string|nil, series: string|nil, search: string|nil, limit: number|nil, offset: number|nil }|nil
---@return table[] rows, number count
function BookDB.listBySource(source_id, opts)
    source_id = Base.requireSourceId(source_id)
    if not source_id then
        return {}, 0
    end
    opts = opts or {}
    Base.ensure()
    local where = "source_id=?"
    local args = { source_id }
    if type(opts.category) == "string" and opts.category ~= "" then
        where = where .. " AND category=?"
        args[#args + 1] = opts.category
    end
    if type(opts.series) == "string" and opts.series ~= "" then
        where = where .. " AND series=?"
        args[#args + 1] = opts.series
    end
    if type(opts.search) == "string" and opts.search ~= "" then
        -- 转义 LIKE 通配符：用户输入的 % _ 是字面量
        where = where .. [[ AND (title LIKE ? ESCAPE '\' OR authors LIKE ? ESCAPE '\' OR stable_id LIKE ? ESCAPE '\')]]
        local like = "%" .. opts.search:gsub("([%%_\\])", "\\%1") .. "%"
        args[#args + 1] = like
        args[#args + 1] = like
        args[#args + 1] = like
    end
    local total = Base.rowexec(
        "SELECT COUNT(*) FROM books WHERE " .. where .. ";",
        unpack(args)
    )
    total = tonumber(total) or 0
    if total == 0 then
        return {}, 0
    end
    local limit = tonumber(opts.limit) or 0
    local offset = tonumber(opts.offset) or 0
    local sel = [[SELECT stable_id, title, authors, percent,
                        category, series, intro, fetched_at FROM books WHERE ]]
        .. where .. " ORDER BY stable_id"
    if limit > 0 then
        sel = sel .. " LIMIT ? OFFSET ?"
        args[#args + 1] = limit
        args[#args + 1] = math.max(0, offset)
    end
    local result, nrows = Base.query(sel .. ";", unpack(args))
    local rows = {}
    if result and nrows and nrows > 0 then
        for i = 1, nrows do
            rows[#rows + 1] = {
                source_id = source_id,
                stable_id = result[1][i],
                title = result[2][i],
                authors = result[3][i],
                percent = tonumber(result[4][i]) or 0,
                category = result[5][i],
                series = result[6][i],
                intro = result[7][i],
                fetched_at = tonumber(result[8][i]) or 0,
            }
        end
    end
    return rows, total
end

--- 某源的书库分类列表（DISTINCT category，非空，字典序）。
---@param source_id string
---@return string[]
function BookDB.categoriesBySource(source_id)
    source_id = Base.requireSourceId(source_id)
    if not source_id then
        return {}
    end
    Base.ensure()
    local result, nrows = Base.query(
        [[SELECT DISTINCT category FROM books
          WHERE source_id=? AND category IS NOT NULL AND category<>''
          ORDER BY category;]],
        source_id
    )
    local out = {}
    if result and nrows and nrows > 0 then
        for i = 1, nrows do
            out[#out + 1] = result[1][i]
        end
    end
    return out
end

--- 某源的书库系列列表（DISTINCT series，非空，字典序）。
---@param source_id string
---@return string[]
function BookDB.seriesBySource(source_id)
    source_id = Base.requireSourceId(source_id)
    if not source_id then
        return {}
    end
    Base.ensure()
    local result, nrows = Base.query(
        [[SELECT DISTINCT series FROM books
          WHERE source_id=? AND series IS NOT NULL AND series<>''
          ORDER BY series;]],
        source_id
    )
    local out = {}
    if result and nrows and nrows > 0 then
        for i = 1, nrows do
            out[#out + 1] = result[1][i]
        end
    end
    return out
end

--- 按 (source_id, stable_id) 删除 books 行（不动 reading_stats）
---@param source_id string
---@param stable_id string
---@return boolean
function BookDB.remove(source_id, stable_id)
    source_id = Base.requireSourceId(source_id)
    if not source_id or type(stable_id) ~= "string" or stable_id == "" then
        return false
    end
    Base.ensure()
    return Base.exec(
        [[DELETE FROM books WHERE source_id=? AND stable_id=?;]],
        source_id, stable_id
    ) ~= nil
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
