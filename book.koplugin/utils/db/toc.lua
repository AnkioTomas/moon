--[[--
tocs 表：目录缓存

@module koplugin.book.utils.db.toc
--]]

local logger = require("logger")
local JSON = require("json")
local Base = require("utils.db.base")

local TocDB = {}

--- 写入/更新目录缓存
---@param book_key string
---@param source_id string
---@param toc { chapters: table, raw: any, fetched_at: number|nil }
---@return boolean
function TocDB.put(book_key, source_id, toc)
    if type(book_key) ~= "string" or book_key == "" or type(toc) ~= "table" then
        return false
    end
    source_id = Base.requireSourceId(source_id)
    if not source_id then
        return false
    end
    Base.ensure()
    local chapters = toc.chapters or toc
    local ok_enc, chapters_json = pcall(JSON.encode, chapters)
    if not ok_enc or not chapters_json then
        logger.warn("book.db putToc encode chapters failed", book_key)
        return false
    end
    local raw_json = nil
    if toc.raw ~= nil then
        local ok_r, encoded = pcall(JSON.encode, toc.raw)
        if ok_r then
            raw_json = encoded
        end
    end
    local sql = string.format(
        [[INSERT INTO tocs (book_key, source_id, fetched_at, chapters, raw)
          VALUES (%s,%s,%s,%s,%s)
          ON CONFLICT(book_key) DO UPDATE SET
            source_id=excluded.source_id,
            fetched_at=excluded.fetched_at,
            chapters=excluded.chapters,
            raw=excluded.raw;]],
        Base.sqlQuote(book_key),
        Base.sqlQuote(source_id),
        Base.sqlQuote(tonumber(toc.fetched_at) or os.time()),
        Base.sqlQuote(chapters_json),
        Base.sqlQuote(raw_json)
    )
    return Base.exec(sql) ~= nil
end

--- 按 book_key 取目录缓存
---@param book_key string
---@return table|nil
function TocDB.get(book_key)
    if type(book_key) ~= "string" or book_key == "" then
        return nil
    end
    Base.ensure()
    local bk, source_id, fetched_at, chapters_json, raw_json = Base.rowexec(string.format(
        [[SELECT book_key, source_id, fetched_at, chapters, raw FROM tocs WHERE book_key=%s LIMIT 1;]],
        Base.sqlQuote(book_key)
    ))
    if not bk then
        return nil
    end
    local chapters = {}
    if type(chapters_json) == "string" and chapters_json ~= "" then
        local ok, decoded = pcall(JSON.decode, chapters_json)
        if ok and type(decoded) == "table" then
            chapters = decoded
        end
    end
    local raw = nil
    if type(raw_json) == "string" and raw_json ~= "" then
        local ok, decoded = pcall(JSON.decode, raw_json)
        if ok then
            raw = decoded
        end
    end
    return {
        book_key = bk,
        source_id = source_id,
        fetched_at = tonumber(fetched_at) or 0,
        chapters = chapters,
        raw = raw,
    }
end

--- 删除一条目录缓存
---@param book_key string
---@return boolean
function TocDB.delete(book_key)
    if type(book_key) ~= "string" or book_key == "" then
        return false
    end
    Base.ensure()
    return Base.exec(string.format(
        [[DELETE FROM tocs WHERE book_key=%s;]],
        Base.sqlQuote(book_key)
    )) ~= nil
end

--- 删除过期目录缓存
---@param before_ts number
---@return boolean
function TocDB.deleteExpired(before_ts)
    before_ts = tonumber(before_ts) or 0
    Base.ensure()
    return Base.exec(string.format(
        [[DELETE FROM tocs WHERE fetched_at < %d;]],
        before_ts
    )) ~= nil
end

--- 清空全部目录缓存
---@return boolean
function TocDB.clear()
    Base.ensure()
    return Base.exec([[DELETE FROM tocs;]]) ~= nil
end

return TocDB
