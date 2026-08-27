--[[--
微信读书划线/想法 → KOReader 注解与 HTML 注入。

@module koplugin.book.source.wechat.notes
--]]

local Notes = {}

--- 从 toc 缓存解析 chapter_idx → uid。
---@param identity BookIdentity
---@return string|nil
local function chapterUid(identity)
    if not identity or not identity.chapter_idx then return nil end
    local payload = require("utils.db.toc").get(identity.source_id, identity.stable_id, 6 * 60 * 60)
    if not payload then return nil end
    local ok, toc = pcall(function() return require("json").decode(payload) end)
    if not ok or type(toc) ~= "table" then return nil end
    local ch = toc[tonumber(identity.chapter_idx) or 0]
    return ch and ch.uid
end

--- 收集章节 range 列表（想法 API 批次用）。
---@param underlines table|nil
---@return string[]
function Notes.collectRanges(underlines)
    local ranges, seen = {}, {}
    if type(underlines) ~= "table" then return ranges end
    for _, ul in ipairs(underlines.underlines or underlines.updated or underlines) do
        if type(ul) == "table" then
            local range = tostring(ul.range or "")
            if range ~= "" and not seen[range] then
                seen[range] = true
                ranges[#ranges + 1] = range
            end
        end
    end
    return ranges
end

--- 构造 readreviews 批次。
---@param ranges string[]
---@return table[]
function Notes.reviewBatches(ranges)
    local batches = {}
    for i = 1, #(ranges or {}), 5 do
        local batch = {}
        for j = i, math.min(i + 4, #ranges) do
            batch[#batch + 1] = { range = ranges[j], maxIdx = 0, count = 30, synckey = 0 }
        end
        batches[#batches + 1] = batch
    end
    return batches
end

--- bookmarklist wire → KOReader annotations（按章过滤）。
---@param wire table
---@param chapter_uid string|nil
---@param reviews table[]|nil
---@return table[]
function Notes.toAnnotations(wire, chapter_uid, reviews)
    local items = wire.updated or wire.items or wire.bookmarks or {}
    local review_by_range = {}
    for _, review in ipairs(reviews or {}) do
        if type(review) == "table" and review.range then
            review_by_range[tostring(review.range)] = review
        end
    end
    local out = {}
    for _, row in ipairs(items) do
        if type(row) == "table" then
            local uid = tostring(row.chapterUid or row.chapter_uid or "")
            if not chapter_uid or uid == tostring(chapter_uid) then
                local range = tostring(row.range or "")
                local text = row.markText or row.bookmarkText or row.text or ""
                local note = ""
                local review = review_by_range[range]
                if review and type(review.pageReviews) == "table" then
                    local page = review.pageReviews[1]
                    local item = page and (page.review or page)
                    if type(item) == "table" then
                        note = item.content or item.abstract or ""
                    end
                end
                local ts = tonumber(row.createTime or row.updateTime) or os.time()
                out[#out + 1] = {
                    datetime = ts,
                    datetime_updated = ts,
                    drawer = "lighten",
                    color = "lightgray",
                    text = text,
                    note = note,
                    chapter = row.chapterTitle or "",
                    page = 1,
                    pageno = 1,
                }
            end
        end
    end
    return out
end

--- 解析当前章 uid（identity 或 toc）。
---@param identity BookIdentity
---@return string|nil
function Notes.resolveChapterUid(identity)
    return chapterUid(identity)
end

return Notes
