--[[--
段评预缓存：从指定章起，逐章拉热点，再对每个热点句拉首页评论（只存前 10 条），落 `book.review_cache`，之后离线可读。

段评接口是风控重点：每次真实请求后停顿 INTERVAL 秒；任何一次失败立即停（不重试、不绕过），
已落库的下次不再请求。不缓存图片。
命中缓存的步骤不发请求也不停顿，所以中断后重跑只补缺的。

@module koplugin.book.book.review_prefetch
--]]

local Chapter = require("source.chapter")
local ReviewCache = require("book.review_cache")
local UIManager = require("ui/uimanager")

local Prefetch = {}

local INTERVAL = 1

--- 源是否有段评、且用户开了（设置里的「显示他人段评」）。
---@param source table|nil
---@return boolean
function Prefetch.supported(source)
    return source ~= nil and source.paragraphHotspotsAsync ~= nil and source:paragraphReviewsEnabled() == true
end

--- 缓存一段章节的段评。
---@param source table 提供 loadTocAsync / paragraphHotspotsAsync / paragraphReviewPageAsync
---@param identity BookIdentity source_id + stable_id
---@param range ChapterCacheRange|nil 缺省全本
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
        local total = count

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
                chapter_idx = from + n + 1, source = source, prefetch = true,
            }
            step(ReviewCache.hotspots(ident), function(done)
                return source:paragraphHotspotsAsync(ident, done)
            end, function(hotspots)
                local function spot(k)
                    if k > #hotspots then return chapter(n + 1) end
                    local rng = hotspots[k].range
                    step(ReviewCache.page(ident, rng, 0), function(done)
                        return source:paragraphReviewPageAsync(ident, rng, 0, done)
                    end, function() return spot(k + 1) end, n)
                end
                return spot(1)
            end, n)
        end
        chapter(0)
    end)
    return handle
end

return Prefetch
