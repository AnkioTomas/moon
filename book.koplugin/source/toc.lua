--[[--
章节源目录缓存：books.toc（JSON 载荷）的读取、按 idx/uid 定位与进程内缓存。

books.toc 只经 ``Toc.put`` 写入（同时接管内存缓存），
翻页、按章补报统计这些高频路径不必反复查库 + decode 整份目录。
缓存键含 source_id，各章节源共用这一份。

@module koplugin.book.source.toc
--]]

local Toc = {}

--- 目录缓存 TTL（秒）。
Toc.TTL = 6 * 60 * 60

---@class SourceTocEntry
---@field list BookChapter[]
---@field idx_by_uid table<string, integer>
---@field source_idx_by_idx table<integer, integer>
---@field fetched_at integer

---@type table<string, SourceTocEntry>
local cache = {}
local count = 0
local CACHE_LIMIT = 32

--- 字数回填后等多久把目录写回库（秒）。字数是派生缓存，丢了下次打开该章再算；
--- 千章全本缓存按这个节奏合并写，而不是每章序列化一遍整份目录。
Toc.WORDS_FLUSH_DELAY = 30
--- 字数改了、还没写回库的目录：key → list。Toc.put 换新目录时作废。
---@type table<string, BookChapter[]>
local pending_words = {}

--- 写入缓存；满了先整表清空再放新条目（活跃的只有在读的几本，清掉的下次查库重建）。
---@param key string
---@param entry SourceTocEntry
---@return SourceTocEntry
local function putCache(key, entry)
    if cache[key] == nil then
        if count >= CACHE_LIMIT then cache, count = {}, 0 end
        count = count + 1
    end
    cache[key] = entry
    return entry
end

---@param key string
local function dropCache(key)
    if cache[key] ~= nil then
        cache[key] = nil
        count = count - 1
    end
end

---@param source_id string
---@param stable_id string
---@return string
local function keyOf(source_id, stable_id)
    return tostring(source_id) .. "\31" .. tostring(stable_id)
end

--- 建立 uid → idx、idx → 源原始序号反查表，省掉每次定位的线性扫。
---@param list BookChapter[]
---@param fetched_at integer
---@return SourceTocEntry
local function build(list, fetched_at)
    local idx_by_uid = {}
    local source_idx_by_idx = {}
    for _idx, chapter in ipairs(list) do
        if type(chapter) == "table" then
            local idx = tonumber(chapter.idx)
            if chapter.uid ~= nil then
                idx_by_uid[tostring(chapter.uid)] = idx
            end
            if idx and tonumber(chapter.source_idx) then
                source_idx_by_idx[idx] = tonumber(chapter.source_idx)
            end
        end
    end
    return { list = list, idx_by_uid = idx_by_uid, source_idx_by_idx = source_idx_by_idx,
        fetched_at = fetched_at }
end

--- 取解码后的目录条目；未命中/过期/非法 JSON 一律返回 nil。
---@param source_id string
---@param stable_id string
---@param stale boolean|nil 为真时不看 TTL
---@return SourceTocEntry|nil
local function entry(source_id, stable_id, stale)
    local key = keyOf(source_id, stable_id)
    local hit = cache[key]
    if hit and (stale or os.time() - hit.fetched_at < Toc.TTL) then
        return hit
    end
    dropCache(key)
    local payload, fetched_at = require("book.books_db").getToc(source_id, stable_id, not stale and Toc.TTL or nil)
    if not payload then
        return nil
    end
    local ok, list = pcall(require("json").decode, payload)
    if not ok or type(list) ~= "table" then
        return nil
    end
    return putCache(key, build(list, fetched_at or os.time()))
end

--- 读取并解码目录缓存；未命中/过期/非法 JSON 一律返回 nil。
---@param source_id string
---@param stable_id string
---@param stale boolean|nil 为真时过期的也要：调用方拿它当「章号编号基线」，不是当新鲜目录用
---@return BookChapter[]|nil
function Toc.read(source_id, stable_id, stale)
    local hit = entry(source_id, stable_id, stale)
    return hit and hit.list
end

--- 落库并接管内存缓存（目录刚拉到手，无需再 decode 一遍）。
---@param source_id string
---@param stable_id string
---@param list BookChapter[]
---@return boolean
function Toc.put(source_id, stable_id, list)
    local ok, payload = pcall(require("json").encode, list)
    if not ok or type(payload) ~= "string" then return false end
    if not require("book.books_db").setToc(source_id, stable_id, payload) then return false end
    local key = keyOf(source_id, stable_id)
    pending_words[key] = nil
    putCache(key, build(list, os.time()))
    return true
end

--- 补一章字数（缓存正文后回填）：内存目录立即生效，落库延迟合并。番茄等目录不带字数时靠这个估全书页码。
---@param source_id string
---@param stable_id string
---@param idx integer
---@param words integer
function Toc.setWords(source_id, stable_id, idx, words)
    words = tonumber(words)
    idx = tonumber(idx)
    if not words or words <= 0 or not idx then return end
    local list = Toc.read(source_id, stable_id, true)
    local chapter = list and list[idx]
    if not chapter or tonumber(chapter.words) == words then return end
    chapter.words = words
    local key = keyOf(source_id, stable_id)
    local scheduled = pending_words[key] ~= nil
    pending_words[key] = list
    if scheduled then return end
    require("ui/uimanager"):scheduleIn(Toc.WORDS_FLUSH_DELAY, function()
        local dirty = pending_words[key]
        pending_words[key] = nil
        if not dirty then return end
        local ok, payload = pcall(require("json").encode, dirty)
        if not ok or type(payload) ~= "string"
            or not require("book.books_db").setToc(source_id, stable_id, payload) then
            require("logger").warn("book.toc setWords flush failed", source_id, stable_id, payload)
        end
    end)
end

--- 记下一章 VIP 的购买状态（目录里显示「已购 / 未购」）；变了才落库。
---@param source_id string
---@param stable_id string
---@param uid string
---@param paid boolean
function Toc.markPaid(source_id, stable_id, uid, paid)
    local list = Toc.read(source_id, stable_id)
    local idx = Toc.index(source_id, stable_id, uid)
    local chapter = list and idx and list[idx]
    if chapter and chapter.vip and chapter.paid ~= paid then
        chapter.paid = paid
        Toc.put(source_id, stable_id, list)
    end
end

--- 按 chapter.uid 反查 chapter.idx。
---@param source_id string
---@param stable_id string
---@param uid string|number|nil
---@return integer|nil
function Toc.index(source_id, stable_id, uid)
    if uid == nil then return nil end
    local hit = entry(source_id, stable_id)
    return hit and hit.idx_by_uid[tostring(uid)]
end

--- 按 1-based 章节序号取 chapter.uid。
---@param source_id string
---@param stable_id string
---@param idx integer|nil
---@param stale boolean|nil 为真时过期目录也认（uid 不随时间变，补报离线数据用）
---@return string|nil
function Toc.uid(source_id, stable_id, idx, stale)
    local hit = entry(source_id, stable_id, stale)
    local chapter = hit and hit.list[tonumber(idx)]
    return chapter and chapter.uid
end

--- 按本地章节序号取源原始章节序号。
---@param source_id string
---@param stable_id string
---@param idx number|nil
---@param stale boolean|nil 同 Toc.uid
---@return integer|nil
function Toc.sourceIndex(source_id, stable_id, idx, stale)
    local hit = entry(source_id, stable_id, stale)
    return hit and hit.source_idx_by_idx[tonumber(idx)]
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

--- 作废一本的目录缓存：落库的 books.toc 与进程内缓存一起清掉。
---@param source_id string
---@param stable_id string
function Toc.drop(source_id, stable_id)
    require("book.books_db").clearToc(source_id, stable_id)
    dropCache(keyOf(source_id, stable_id))
end

--- 清空进程内目录缓存；落库的 books.toc 不受影响。
function Toc.clear()
    cache = {}
    count = 0
end

return Toc
