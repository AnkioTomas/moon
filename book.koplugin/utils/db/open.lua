--[[--
opens 表：本地路径 → BookRef + chapter_idx

@module koplugin.book.utils.db.open
--]]

local Base = require("utils.db.base")

local OpenDB = {}

--- 插入或更新本地打开记录
---@param path string
---@param row { book_key: string, source_id: string, stable_id: string, chapter_idx: number|nil, last_open: number|nil }
---@return boolean
function OpenDB.upsert(path, row)
    if type(path) ~= "string" or path == "" or type(row) ~= "table" then
        return false
    end
    if not row.book_key or not row.source_id or not row.stable_id then
        return false
    end
    local source_id = Base.requireSourceId(row.source_id)
    if not source_id then
        return false
    end
    Base.ensure()
    return Base.exec(
        [[INSERT INTO opens (path, book_key, source_id, stable_id, chapter_idx, last_open)
          VALUES (?,?,?,?,?,?)
          ON CONFLICT(path) DO UPDATE SET
            book_key=excluded.book_key,
            source_id=excluded.source_id,
            stable_id=excluded.stable_id,
            chapter_idx=excluded.chapter_idx,
            last_open=excluded.last_open;]],
        path,
        tostring(row.book_key),
        source_id,
        tostring(row.stable_id),
        row.chapter_idx,
        tonumber(row.last_open) or os.time()
    ) ~= nil
end

--- 按本地路径取打开记录
---@param path string
---@return table|nil
function OpenDB.get(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    Base.ensure()
    local p, book_key, source_id, stable_id, chapter_idx, last_open = Base.rowexec(
        [[SELECT path, book_key, source_id, stable_id, chapter_idx, last_open FROM opens WHERE path=? LIMIT 1;]],
        path
    )
    if not p then
        return nil
    end
    return {
        path = p,
        book_key = book_key,
        source_id = source_id,
        stable_id = stable_id,
        chapter_idx = chapter_idx ~= nil and tonumber(chapter_idx) or nil,
        last_open = tonumber(last_open) or 0,
    }
end

--- 全部打开记录（path → row）
---@return table<string, table>
function OpenDB.all()
    Base.ensure()
    local result, nrows = Base.query(
        [[SELECT path, book_key, source_id, stable_id, chapter_idx, last_open FROM opens;]]
    )
    local map = {}
    if result and nrows and nrows > 0 then
        for i = 1, nrows do
            local path = result[1][i]
            if type(path) == "string" then
                map[path] = {
                    book_key = result[2][i],
                    source_id = result[3][i],
                    stable_id = result[4][i],
                    chapter_idx = result[5][i] ~= nil and tonumber(result[5][i]) or nil,
                    last_open = tonumber(result[6][i]) or 0,
                }
            end
        end
    end
    return map
end

--- 删除一条打开记录
---@param path string
---@return boolean
function OpenDB.delete(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    Base.ensure()
    return Base.exec([[DELETE FROM opens WHERE path=?;]], path) ~= nil
end

--- 清空全部打开记录
---@return boolean
function OpenDB.clear()
    Base.ensure()
    return Base.exec([[DELETE FROM opens;]]) ~= nil
end

return OpenDB
