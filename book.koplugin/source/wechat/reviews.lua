--[[--
微信读书段评（他人在本章某句下的点评）：本章热点与按句分页。

热点 = ``/web/book/underlines`` 的全部 range，分批 ``readReviews``（每句只要 1 条）换回原句
``abstract`` 与段评总数；原句经 ``Annotations.locateBatch`` 落到本地章节 xpointer，
定位不了（找不到 / 重复无法消歧）的热点直接丢弃，不画错位置。

@module koplugin.book.source.wechat.reviews
--]]

local Annotations = require("source.wechat.annotations")
local _ = require("gettext")

local PAGE_SIZE = 30
-- 服务端按 range 逐个查，整批 3 秒超时（errCode -10100）；实测每个约 30ms，一章常有 150 个。
local BATCH_SIZE = 40

local Reviews = {}

---@class WechatReviewSpot
---@field range string wire range，翻页时原样带回
---@field text string 原句
---@field total integer 段评总数
---@field pos0 string
---@field pos1 string

---@class WechatReview
---@field id string
---@field author string
---@field content string
---@field likes integer
---@field time integer 秒

---@class WechatReviewPage
---@field items WechatReview[]
---@field total integer
---@field max_idx integer 下一页请求带回
---@field more boolean

--- readReviews 回包 → 已定位的热点。
---@param wire table ``{ reviews = [{ range, totalCount, pageReviews[] }] }``
---@param html string 本地章节 HTML
---@return WechatReviewSpot[]
function Reviews.spots(wire, html)
    local items = {}
    for _idx, entry in ipairs(wire.reviews or {}) do
        local first = entry.pageReviews and entry.pageReviews[1]
        local total = tonumber(entry.totalCount) or 0
        if first and total > 0 then
            items[#items + 1] = {
                text = first.review.abstract,
                wr_range = entry.range,
                total = total,
            }
        end
    end
    local located = Annotations.locateBatch(html, items)
    local out = {}
    for _idx, item in ipairs(items) do
        local hit = located[item]
        if hit then
            out[#out + 1] = {
                range = item.wr_range, text = item.text, total = item.total,
                pos0 = hit.pos0, pos1 = hit.pos1,
            }
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
        author = review.author.name,
        content = review.content,
        likes = tonumber(entry.likesCount) or 0,
        time = tonumber(review.createTime) or 0,
    }
end

--- 拉本章热点：underlines → 批量 readReviews → 定位。
---@param client WechatClient
---@param book_id string
---@param chapter_uid string
---@param html string 本地章节 HTML
---@param cb fun(spots: WechatReviewSpot[]|nil, err: string|nil)
---@return { cancel: fun() }
function Reviews.spotsAsync(client, book_id, chapter_uid, html, cb)
    local job
    local cancelled = false
    job = client:underlinesAsync(book_id, chapter_uid, function(data, err)
        if cancelled then return end
        if not data then
            cb(nil, err)
            return
        end
        local ranges = {}
        for _idx, underline in ipairs(data.underlines or {}) do
            ranges[#ranges + 1] = { range = underline.range, maxIdx = 0, count = 1, synckey = 0 }
        end
        local collected = {}
        local function nextBatch(from)
            if from > #ranges then
                cb(Reviews.spots({ reviews = collected }, html))
                return
            end
            local batch = { unpack(ranges, from, math.min(from + BATCH_SIZE - 1, #ranges)) }
            job = client:readReviewsAsync(book_id, chapter_uid, batch, function(wire, review_err)
                if cancelled then return end
                if not wire then
                    cb(nil, review_err)
                    return
                end
                for _idx, entry in ipairs(wire.reviews or {}) do collected[#collected + 1] = entry end
                nextBatch(from + BATCH_SIZE)
            end)
        end
        nextBatch(1)
    end)
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
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
            items[#items + 1] = Reviews.item(review)
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
