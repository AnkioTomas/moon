--[[--
toc 表：在线源书籍目录缓存（一书一条，身份 = source_id + stable_id）

payload 是不透明字符串（调用方自行 JSON 编解码，语义同 http 表）；
新鲜度（TTL）由读取方按 max_age 判定，过期即 miss，由下次拉取覆盖。

@module koplugin.book.utils.db.toc
--]]

local Base = require("utils.db.base")

local TocDB = {}

--- 取目录缓存；fetched_at 在 max_age 秒内才返回 payload，否则 nil。
---@param source_id string
---@param stable_id string
---@param max_age? number 秒；省略时不做过期判断
---@return string|nil payload, number|nil fetched_at
function TocDB.get(source_id, stable_id, max_age)
    Base.ensure()
    local payload, fetched_at = Base.rowexec(
        [[SELECT payload, fetched_at FROM toc WHERE source_id=? AND stable_id=? LIMIT 1;]],
        source_id,
        stable_id
    )
    if not payload then
        return nil
    end
    fetched_at = tonumber(fetched_at) or 0
    if max_age and os.time() - fetched_at >= max_age then
        return nil
    end
    return payload, fetched_at
end

--- 写入/覆盖目录缓存
---@param source_id string
---@param stable_id string
---@param payload string
---@return boolean
function TocDB.upsert(source_id, stable_id, payload)
    Base.ensure()
    return Base.exec(
        [[INSERT INTO toc (source_id, stable_id, payload, fetched_at)
          VALUES (?,?,?,?)
          ON CONFLICT(source_id, stable_id) DO UPDATE SET
            payload=excluded.payload,
            fetched_at=excluded.fetched_at;]],
        source_id,
        stable_id,
        payload,
        os.time()
    ) ~= nil
end

--- 删除目录缓存
---@param source_id string
---@param stable_id string
---@return boolean
function TocDB.delete(source_id, stable_id)
    Base.ensure()
    return Base.exec(
        [[DELETE FROM toc WHERE source_id=? AND stable_id=?;]],
        source_id,
        stable_id
    ) ~= nil
end

return TocDB
