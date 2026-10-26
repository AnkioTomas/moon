--[[--
微信读书段评（他人在本章某句下的点评）：本章热点与按句分页。

热点 = ``/web/book/underlines`` 的全部 range，分批并发 ``readReviews``（每句只要 1 条）换回原句
``abstract`` 与段评总数，缓存由 `book.review_cache` 统一做。拉取与定位分开：章会话在本章 HTML 上定位，关联书按页查找原句。
原句经 ``Annotations.locateBatch`` 落到 HTML 的 xpointer，定位不了（找不到 / 重复无法消歧）的直接丢弃，不画错位置。

@module koplugin.book.source.wechat.reviews
--]]

local Annotations = require("book.annotations")
local _ = require("gettext")

local PAGE_SIZE = 30
-- 服务端按 range 逐个查，整批 3 秒超时（errCode -10100）；实测每个约 30ms，一章常有 150～300 个。
local BATCH_SIZE = 40
-- 同时在飞的批数：串行时一章 8 批要 10 秒以上。
local CONCURRENCY = 3

local Reviews = {}

--- 未定位的热点。
---@class WechatReviewHotspot
---@field chapter_idx integer|nil 归属章序号
---@field badge string|nil 标记文案
---@field range string wire range，翻页时原样带回
---@field text string 原句
---@field total integer 段评总数

--- 已定位的热点。
---@class WechatReviewSpot: WechatReviewHotspot
---@field pos0 string
---@field pos1 string

---@class WechatReview
---@field id string
---@field author string
---@field content string
---@field likes integer
---@field images { url: string, width: integer, height: integer }[]|nil 评论配图（目前只有番茄）
---@field time integer 秒

---@class WechatReviewPage
---@field items WechatReview[]
---@field total integer
---@field max_idx integer 下一页请求带回
---@field more boolean

--- readReviews 回包 → 有段评的热点（未定位）。
---@param wire table ``{ reviews = [{ range, totalCount, pageReviews[] }] }``
---@return WechatReviewHotspot[]
function Reviews.hotspots(wire)
    local out = {}
    for _idx, entry in ipairs(wire.reviews or {}) do
        local first = entry.pageReviews and entry.pageReviews[1]
        local total = tonumber(entry.totalCount) or 0
        if first and total > 0 then
            out[#out + 1] = { range = entry.range, text = first.review.abstract, total = total }
        end
    end
    return out
end

--- 热点按原句定位到 html；xpointer 以该 HTML 的根为起点。
---@param hotspots WechatReviewHotspot[]
---@param html string
---@return WechatReviewSpot[]
function Reviews.locate(hotspots, html)
    local items = {}
    for i, spot in ipairs(hotspots) do items[i] = { text = spot.text, wr_range = spot.range, spot = spot } end
    local located = Annotations.locateBatch(html, items)
    local out = {}
    for _idx, item in ipairs(items) do
        local hit = located[item]
        if hit then
            local spot = item.spot
            out[#out + 1] = { range = spot.range, text = spot.text, total = spot.total, pos0 = hit.pos0, pos1 = hit.pos1 }
        end
    end
    return out
end

--- 单条 pageReviews → 展示项。
---@param entry table
---@return WechatReview
function Reviews.item(entry)
    local review = entry.review
    return {
        id = entry.reviewId,
        author = type(review.author) == "table" and review.author.name or "",
        content = review.content,
        likes = tonumber(entry.likesCount) or 0,
        time = tonumber(review.createTime) or 0,
    }
end

--- 拉本章热点：underlines → 并发分批 readReviews。
---@param client WechatClient
---@param book_id string
---@param chapter_uid string
---@param cb fun(hotspots: WechatReviewHotspot[]|nil, err: string|nil)
---@return { cancel: fun() }
function Reviews.hotspotsAsync(client, book_id, chapter_uid, cb)
    local cancelled = false
    local jobs = {}
    local function cancel()
        cancelled = true
        for _key, job in pairs(jobs) do job.cancel() end
    end
    jobs.underlines = client:underlinesAsync(book_id, chapter_uid, function(data, err)
        jobs.underlines = nil
        if cancelled then return end
        if not data then
            cb(nil, err)
            return
        end
        local batches = {}
        local underlines = data.underlines or {}
        for from = 1, #underlines, BATCH_SIZE do
            local batch = {}
            for i = from, math.min(from + BATCH_SIZE - 1, #underlines) do
                batch[#batch + 1] = { range = underlines[i].range, maxIdx = 0, count = 1, synckey = 0 }
            end
            batches[#batches + 1] = batch
        end
        local results, next_batch, pending = {}, 1, 0
        local function finish()
            local collected = {}
            for _idx, reviews in ipairs(results) do
                for _entry_idx, entry in ipairs(reviews) do collected[#collected + 1] = entry end
            end
            local hotspots = Reviews.hotspots({ reviews = collected })
            cb(hotspots)
        end
        local function launch()
            while next_batch <= #batches and pending < CONCURRENCY do
                local i = next_batch
                next_batch, pending = next_batch + 1, pending + 1
                jobs[i] = client:readReviewsAsync(book_id, chapter_uid, batches[i], function(wire, review_err)
                    jobs[i], pending = nil, pending - 1
                    if cancelled then return end
                    if not wire then
                        cancel()
                        cb(nil, review_err)
                        return
                    end
                    results[i] = wire.reviews or {}
                    if next_batch > #batches and pending == 0 then finish() else launch() end
                end)
            end
        end
        if #batches == 0 then finish() else launch() end
    end)
    return { cancel = cancel }
end

--- 拉某句的一页段评。
---@param client WechatClient
---@param book_id string
---@param chapter_uid string
---@param range string
---@param max_idx integer 首页 0，之后用上一页的 max_idx
---@param cb fun(page: WechatReviewPage|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Reviews.pageAsync(client, book_id, chapter_uid, range, max_idx, cb)
    return client:readReviewsAsync(book_id, chapter_uid, {
        { range = range, maxIdx = max_idx, count = PAGE_SIZE, synckey = 0 },
    }, function(wire, err)
        local entry = wire and wire.reviews and wire.reviews[1]
        if not entry then
            cb(nil, err or _("无法获取段评"))
            return
        end
        local items = {}
        for _idx, review in ipairs(entry.pageReviews or {}) do
            -- 已删除的段评只剩 reviewId，没有 review 体。
            if type(review) == "table" and type(review.review) == "table" then
                items[#items + 1] = Reviews.item(review)
            end
        end
        cb({
            items = items,
            total = tonumber(entry.totalCount) or #items,
            max_idx = tonumber(entry.maxIdx) or max_idx,
            more = tonumber(entry.hasMore) == 1,
        })
    end)
end

return Reviews
