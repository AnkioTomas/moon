--[[--
段评本地缓存（微信读书 / 番茄共用）：本章热点与每句的评论页，离线可读。

表 review_cache：(source_id, stable_id, chapter_idx, kind, key) 主键，payload 是 JSON。
kind = "hot"（key 为空串，payload 是热点数组）或 "page"（key = range \0 max_idx，payload 是一页评论）。
不缓存图片。有内容的行存 TTL（180 天）；空结果（多半是网络抖动 / 接口偶发）只存 EMPTY_TTL 就重来。
过期行读到时当没有，下次写入覆盖。

`through`（内部）是读写收口：命中直接回（不看网络），没命中且未联网立即失败，联网才请求并落库。
依附书身份：改名 / 撕墓碑由 books_db 经 IDENTITY_MODULES 调 moveIdentity / removeIdentity。

@module koplugin.book.book.review_cache
--]]

local DB = require("utils.db")
local JSON = require("json")
local _ = require("gettext")

local ReviewCache = {}

local TTL = 180 * 24 * 3600
local EMPTY_TTL = 300

DB.schema("review_cache", function()
    return DB.exec([[
CREATE TABLE IF NOT EXISTS review_cache (
  source_id TEXT NOT NULL, stable_id TEXT NOT NULL, chapter_idx INTEGER NOT NULL,
  kind TEXT NOT NULL, key TEXT NOT NULL, payload TEXT NOT NULL, expire INTEGER NOT NULL,
  PRIMARY KEY (source_id, stable_id, chapter_idx, kind, key)
);
]]) ~= nil
end)

function ReviewCache.moveIdentity(source_id, old_stable_id, new_stable_id, merge)
    return DB.moveIdentity("review_cache", source_id, old_stable_id, new_stable_id, merge)
end

function ReviewCache.removeIdentity(source_id, stable_id)
    return DB.removeIdentity("review_cache", source_id, stable_id)
end

---@param identity BookIdentity
---@param kind "hot"|"page"
---@param key string
---@return table|nil
local function read(identity, kind, key)
    local payload, expire = DB.rowexec(
        [[SELECT payload, expire FROM review_cache
          WHERE source_id=? AND stable_id=? AND chapter_idx=? AND kind=? AND key=?;]],
        identity.source_id, identity.stable_id, tonumber(identity.chapter_idx), kind, key)
    if not payload or (tonumber(expire) or 0) <= os.time() then return nil end
    return JSON.decode(payload)
end

---@param identity BookIdentity
---@param kind "hot"|"page"
---@param key string
---@param value table
local function write(identity, kind, key, value)
    local count = value.items and #value.items or #value
    DB.exec(
        [[INSERT OR REPLACE INTO review_cache (source_id, stable_id, chapter_idx, kind, key, payload, expire)
          VALUES (?,?,?,?,?,?,?);]],
        identity.source_id, identity.stable_id, tonumber(identity.chapter_idx), kind, key,
        JSON.encode(value), os.time() + (count > 0 and TTL or EMPTY_TTL))
end

---@param range string
---@param max_idx integer
---@return string
local function pageKey(range, max_idx)
    return range .. "\0" .. max_idx
end

--- 本章热点缓存（未过期才有）。
---@param identity BookIdentity
---@return table[]|nil
function ReviewCache.hotspots(identity)
    return read(identity, "hot", "")
end

--- 某句某页的评论缓存（未过期才有）。
---@param identity BookIdentity
---@param range string
---@param max_idx integer
---@return table|nil
function ReviewCache.page(identity, range, max_idx)
    return read(identity, "page", pageKey(range, max_idx))
end

--- 读写收口：命中直接回；没命中且未联网立即失败；联网请求，成功落库。
---@param identity BookIdentity
---@param kind "hot"|"page"
---@param key string
---@param fetch fun(cb: fun(value: table|nil, err: string|nil)): { cancel: fun() }|nil
---@param cb fun(value: table|nil, err: string|nil)
---@return { cancel: fun() }
local function through(identity, kind, key, fetch, cb)
    local cancelled, job = false, nil
    local handle = { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
    local hit = read(identity, kind, key)
    local online = hit ~= nil or require("ui/network/manager"):isConnected()
    if not online then
        require("ui/uimanager"):nextTick(function()
            if not cancelled then cb(nil, _("未联网，无法加载段评")) end
        end)
        return handle
    end
    if hit then
        require("ui/uimanager"):nextTick(function()
            if not cancelled then cb(hit) end
        end)
        return handle
    end
    job = fetch(function(value, err)
        if cancelled then return end
        if value then write(identity, kind, key, value) end
        cb(value, err)
    end)
    return handle
end

--- 热点：本章热点缓存或请求。
function ReviewCache.hotspotsAsync(identity, fetch, cb)
    return through(identity, "hot", "", fetch, cb)
end

--- 评论页：缓存或请求。
function ReviewCache.pageAsync(identity, range, max_idx, fetch, cb)
    return through(identity, "page", pageKey(range, max_idx), fetch, cb)
end

return ReviewCache
