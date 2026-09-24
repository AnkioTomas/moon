--[[--
拷贝漫画目录缓存。

@module koplugin.book.source.copymanga.toc
--]]

local JSON = require("json")

local Toc = {}
local TTL = 6 * 60 * 60
local cache = {}
local CACHE_LIMIT = 32
local function putCache(cache_key, value)
    cache[cache_key] = value
    local count = 0
    for key in pairs(cache) do count = count + 1; if count > CACHE_LIMIT then cache[key] = nil; break end end
end

---@param source_id string
---@param stable_id string
---@return string
local function key(source_id, stable_id)
    return source_id .. "\31" .. stable_id
end

---@param list BookChapter[]
---@param fetched_at integer
---@return table
local function build(list, fetched_at)
    local by_uid = {}
    for _, chapter in ipairs(list) do
        if chapter.uid ~= nil then by_uid[tostring(chapter.uid)] = chapter.idx end
    end
    return { list = list, by_uid = by_uid, fetched_at = fetched_at }
end

---@param source_id string
---@param stable_id string
---@return table|nil
local function entry(source_id, stable_id)
    local cache_key = key(source_id, stable_id)
    local hit = cache[cache_key]
    if hit and os.time() - hit.fetched_at < TTL then return hit end
    cache[cache_key] = nil
    local payload, fetched_at = require("db.book").getToc(source_id, stable_id, TTL)
    if not payload then return nil end
    local ok, list = pcall(JSON.decode, payload)
    if not ok or type(list) ~= "table" or #list == 0 then return nil end
    putCache(cache_key, build(list, fetched_at or os.time()))
    return cache[cache_key]
end

---@param source_id string
---@param stable_id string
---@return BookChapter[]|nil
function Toc.read(source_id, stable_id)
    local hit = entry(source_id, stable_id)
    return hit and hit.list
end

---@param source_id string
---@param stable_id string
---@param list BookChapter[]
---@return boolean
function Toc.put(source_id, stable_id, list)
    local ok, payload = pcall(JSON.encode, list)
    if not ok or type(payload) ~= "string" then return false end
    if not require("db.book").setToc(source_id, stable_id, payload) then return false end
    putCache(key(source_id, stable_id), build(list, os.time()))
    return true
end

--- 按 chapter.uid 反查 1-based idx。
---@param source_id string
---@param stable_id string
---@param uid string|number|nil
---@return integer|nil
function Toc.index(source_id, stable_id, uid)
    if uid == nil then return nil end
    local hit = entry(source_id, stable_id)
    return hit and hit.by_uid[tostring(uid)]
end

--- 按 1-based idx 取 chapter.uid。
---@param source_id string
---@param stable_id string
---@param idx integer|nil
---@return string|nil
function Toc.uid(source_id, stable_id, idx)
    local hit = entry(source_id, stable_id)
    local chapter = hit and hit.list[tonumber(idx)]
    return chapter and chapter.uid
end

--- 章序号 + 章内比例 → 全书 fraction；目录未缓存时返回 nil。
---@param source_id string
---@param stable_id string
---@param chapter_idx integer
---@param chapter_fraction number|nil
---@return number|nil
function Toc.wholeFraction(source_id, stable_id, chapter_idx, chapter_fraction)
    local list = Toc.read(source_id, stable_id)
    if not list or #list == 0 then return nil end
    return require("book.progress").clampFraction(
        (chapter_idx - 1 + (chapter_fraction or 0)) / #list
    )
end

function Toc.clear()
    cache = {}
end

return Toc
