--[[--
X-Ray 书级实体 / 时间线 / 元数据。

@module koplugin.book.utils.db.xray
--]]

local Base = require("utils.db.base")

local XrayDB = {}

local function validBook(source_id, stable_id)
    source_id = Base.requireSourceId(source_id)
    if not source_id or type(stable_id) ~= "string" or stable_id == "" then
        return nil
    end
    return source_id
end

--- 写入或覆盖一个 X-Ray 实体。
---@param source_id string
---@param stable_id string
---@param kind string
---@param name string
---@param aliases_json string
---@param payload_json string
---@param updated_at integer|nil
---@return boolean
function XrayDB.upsertEntity(source_id, stable_id, kind, name, aliases_json, payload_json, updated_at)
    source_id = validBook(source_id, stable_id)
    if not source_id or type(kind) ~= "string" or kind == ""
        or type(name) ~= "string" or name == ""
        or type(aliases_json) ~= "string"
        or type(payload_json) ~= "string" then
        return false
    end
    Base.ensure()
    return Base.exec([[
        INSERT INTO xray_entities
          (source_id, stable_id, kind, name, aliases_json, payload_json, updated_at)
        VALUES (?,?,?,?,?,?,?)
        ON CONFLICT(source_id, stable_id, kind, name) DO UPDATE SET
          aliases_json=excluded.aliases_json,
          payload_json=excluded.payload_json,
          updated_at=excluded.updated_at;
    ]], source_id, stable_id, kind, name, aliases_json, payload_json,
        tonumber(updated_at) or os.time()) ~= nil
end

--- 列出实体；kind 非空时按种类过滤。
---@param source_id string
---@param stable_id string
---@param kind string|nil
---@return table[]
function XrayDB.listEntities(source_id, stable_id, kind)
    source_id = validBook(source_id, stable_id)
    if not source_id then return {} end
    Base.ensure()
    local result, nrows
    if kind and kind ~= "" then
        result, nrows = Base.query([[
            SELECT kind, name, aliases_json, payload_json, updated_at
            FROM xray_entities
            WHERE source_id=? AND stable_id=? AND kind=?
            ORDER BY name COLLATE NOCASE ASC;
        ]], source_id, stable_id, kind)
    else
        result, nrows = Base.query([[
            SELECT kind, name, aliases_json, payload_json, updated_at
            FROM xray_entities
            WHERE source_id=? AND stable_id=?
            ORDER BY kind ASC, name COLLATE NOCASE ASC;
        ]], source_id, stable_id)
    end
    local out = {}
    if not result then return out end
    for i = 1, nrows do
        out[#out + 1] = {
            kind = result[1][i],
            name = result[2][i],
            aliases_json = result[3][i],
            payload_json = result[4][i],
            updated_at = tonumber(result[5][i]) or 0,
        }
    end
    return out
end

--- 写入或覆盖一条时间线（按 chapter 冲突更新）。
---@param source_id string
---@param stable_id string
---@param chapter string
---@param event string
---@param page integer|nil
---@param sort_idx integer|nil
---@param updated_at integer|nil
---@return boolean
function XrayDB.upsertTimeline(source_id, stable_id, chapter, event, page, sort_idx, updated_at)
    source_id = validBook(source_id, stable_id)
    if not source_id or type(chapter) ~= "string" or chapter == ""
        or type(event) ~= "string" then
        return false
    end
    Base.ensure()
    return Base.exec([[
        INSERT INTO xray_timeline
          (source_id, stable_id, chapter, event, page, sort_idx, updated_at)
        VALUES (?,?,?,?,?,?,?)
        ON CONFLICT(source_id, stable_id, chapter) DO UPDATE SET
          event=excluded.event,
          page=excluded.page,
          sort_idx=excluded.sort_idx,
          updated_at=excluded.updated_at;
    ]], source_id, stable_id, chapter, event, tonumber(page) or 0,
        tonumber(sort_idx) or 0, tonumber(updated_at) or os.time()) ~= nil
end

--- 列出该书时间线，按 sort_idx / page 排序。
---@param source_id string
---@param stable_id string
---@return table[]
function XrayDB.listTimeline(source_id, stable_id)
    source_id = validBook(source_id, stable_id)
    if not source_id then return {} end
    Base.ensure()
    local result, nrows = Base.query([[
        SELECT chapter, event, page, sort_idx, updated_at
        FROM xray_timeline
        WHERE source_id=? AND stable_id=?
        ORDER BY sort_idx ASC, page ASC, chapter ASC;
    ]], source_id, stable_id)
    local out = {}
    if not result then return out end
    for i = 1, nrows do
        out[#out + 1] = {
            chapter = result[1][i],
            event = result[2][i],
            page = tonumber(result[3][i]) or 0,
            sort_idx = tonumber(result[4][i]) or 0,
            updated_at = tonumber(result[5][i]) or 0,
        }
    end
    return out
end

--- 写入或覆盖 X-Ray 元数据（上次拉取页、书类型）。
---@param source_id string
---@param stable_id string
---@param last_fetch_page integer|nil
---@param book_type string|nil
---@param updated_at integer|nil
---@return boolean
function XrayDB.upsertMeta(source_id, stable_id, last_fetch_page, book_type, updated_at)
    source_id = validBook(source_id, stable_id)
    if not source_id then return false end
    Base.ensure()
    return Base.exec([[
        INSERT INTO xray_meta
          (source_id, stable_id, last_fetch_page, book_type, updated_at)
        VALUES (?,?,?,?,?)
        ON CONFLICT(source_id, stable_id) DO UPDATE SET
          last_fetch_page=excluded.last_fetch_page,
          book_type=excluded.book_type,
          updated_at=excluded.updated_at;
    ]], source_id, stable_id, tonumber(last_fetch_page) or 0,
        book_type, tonumber(updated_at) or os.time()) ~= nil
end

--- 读取 X-Ray 元数据。
---@param source_id string
---@param stable_id string
---@return table|nil
function XrayDB.getMeta(source_id, stable_id)
    source_id = validBook(source_id, stable_id)
    if not source_id then return nil end
    Base.ensure()
    local last_fetch_page, book_type, updated_at = Base.rowexec([[
        SELECT last_fetch_page, book_type, updated_at
        FROM xray_meta WHERE source_id=? AND stable_id=? LIMIT 1;
    ]], source_id, stable_id)
    if last_fetch_page == nil and book_type == nil then
        return nil
    end
    return {
        last_fetch_page = tonumber(last_fetch_page) or 0,
        book_type = book_type,
        updated_at = tonumber(updated_at) or 0,
    }
end

--- 删除指定实体。
---@param source_id string
---@param stable_id string
---@param kind string
---@param name string
---@return boolean
function XrayDB.deleteEntity(source_id, stable_id, kind, name)
    source_id = validBook(source_id, stable_id)
    if not source_id or type(kind) ~= "string" or type(name) ~= "string" then
        return false
    end
    Base.ensure()
    return Base.exec([[
        DELETE FROM xray_entities
        WHERE source_id=? AND stable_id=? AND kind=? AND name=?;
    ]], source_id, stable_id, kind, name) ~= nil
end

return XrayDB
