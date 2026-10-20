--[[--
段评预缓存：从指定章起，逐章拉热点，再拉最热的几句各前几页，落 `book.review_cache`，之后离线可读。

段评接口是风控重点，所以三道闸：章数、每章句数、每句页数都有硬上限；每次真实请求后停顿 INTERVAL 秒；
任何一次失败立即停（不重试、不绕过），已落库的下次不再请求。不缓存图片。
命中缓存的步骤不发请求也不停顿，所以中断后重跑只补缺的。

@module koplugin.book.book.review_prefetch
--]]

local Chapter = require("source.chapter")
local ReviewCache = require("book.review_cache")
local UIManager = require("ui/uimanager")

local Prefetch = {}

Prefetch.MAX_CHAPTERS = 50
local TOP_HOTSPOTS = 10
local PAGES = 2
local INTERVAL = 2

--- 源是否有段评、且用户开了（设置里的「显示他人段评」）。
---@param source table|nil
---@return boolean
function Prefetch.supported(source)
    return source ~= nil and source.paragraphHotspotsAsync ~= nil and source:paragraphReviewsEnabled() == true
end

--- 缓存一段章节的段评。
---@param source table 提供 loadTocAsync / paragraphHotspotsAsync / paragraphReviewPageAsync
---@param identity BookIdentity source_id + stable_id
---@param range ChapterCacheRange|nil 起点；章数上限 MAX_CHAPTERS
---@param on_progress fun(done: integer, total: integer)|nil
---@param cb fun(ok: boolean, done: integer, total: integer, err: string|nil)
---@return { cancel: fun() }
function Prefetch.run(source, identity, range, on_progress, cb)
    local cancelled, job, timer = false, nil, nil
    local handle = { cancel = function()
        cancelled = true
        if timer then UIManager:unschedule(timer) end
        if job then job.cancel() end
    end }

    job = source:loadTocAsync(identity, function(toc, err)
        if cancelled then return end
        if not toc then return cb(false, 0, 0, err) end
        local from, count = Chapter.cacheRange(toc, range)
        local total = math.min(count, Prefetch.MAX_CHAPTERS)

        --- 有缓存直接继续；否则请求，成功后停顿再继续，失败整体结束。
        local function step(cached, request, cont, done_chapters)
            if cached then return cont(cached) end
            job = request(function(value, request_err)
                if cancelled then return end
                if not value then return cb(false, done_chapters, total, request_err) end
                timer = function() cont(value) end
                UIManager:scheduleIn(INTERVAL, timer)
            end)
        end

        local function chapter(n)
            if cancelled then return end
            if on_progress then on_progress(n, total) end
            if n >= total then return cb(true, n, total) end
            local ident = {
                source_id = identity.source_id, stable_id = identity.stable_id,
                chapter_idx = from + n + 1, source = source,
            }
            step(ReviewCache.hotspots(ident), function(done)
                return source:paragraphHotspotsAsync(ident, done)
            end, function(hotspots)
                local top = {}
                for _idx, spot in ipairs(hotspots) do top[#top + 1] = spot end
                table.sort(top, function(a, b) return (a.total or 0) > (b.total or 0) end)
                for i = #top, TOP_HOTSPOTS + 1, -1 do top[i] = nil end
                local function spot(k)
                    if k > #top then return chapter(n + 1) end
                    local rng = top[k].range
                    local function page(p, max_idx)
                        if p > PAGES then return spot(k + 1) end
                        step(ReviewCache.page(ident, rng, max_idx), function(done)
                            return source:paragraphReviewPageAsync(ident, rng, max_idx, done)
                        end, function(result)
                            if result.more and #result.items > 0 then return page(p + 1, result.max_idx) end
                            return spot(k + 1)
                        end, n)
                    end
                    return page(1, 0)
                end
                return spot(1)
            end, n)
        end
        chapter(0)
    end)
    return handle
end

return Prefetch
