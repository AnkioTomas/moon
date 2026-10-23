--[[--
起点段评：本章每段评论数、某段的评论页、把段落定位到章节 HTML。

走手机站接口（m.qidian.com/webcommon/chapterreview/*），匿名可读，见 `Client.reviewSummaryAsync`：
- reviewsummary4m：本章每段评论数；paragraphId 从 1 数，对应章节正文第 n 个 <p>（起点正文每个 <p> 都非空），-1 是章末总评。
- reviewlist4m：某段评论，page 从 1 起。
章节 HTML 的段落是非空行逐个包成 <p>（Text.textToBody），所以第 n 个 <p> 就是 paragraphId = n。

@module koplugin.book.source.qidian.reviews
--]]

local Client = require("source.qidian.client")
local ReviewLocate = require("book.review_locate")
local Text = require("utils.text")
local _ = require("gettext")

local Reviews = {}

---@class QidianReviewHotspot
---@field range string 段落序号（第几个 <p>）
---@field text string
---@field total integer 本段评论数

--- 统计回包 → 有评论的段落（未定位）；章末总评（-1）不是段，丢弃。
---@param data table
---@return QidianReviewHotspot[]
function Reviews.hotspots(data)
    local out = {}
    for _idx, row in ipairs(data.list or {}) do
        local pid, total = tonumber(row.paragraphId), tonumber(row.textCount) or 0
        if pid and pid > 0 and total > 0 then
            out[#out + 1] = { range = tostring(pid), text = "", total = total }
        end
    end
    table.sort(out, function(a, b) return tonumber(a.range) < tonumber(b.range) end)
    return out
end

--- 表情是「[fn=47]」这样的占位码，没有图可画，去掉。
---@param row table
---@return WechatReview
function Reviews.item(row)
    local body = tostring(row.content or ""):gsub("%[fn=%d+%]", "")
    local images = {}
    if tonumber(row.hasImage) == 1 and type(row.imagePre) == "string" and row.imagePre ~= "" then
        images[1] = { url = row.imagePre, width = 0, height = 0 }
    end
    return {
        id = tostring(row.reviewId or ""),
        author = tostring(row.nickName or ""),
        content = Text.trim(body),
        likes = tonumber(row.likeCount) or 0,
        images = images,
        time = tonumber(row.createTimestamp) or 0,
    }
end

--- 评论回包 → 一页。max_idx 存「已取到第几页」（首页请求带 0），避免依赖每页条数。
---@param data table
---@param page integer
---@return WechatReviewPage|nil, string|nil
function Reviews.page(data, page)
    if type(data.list) ~= "table" then return nil, _("起点段评响应缺少评论列表") end
    local items = {}
    for _idx, row in ipairs(data.list) do
        if type(row) == "table" and tonumber(row.status) ~= 0 then items[#items + 1] = Reviews.item(row) end
    end
    local total = tonumber(data.total) or #items
    return { items = items, total = total, max_idx = page, more = #data.list > 0 and page * #data.list < total }
end

--- 本章有评论的段落；这本书没开段评（enableReview ≠ 1）当没有。
---@param book_id string
---@param chapter_id string
---@param cb fun(hotspots: QidianReviewHotspot[]|nil, err: string|nil)
---@return HttpJob
function Reviews.hotspotsAsync(book_id, chapter_id, cb)
    return Client.reviewSummaryAsync(book_id, chapter_id, function(data, err)
        if not data then cb(nil, err); return end
        cb(tonumber(data.enableReview) == 1 and Reviews.hotspots(data) or {})
    end)
end

--- 某段的一页评论；max_idx 是已取页数（首页 0）。
---@param book_id string
---@param chapter_id string
---@param paragraph_id integer
---@param max_idx integer
---@param cb fun(page: WechatReviewPage|nil, err: string|nil)
---@return HttpJob
function Reviews.pageAsync(book_id, chapter_id, paragraph_id, max_idx, cb)
    local page = max_idx + 1
    return Client.reviewListAsync(book_id, chapter_id, paragraph_id, page, function(data, err)
        if not data then cb(nil, err); return end
        cb(Reviews.page(data, page))
    end)
end

--- 把有评论的段落定位到章节 HTML。
---@param hotspots QidianReviewHotspot[]
---@param html string
---@return table[]
function Reviews.locate(hotspots, html)
    return ReviewLocate.locate(ReviewLocate.paragraphs(html), hotspots, html)
end

return Reviews
