--[[--
章节源目录缓存：逐章 sqlite、按 idx/uid 定位与进程内缓存。

目录经 ``Toc.put`` 写入（同时接管内存缓存），旧 books.toc 首次读取时按书迁移。
翻页、按章补报统计这些高频路径不必反复查库；字数 / 购买状态只更新一章。
缓存键含 source_id，各章节源共用这一份。

有缓存就一直可用，不做时间保鲜；开书或剩余章不多时由章节会话后台静默拉新
（``refreshTocAsync``，没有则 ``loadTocAsync(..., true)``），
成功 ``Toc.put`` 换掉，失败不动旧目录、不弹提示。
拉新有节流（``REFRESH_INTERVAL``）：刚拉过或刚试过就跳过，避免反复开书 / 追更打爆源站。

@module koplugin.book.source.toc
--]]

local Toc = {}
local TocDB = require("book.toc_db")
local logger = require("utils.log")

---@class SourceTocEntry
---@field list BookChapter[]
---@field idx_by_uid table<string, integer>
---@field source_idx_by_idx table<integer, integer>
---@field fetched_at integer

---@type table<string, SourceTocEntry>
local cache = {}
local count = 0
local CACHE_LIMIT = 32

--- 开书 / 临近章末拉新最短间隔（秒）。成功看 fetched_at，失败看本进程上次尝试时间。
Toc.REFRESH_INTERVAL = 5 * 60
--- 本进程内上次「尝试拉新」的时间：key → unix。失败也要记，不然离线狂开书会连打。
---@type table<string, integer>
local last_attempt = {}

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

--- 取解码后的目录条目；未命中 / 非法 JSON 返回 nil。有就一直认，不看写入时间。
---@param source_id string
---@param stable_id string
---@param _stale boolean|nil 兼容旧调用方；已无 TTL，忽略
---@return SourceTocEntry|nil
local function entry(source_id, stable_id, _stale)
    local key = keyOf(source_id, stable_id)
    local hit = cache[key]
    if hit then return hit end
    local list, fetched_at = TocDB.read(source_id, stable_id)
    if not list then
        local payload
        payload, fetched_at = require("book.books_db").getToc(source_id, stable_id)
        if not payload then return nil end
        local decoded, _position, err = require("dkjson").decode(payload)
        if type(decoded) ~= "table" then
            logger.warn("book.toc legacy decode failed", source_id, stable_id, err)
            return nil
        end
        if not TocDB.put(source_id, stable_id, decoded, fetched_at) then
            logger.warn("book.toc migration failed", source_id, stable_id)
            return nil
        end
        list = decoded
    end
    return putCache(key, build(list, fetched_at or os.time()))
end

--- 读取并解码目录缓存；未命中 / 非法 JSON 返回 nil。
---@param source_id string
---@param stable_id string
---@param stale boolean|nil 兼容旧调用方；已无 TTL，有缓存就返回
---@return BookChapter[]|nil
function Toc.read(source_id, stable_id, stale)
    local hit = entry(source_id, stable_id, stale)
    return hit and hit.list
end

--- 首绘只看已装入的目录，冷读交给 readAsync。
function Toc.peek(source_id, stable_id)
    local hit = cache[keyOf(source_id, stable_id)]
    return hit and hit.list
end

--- 子进程只解析 / 写临时文件；主进程每次接收 16 章，成功后原子发布。
--- 不把整份大目录塞进 Job 的 JSON 管道，也不在子进程访问业务库。
---@param source_id string
---@param stable_id string
---@param parse fun(): BookChapter[]|nil, string|nil
---@param cb fun(list: BookChapter[]|nil, err: string|nil)
---@param fetched_at integer|nil
---@return { cancel: fun() }
function Toc.parseAsync(source_id, stable_id, parse, cb, fetched_at)
    local UI = require("ui/uimanager")
    -- 必须走 Paths.tmpname：Android 上 os.tmpname 写 /tmp 会直接抛错。
    local path = require("utils.paths").tmpname()
    local file, job, step
    local finished = false
    local list = {}
    local _old_at, revision = TocDB.snapshot(source_id, stable_id)
    local function cleanup()
        if step then UI:unschedule(step) end
        if file then file:close(); file = nil end
        os.remove(path)
    end
    local function finish(result, err)
        if finished then return end
        finished = true
        cleanup()
        if err then logger.warn("book.toc parse failed", source_id, stable_id, err) end
        cb(result, err)
    end
    job = require("workers.job").run(function()
        local parsed, err = parse()
        if not parsed then return { error = err or "invalid toc" } end
        local output = assert(io.open(path, "wb"))
        for _idx, chapter in ipairs(parsed) do
            assert(output:write(require("dkjson").encode(chapter), "\n"))
        end
        assert(output:close())
        return { count = #parsed }
    end, {
        name = "toc parse " .. source_id,
        kind = "light",
        on_failed = function(err) finish(nil, err) end,
        on_done = function(result)
            if result.error then finish(nil, result.error); return end
            local err
            file, err = io.open(path, "rb")
            if not file then finish(nil, err); return end
            step = require("ui.guard").wrap("toc receive", function()
                for _idx = 1, 16 do
                    local line, read_err = file:read("*l")
                    if read_err then finish(nil, read_err); return end
                    if not line then
                        local _current_at, current_revision = TocDB.snapshot(source_id, stable_id)
                        if #list ~= result.count then
                            finish(nil, "incomplete toc transfer")
                        elseif revision ~= current_revision then
                            finish(nil, "toc snapshot changed")
                        elseif not TocDB.put(source_id, stable_id, list, fetched_at) then
                            finish(nil, require("l10n").get("source." .. source_id)("章节目录保存失败"))
                        else
                            putCache(keyOf(source_id, stable_id), build(list, fetched_at or os.time()))
                            finish(list)
                        end
                        return
                    end
                    local chapter, _position, decode_err = require("dkjson").decode(line)
                    if type(chapter) ~= "table" then finish(nil, decode_err or "invalid toc entry"); return end
                    list[#list + 1] = chapter
                end
                UI:scheduleIn(0.01, step)
            end)
            UI:nextTick(step)
        end,
    })
    return { cancel = function()
        if finished then return end
        finished = true
        job:cancel()
        cleanup()
    end }
end

--- 缓存命中仍立即复用；冷目录分批读取，旧大 JSON 在子进程迁移。
---@param source_id string
---@param stable_id string
---@param cb fun(list: BookChapter[]|nil, err: string|nil)
---@return { cancel: fun() }
function Toc.readAsync(source_id, stable_id, cb)
    local UI = require("ui/uimanager")
    local key = keyOf(source_id, stable_id)
    local finished, active, step = false, nil, nil
    local list, after, fetched_at, revision = {}, 0, nil, nil
    local function finish(result, err)
        if finished then return end
        finished = true
        if err then logger.warn("book.toc read failed", source_id, stable_id, err) end
        cb(result, err)
    end
    step = require("ui.guard").wrap("toc read", function()
        if finished then return end
        if cache[key] then finish(cache[key].list); return end
        local current_at, current_revision = TocDB.snapshot(source_id, stable_id)
        if not revision then
            if not current_revision then
                local payload, legacy_at = require("book.books_db").getToc(source_id, stable_id)
                if not payload then finish(nil); return end
                active = Toc.parseAsync(source_id, stable_id, function()
                    local decoded, _position, err = require("dkjson").decode(payload)
                    if type(decoded) ~= "table" then return nil, err or "invalid legacy toc" end
                    return decoded
                end, finish, legacy_at)
                return
            end
            fetched_at, revision = current_at, current_revision
        elseif revision ~= current_revision then
            finish(nil, "toc snapshot changed"); return
        end
        local page = TocDB.readPage(source_id, stable_id, after)
        if not page then finish(nil, "toc read failed"); return end
        for _idx, chapter in ipairs(page) do list[#list + 1] = chapter end
        if #page < 16 then
            putCache(key, build(list, fetched_at))
            finish(list)
        else
            after = page[#page].idx
            UI:scheduleIn(0.01, step)
        end
    end)
    UI:nextTick(step)
    return { cancel = function()
        if finished then return end
        finished = true
        UI:unschedule(step)
        if active then active.cancel() end
    end }
end

--- 开书要不要后台拉新：间隔内已成功拉过或已尝试过则否。真要拉时记一次尝试（失败也算）。
---@param source_id string
---@param stable_id string
---@return boolean
function Toc.allowRefresh(source_id, stable_id)
    local key = keyOf(source_id, stable_id)
    local now = os.time()
    local attempted = last_attempt[key]
    if attempted and now - attempted < Toc.REFRESH_INTERVAL then
        return false
    end
    local hit = entry(source_id, stable_id)
    if hit and now - hit.fetched_at < Toc.REFRESH_INTERVAL then
        return false
    end
    last_attempt[key] = now
    return true
end

--- 落库并接管内存缓存（目录刚拉到手，无需再 decode 一遍）。
---@param source_id string
---@param stable_id string
---@param list BookChapter[]
---@return boolean
function Toc.put(source_id, stable_id, list)
    if not TocDB.put(source_id, stable_id, list) then return false end
    local key = keyOf(source_id, stable_id)
    putCache(key, build(list, os.time()))
    return true
end

--- 补一章字数（缓存正文后回填）：只写这一行，不序列化目录、不改变拉取时间。
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
    if not TocDB.update(source_id, stable_id, idx, "words", words) then
        logger.warn("book.toc setWords failed", source_id, stable_id, idx)
        return
    end
    chapter.words = words
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
        if not TocDB.update(source_id, stable_id, idx, "paid", paid) then
            logger.warn("book.toc markPaid failed", source_id, stable_id, idx)
            return
        end
        chapter.paid = paid
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
---@param stale boolean|nil 兼容旧调用方
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
---@param stale boolean|nil 兼容旧调用方
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
    if not require("book.books_db").clearToc(source_id, stable_id) then
        logger.warn("book.toc clear failed", source_id, stable_id)
        return
    end
    Toc.invalidate(source_id, stable_id)
end

--- 库中的身份 / 快照变更后作废对应内存，不再访问数据库。
function Toc.invalidate(source_id, stable_id)
    local key = keyOf(source_id, stable_id)
    dropCache(key)
    last_attempt[key] = nil
end

--- 清空进程内目录缓存；落库的 books.toc 不受影响。
function Toc.clear()
    cache = {}
    count = 0
    last_attempt = {}
end

return Toc
