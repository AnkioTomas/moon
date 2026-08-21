--[[--
AI 阅读分析缓存。每个可见文本上下文保存一份结构化结果，图谱按书聚合这些结果。

@module koplugin.book.utils.db.ai
--]]

local Base = require("utils.db.base")

local AiDB = {}
local COLUMNS = "source_id, stable_id, chapter_idx, context_key, page, payload, updated_at"

local function validIdentity(source_id, stable_id, chapter_idx)
    source_id = Base.requireSourceId(source_id)
    chapter_idx = tonumber(chapter_idx) or 0
    if not source_id or type(stable_id) ~= "string" or stable_id == ""
        or chapter_idx < 0 or chapter_idx % 1 ~= 0 then
        return nil
    end
    return source_id, chapter_idx
end

local function row(source_id, stable_id, chapter_idx, context_key, page, payload, updated_at)
    if not source_id then return nil end
    return {
        source_id = source_id,
        stable_id = stable_id,
        chapter_idx = tonumber(chapter_idx) or 0,
        context_key = context_key,
        page = tonumber(page) or 0,
        payload = payload,
        updated_at = tonumber(updated_at) or 0,
    }
end

--- 写入或覆盖一条 AI 分析缓存。
---@param source_id string
---@param stable_id string
---@param chapter_idx integer|nil
---@param context_key string
---@param page integer|nil
---@param payload string
---@param updated_at integer|nil
---@return boolean
function AiDB.upsert(source_id, stable_id, chapter_idx, context_key, page, payload, updated_at)
    source_id, chapter_idx = validIdentity(source_id, stable_id, chapter_idx)
    if not source_id or type(context_key) ~= "string" or context_key == ""
        or type(payload) ~= "string" then
        return false
    end
    Base.ensure()
    return Base.exec([[
        INSERT INTO ai_analysis
          (source_id, stable_id, chapter_idx, context_key, page, payload, updated_at)
        VALUES (?,?,?,?,?,?,?)
        ON CONFLICT(source_id, stable_id, chapter_idx, context_key) DO UPDATE SET
          page=excluded.page, payload=excluded.payload, updated_at=excluded.updated_at;
    ]], source_id, stable_id, chapter_idx, context_key, tonumber(page) or 0,
        payload, tonumber(updated_at) or os.time()) ~= nil
end

--- 按上下文键读取一条分析缓存。
---@param source_id string
---@param stable_id string
---@param chapter_idx integer|nil
---@param context_key string
---@return table|nil
function AiDB.get(source_id, stable_id, chapter_idx, context_key)
    source_id, chapter_idx = validIdentity(source_id, stable_id, chapter_idx)
    if not source_id or type(context_key) ~= "string" or context_key == "" then return nil end
    Base.ensure()
    return row(Base.rowexec(
        "SELECT " .. COLUMNS .. " FROM ai_analysis WHERE source_id=? AND stable_id=? AND chapter_idx=? AND context_key=? LIMIT 1;",
        source_id, stable_id, chapter_idx, context_key))
end

--- 该书全部分析缓存，按更新时间升序。
---@param source_id string
---@param stable_id string
---@return table[]
function AiDB.allForBook(source_id, stable_id)
    source_id = Base.requireSourceId(source_id)
    if not source_id or type(stable_id) ~= "string" or stable_id == "" then return {} end
    Base.ensure()
    local result, nrows = Base.query(
        "SELECT " .. COLUMNS .. " FROM ai_analysis WHERE source_id=? AND stable_id=? ORDER BY updated_at ASC;",
        source_id, stable_id)
    local out = {}
    if not result then return out end
    for i = 1, nrows do
        out[#out + 1] = row(result[1][i], result[2][i], result[3][i], result[4][i],
            result[5][i], result[6][i], result[7][i])
    end
    return out
end

return AiDB
