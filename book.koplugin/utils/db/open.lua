--[[--
opens 表：本地打开记录（一书一条，身份 = source_id + stable_id）

@module koplugin.book.utils.db.open
--]]

local Base = require("utils.db.base")

local OpenDB = {}

--- 插入或更新本地打开记录
---@param row { source_id: string, stable_id: string, path: string, chapter_idx: number|nil, last_open: number|nil }
---@return boolean
function OpenDB.upsert(row)
    if type(row) ~= "table" then
        return false
    end
    local source_id = Base.requireSourceId(row.source_id)
    if not source_id or type(row.stable_id) ~= "string" or row.stable_id == "" then
        return false
    end
    if type(row.path) ~= "string" or row.path == "" then
        return false
    end
    Base.ensure()
    return Base.exec(
        [[INSERT INTO opens (source_id, stable_id, path, chapter_idx, last_open)
          VALUES (?,?,?,?,?)
          ON CONFLICT(source_id, stable_id) DO UPDATE SET
            path=excluded.path,
            chapter_idx=excluded.chapter_idx,
            last_open=excluded.last_open;]],
        source_id,
        row.stable_id,
        row.path,
        row.chapter_idx,
        tonumber(row.last_open) or os.time()
    ) ~= nil
end

--- 按 (source_id, stable_id) 取打开记录
---@param source_id string
---@param stable_id string
---@return table|nil
function OpenDB.get(source_id, stable_id)
    source_id = Base.requireSourceId(source_id)
    if not source_id or type(stable_id) ~= "string" or stable_id == "" then
        return nil
    end
    Base.ensure()
    local s_id, st_id, path, chapter_idx, last_open = Base.rowexec(
        [[SELECT source_id, stable_id, path, chapter_idx, last_open
          FROM opens WHERE source_id=? AND stable_id=? LIMIT 1;]],
        source_id, stable_id
    )
    if not s_id then
        return nil
    end
    return {
        source_id = s_id,
        stable_id = st_id,
        path = path,
        chapter_idx = chapter_idx ~= nil and tonumber(chapter_idx) or nil,
        last_open = tonumber(last_open) or 0,
    }
end

--- 按本地路径取打开记录（阅读器只有物理路径，需要反查身份）。
---@param path string
---@return table|nil
function OpenDB.getByPath(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    Base.ensure()
    local source_id, stable_id, path_r, chapter_idx, last_open = Base.rowexec(
        [[SELECT source_id, stable_id, path, chapter_idx, last_open
          FROM opens WHERE path=? LIMIT 1;]],
        path
    )
    if not source_id then
        return nil
    end
    return {
        source_id = source_id,
        stable_id = stable_id,
        path = path_r,
        chapter_idx = chapter_idx ~= nil and tonumber(chapter_idx) or nil,
        last_open = tonumber(last_open) or 0,
    }
end

--- 全部打开记录。
---@return table[]
function OpenDB.all()
    Base.ensure()
    local result, nrows = Base.query(
        [[SELECT source_id, stable_id, path, chapter_idx, last_open FROM opens;]]
    )
    local rows = {}
    if result and nrows and nrows > 0 then
        for i = 1, nrows do
            rows[#rows + 1] = {
                source_id = result[1][i],
                stable_id = result[2][i],
                path = result[3][i],
                chapter_idx = result[4][i] ~= nil and tonumber(result[4][i]) or nil,
                last_open = tonumber(result[5][i]) or 0,
            }
        end
    end
    return rows
end

--- 某源最近打开记录（联 books 取展示元数据）。
---@param source_id string
---@param limit number|nil
---@return table[] { stable_id, last_open, title, authors, category, intro, percent }
function OpenDB.recentBySource(source_id, limit)
    source_id = Base.requireSourceId(source_id)
    if not source_id then
        return {}
    end
    Base.ensure()
    local result, nrows = Base.query(
        [[SELECT o.stable_id, o.last_open, b.title, b.authors, b.category, b.intro, b.percent
          FROM opens o LEFT JOIN books b
            ON b.source_id = o.source_id AND b.stable_id = o.stable_id
          WHERE o.source_id=?
          ORDER BY o.last_open DESC
          LIMIT ?;]],
        source_id,
        tonumber(limit) or 24
    )
    local rows = {}
    if result and nrows and nrows > 0 then
        for i = 1, nrows do
            rows[#rows + 1] = {
                stable_id = result[1][i],
                last_open = tonumber(result[2][i]) or 0,
                title = result[3][i],
                authors = result[4][i],
                category = result[5][i],
                intro = result[6][i],
                percent = tonumber(result[7][i]) or 0,
            }
        end
    end
    return rows
end

--- 删除一条打开记录
---@param source_id string
---@param stable_id string
---@return boolean
function OpenDB.delete(source_id, stable_id)
    source_id = Base.requireSourceId(source_id)
    if not source_id or type(stable_id) ~= "string" or stable_id == "" then
        return false
    end
    Base.ensure()
    return Base.exec(
        [[DELETE FROM opens WHERE source_id=? AND stable_id=?;]],
        source_id, stable_id
    ) ~= nil
end

--- 清空全部打开记录
---@return boolean
function OpenDB.clear()
    Base.ensure()
    return Base.exec([[DELETE FROM opens;]]) ~= nil
end

return OpenDB
