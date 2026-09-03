--[[--
微信读书目录缓存读取：把 books.toc（JSON 载荷）的读取与按 idx/uid 定位收口到一处，
避免在门面、上报器与划线模块里重复 decode。

解码结果带进程内缓存：目录只由本插件 ``Toc.put`` 写入，写入即失效重建，
所以翻页、按章补报统计这些高频路径不必反复查库 + decode 整份目录。

@module koplugin.book.source.wechat.toc
--]]

local Toc = {}

local TTL = 6 * 60 * 60

---@class WechatTocEntry
---@field list BookChapter[]
---@field idx_by_uid table<string, integer>

---@type table<string, WechatTocEntry>
local cache = {}

---@param source_id string
---@param stable_id string
---@return string
local function cacheKey(source_id, stable_id)
    return tostring(source_id) .. "\31" .. tostring(stable_id)
end

--- 建立 uid → idx 反查表，省掉每次定位的线性扫。
---@param list BookChapter[]
---@return WechatTocEntry
local function buildEntry(list)
    local idx_by_uid = {}
    for _, chapter in ipairs(list) do
        if type(chapter) == "table" and chapter.uid ~= nil then
            idx_by_uid[tostring(chapter.uid)] = tonumber(chapter.idx)
        end
    end
    return { list = list, idx_by_uid = idx_by_uid }
end

--- 取解码后的目录条目（含 uid 反查表）；未命中/过期/非法 JSON 一律返回 nil。
---@param source_id string
---@param stable_id string
---@return WechatTocEntry|nil
local function entryOf(source_id, stable_id)
    local key = cacheKey(source_id, stable_id)
    local hit = cache[key]
    if hit then
        return hit
    end
    local payload = require("db.book").getToc(source_id, stable_id, TTL)
    if not payload then
        return nil
    end
    local ok, decoded = pcall(require("json").decode, payload)
    if not ok or type(decoded) ~= "table" then
        return nil
    end
    local entry = buildEntry(decoded)
    cache[key] = entry
    return entry
end

--- 读取并解码目录缓存；未命中/过期/非法 JSON 一律返回 nil。
---@param source_id string
---@param stable_id string
---@return BookChapter[]|nil
function Toc.read(source_id, stable_id)
    local entry = entryOf(source_id, stable_id)
    return entry and entry.list
end

--- 落库并接管内存缓存（目录刚拉到手，无需再 decode 一遍）。
---@param source_id string
---@param stable_id string
---@param list BookChapter[]
function Toc.put(source_id, stable_id, list)
    local ok, encoded = pcall(require("json").encode, list)
    if not ok or not encoded then
        return
    end
    cache[cacheKey(source_id, stable_id)] = buildEntry(list)
    require("db.book").setToc(source_id, stable_id, encoded)
end

--- 按 1-based 章节序号取 chapter.uid。
---@param source_id string
---@param stable_id string
---@param idx number|nil
---@return string|nil
function Toc.uid(source_id, stable_id, idx)
    local entry = entryOf(source_id, stable_id)
    local chapter = entry and entry.list[tonumber(idx)]
    return chapter and chapter.uid
end

--- 按 chapter.uid 反查 chapter.idx。
---@param source_id string
---@param stable_id string
---@param uid string|number|nil
---@return integer|nil
function Toc.index(source_id, stable_id, uid)
    if uid == nil then
        return nil
    end
    local entry = entryOf(source_id, stable_id)
    return entry and entry.idx_by_uid[tostring(uid)]
end

--- 章内进度 + 章节序号 → 全书 fraction；目录未缓存时返回 nil。
---@param source_id string
---@param stable_id string
---@param chapter_idx integer
---@param chapter_fraction number|nil
---@return number|nil
function Toc.wholeFraction(source_id, stable_id, chapter_idx, chapter_fraction)
    local list = Toc.read(source_id, stable_id)
    if not list or #list == 0 then
        return nil
    end
    local within = chapter_fraction or 0
    return require("types.book_progress").clampFraction(
        (chapter_idx - 1 + within) / #list
    )
end

--- 清空进程内目录缓存；落库的 books.toc 不受影响。
function Toc.clear()
    cache = {}
end

return Toc
