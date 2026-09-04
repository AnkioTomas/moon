--[[--
微信读书划线/想法 ↔ KOReader 注解与 HTML 注入。

@module koplugin.book.source.wechat.notes
--]]

local Text = require("utils.text")
local Annotations = require("source.wechat.annotations")
local Toc = require("source.wechat.toc")

local Notes = {}

local COLOR_STYLE = {
    blue = 1,
    green = 2,
    yellow = 3,
    purple = 4,
    orange = 5,
    lightgray = 5,
    gray = 5,
    cyan = 1,
    red = 5,
    pink = 4,
}

local LOCAL_COLOR = {
    [1] = "blue",
    [2] = "green",
    [3] = "yellow",
    [4] = "purple",
    [5] = "orange",
}

--- 是否为个人划线（bookmarklist ``updated`` 条目；排除 type=0 书签位）。
---@param row table
---@return boolean
function Notes.isHighlightRow(row)
    if type(row) ~= "table" then
        return false
    end
    local kind = tonumber(row.type)
    if kind == 0 then
        return false
    end
    return tostring(row.range or "") ~= ""
end

--- 微信划线 → 可在阅读器内显示的原生注解（按段落偏移直算 xpointer）。
---@param document table|nil
---@param annotations table[]
---@param html_path string|nil 章节 HTML 路径
---@param current table[]|nil 阅读器已有注解；同一远端 id 优先复用已验证的 xpointer
---@return table[]
function Notes.localizeAnnotations(document, annotations, html_path, current)
    if type(annotations) ~= "table" then
        return {}
    end
    local html
    if type(html_path) == "string" and html_path ~= "" then
        local f = io.open(html_path, "rb")
        if f then
            html = f:read("*a")
            f:close()
        end
    end
    if not html then
        return annotations
    end
    -- rune 流只随 HTML 变，整章建一次给所有划线复用。
    local flow = Annotations.flow(html)
    local positioned = {}
    for _, item in ipairs(current or {}) do
        if type(item) == "table" and item.wr_bookmark_id and item.pos0 and item.pos1 then
            positioned[tostring(item.wr_bookmark_id)] = item
        end
    end
    local unresolved = {}
    for _, item in ipairs(annotations) do
        if type(item) == "table" and not item.pos0 then
            unresolved[#unresolved + 1] = item
        end
    end
    local located = Annotations.locateBatch(flow, unresolved)
    local out = {}
    for _, item in ipairs(annotations) do
        local ann = item
        if type(item) == "table" and not item.pos0 then
            local saved = item.wr_bookmark_id and positioned[tostring(item.wr_bookmark_id)] or nil
            local location = located[item]
            if saved or location then
                ann = {}
                for k, v in pairs(item) do ann[k] = v end
                -- 当前章节文本能唯一确定时以重算结果为准，顺手修复旧版本留下的错位坐标；
                -- 只有仍然歧义时才保留同 bookmarkId 的既有原生位置。
                if location then
                    ann.pos0, ann.pos1, ann.page = location.pos0, location.pos1, location.pos0
                    ann.pageno = nil
                else
                    ann.pos0, ann.pos1 = saved.pos0, saved.pos1
                    ann.page, ann.pageno = saved.page or saved.pos0, saved.pageno
                end
                if not ann.pageno and document and type(document.getPageFromXPointer) == "function" then
                    local ok, pageno = pcall(document.getPageFromXPointer, document, ann.pos0)
                    if ok and pageno then
                        ann.pageno = pageno
                    end
                end
            end
        end
        if type(ann) == "table" then
            out[#out + 1] = ann
        end
    end
    return out
end

--- bookmarklist 的 markText 可能是 base64。
---@param value any
---@return string
function Notes.decodeMarkText(value)
    local raw = tostring(value or "")
    if raw == "" then
        return ""
    end
    if raw:match("^[%w%+/]+=*$") and #raw % 4 == 0 then
        local decoded = Text.base64Decode(raw)
        if type(decoded) == "string" and decoded ~= "" and Text.isValidUtf8(decoded) then
            return decoded
        end
    end
    return raw
end

---@param color string|nil
---@return integer
function Notes.colorStyle(color)
    if type(color) ~= "string" then
        return 5
    end
    return COLOR_STYLE[color] or 5
end

---@param style any
---@return string|nil
function Notes.localColor(style)
    return LOCAL_COLOR[tonumber(style)]
end

--- ``/review/list/mine`` wire → 按 ``range`` 索引的划线想法。
---
--- 想法条目形如 ``{ review = { range, content, reviewId } }``；无 ``range`` 的是
--- 整本书评或章节点评，不挂到划线上。
---@param wire table|nil
---@return table<string, table>
function Notes.reviewsByRange(wire)
    local out = {}
    if type(wire) ~= "table" then
        return out
    end
    for _, entry in ipairs(wire.reviews or {}) do
        local review = type(entry) == "table" and (entry.review or entry) or nil
        if type(review) == "table" then
            local range = tostring(review.range or "")
            local content = review.content
            if range ~= "" and type(content) == "string" and content ~= "" then
                out[range] = review
            end
        end
    end
    return out
end

---@param wire table|nil
---@return table<string, boolean>
function Notes.reviewIds(wire)
    local out = {}
    for _, entry in ipairs(type(wire) == "table" and wire.reviews or {}) do
        local review = type(entry) == "table" and (entry.review or entry) or nil
        local id = type(review) == "table" and (review.reviewId or entry.reviewId) or nil
        if id then out[tostring(id)] = true end
    end
    return out
end

--- 用完整远端想法快照回填 reviewId；新增请求已成功但本地未确认时可避免重复提交。
---@param annotations table[]
---@param wire table|nil
---@return table<table, boolean>
function Notes.reconcileReviews(annotations, wire)
    local by_id, by_key, by_semantic = {}, {}, {}
    for _, entry in ipairs(type(wire) == "table" and wire.reviews or {}) do
        local review = type(entry) == "table" and (entry.review or entry) or nil
        if type(review) == "table" then
            local id = review.reviewId or entry.reviewId
            if id then by_id[tostring(id)] = review end
            local range = tostring(review.range or "")
            local content = review.content
            local abstract = review.abstract or review.contextAbstract
            if range ~= "" and type(content) == "string" and type(abstract) == "string" then
                local key = table.concat({ range, abstract, content }, "\31")
                if by_key[key] == nil then by_key[key] = review else by_key[key] = false end
                local semantic = table.concat({ abstract, content }, "\31")
                if by_semantic[semantic] == nil then
                    by_semantic[semantic] = review
                else
                    by_semantic[semantic] = false
                end
            end
        end
    end
    local confirmed = {}
    for _, item in ipairs(annotations or {}) do
        if type(item) == "table" and not item.wr_deleted
                and type(item.note) == "string" and item.note ~= "" then
            local review = item.wr_review_id and by_id[tostring(item.wr_review_id)] or nil
            if not review and not item.wr_review_id and item.wr_range and item.text then
                review = by_key[table.concat({
                    tostring(item.wr_range), item.text, item.note,
                }, "\31")]
            end
            if not review and not item.wr_review_id and item.text then
                review = by_semantic[table.concat({ item.text, item.note }, "\31")]
            end
            if review then
                item.wr_review_id = review.reviewId
                confirmed[item] = true
            end
        end
    end
    return confirmed
end

---@param wire table|nil
---@param chapter_uid string|number
---@return table<string, boolean>
function Notes.bookmarkIds(wire, chapter_uid)
    local out = {}
    for _, row in ipairs(type(wire) == "table" and wire.updated or {}) do
        if type(row) == "table"
                and tostring(row.chapterUid or row.chapter_uid or "") == tostring(chapter_uid)
                and Notes.isHighlightRow(row) then
            local id = row.bookmarkId or row.id
            if id then out[tostring(id)] = true end
        end
    end
    return out
end

--- bookmarklist wire → 通用 KOReader 注解（``chapter_idx`` 用于按章分片落库）。
---@param wire table
---@param chapter_uid string|nil 非 nil 时只返回该章
---@param reviews table|nil ``/review/list/mine`` wire
---@param source_id string|nil
---@param stable_id string|nil
---@return table[]
function Notes.toAnnotations(wire, chapter_uid, reviews, source_id, stable_id)
    local items = (type(wire) == "table" and wire.updated) or {}
    local chapter_idx_by_uid = {}
    if type(wire) == "table" and type(wire.chapters) == "table" then
        for _, ch in ipairs(wire.chapters) do
            if type(ch) == "table" then
                local uid = tostring(ch.chapterUid or ch.chapter_uid or "")
                local idx = tonumber(ch.chapterIdx or ch.chapter_idx)
                if uid ~= "" and idx then
                    chapter_idx_by_uid[uid] = idx
                end
            end
        end
    end
    local review_by_range = Notes.reviewsByRange(reviews)
    local matched_reviews = {}
    local out = {}
    for _, row in ipairs(items) do
        if type(row) == "table" and Notes.isHighlightRow(row) then
            local uid = tostring(row.chapterUid or row.chapter_uid or "")
            if not chapter_uid or uid == tostring(chapter_uid) then
                local range = tostring(row.range or "")
                local text = Notes.decodeMarkText(row.markText or row.bookmarkText or row.text or "")
                local review = review_by_range[range]
                if review then matched_reviews[review] = true end
                local note = review and review.content or nil
                local wr_review_id = review and review.reviewId or nil
                local ts = tonumber(row.createTime or row.updateTime) or os.time()
                -- bookmarklist 的 chapterIdx 是微信原始序号；本地目录过滤过封面和空章，
                -- 必须优先按 uid 映射，不能把原始序号直接当本地章节号。
                local idx = source_id and stable_id
                    and Toc.index(source_id, stable_id, row.chapterUid or row.chapter_uid)
                    or nil
                idx = idx or tonumber(row.chapterIdx or row.chapter_idx)
                    or chapter_idx_by_uid[uid]
                -- page/pos0/pos1 留空：开章后由 localizeAnnotations 按 wr_range 补
                -- xpointer。数字占位会让 KOReader 误判整份注解为 mupdf 格式。
                out[#out + 1] = {
                    datetime = os.date("%Y-%m-%d %H:%M:%S", ts),
                    datetime_updated = os.date("%Y-%m-%d %H:%M:%S", ts),
                    drawer = "lighten",
                    color = Notes.localColor(row.colorStyle),
                    text = text,
                    note = note,
                    chapter = row.chapterTitle or "",
                    chapter_idx = idx,
                    wr_range = range ~= "" and range or nil,
                    wr_bookmark_id = row.bookmarkId or row.id,
                    wr_review_id = wr_review_id,
                }
            end
        end
    end
    -- 有想法不等于 bookmarklist 必有同 range 划线。微信允许直接发表选中文本想法；
    -- 这种条目也必须映射为 KOReader 原生高亮+笔记，不能静默丢掉。
    for _, entry in ipairs(type(reviews) == "table" and reviews.reviews or {}) do
        local review = type(entry) == "table" and (entry.review or entry) or nil
        if type(review) == "table" and not matched_reviews[review] then
            local uid = tostring(review.chapterUid or review.chapter_uid or "")
            local range = tostring(review.range or "")
            local text = review.abstract or review.contextAbstract
            local content = review.content
            if range ~= "" and type(text) == "string" and text ~= ""
                    and type(content) == "string" and content ~= ""
                    and (not chapter_uid or uid == tostring(chapter_uid)) then
                local idx = source_id and stable_id
                    and Toc.index(source_id, stable_id, review.chapterUid or review.chapter_uid)
                    or nil
                idx = idx or tonumber(review.chapterIdx or review.chapter_idx)
                    or chapter_idx_by_uid[uid]
                local ts = tonumber(review.createTime or review.updateTime) or os.time()
                out[#out + 1] = {
                    datetime = os.date("%Y-%m-%d %H:%M:%S", ts),
                    datetime_updated = os.date("%Y-%m-%d %H:%M:%S", ts),
                    drawer = "lighten",
                    color = Notes.localColor(review.colorStyle),
                    text = text,
                    note = content,
                    chapter = review.chapterTitle or "",
                    chapter_idx = idx,
                    wr_range = range,
                    wr_review_id = review.reviewId or entry.reviewId,
                    wr_review_only = true,
                }
            end
        end
    end
    return out
end

--- 待上传的划线想法（划线已登记远端 id）。
---@param annotations table[]|nil
---@return table[]
function Notes.notePushCandidates(annotations)
    local out = {}
    for _, item in ipairs(annotations or {}) do
        if type(item) == "table" and type(item.note) == "string" and item.note ~= ""
                and ((item.wr_review_id and item.wr_update_review)
                    or (not item.wr_review_id
                        and (item.wr_bookmark_id or item.wr_review_only)
                        and type(item.wr_range) == "string" and item.wr_range ~= "")) then
            out[#out + 1] = item
        end
    end
    return out
end

---@param annotations table[]|nil
---@return table[]
function Notes.deleteCandidates(annotations)
    local out = {}
    for _, item in ipairs(annotations or {}) do
        if type(item) == "table" and (item.wr_deleted or item.wr_delete_review) then
            out[#out + 1] = item
        end
    end
    return out
end

---@param annotations table[]|nil
---@return table[]
function Notes.bookmarkUpdateCandidates(annotations)
    local out = {}
    for _, item in ipairs(annotations or {}) do
        if type(item) == "table" and not item.wr_deleted
                and item.wr_bookmark_id and item.wr_update_bookmark then
            out[#out + 1] = item
        end
    end
    return out
end

---@param annotation table
---@return table
function Notes.toBookmarkUpdateBody(annotation)
    return {
        bookmarkId = tostring(annotation.wr_bookmark_id),
        style = 1,
        colorStyle = Notes.colorStyle(annotation.color),
    }
end

--- KOReader 注解 → ``/web/review/add`` 请求体。
---@param book_id string
---@param chapter_uid string|number
---@param annotation table
---@return table|nil body
---@return string|nil err
function Notes.toReviewBody(book_id, chapter_uid, annotation)
    if type(annotation) ~= "table" then
        return nil, "invalid annotation"
    end
    local content = annotation.note
    if type(content) ~= "string" or content == "" then
        return nil, "empty note"
    end
    local range = annotation.wr_range
    if type(range) ~= "string" or range == "" then
        return nil, "missing range"
    end
    local abstract = annotation.text
    if type(abstract) ~= "string" or abstract == "" then
        return nil, "missing highlight text"
    end
    return {
        bookId = tostring(book_id),
        content = content,
        type = 1,
        range = range,
        abstract = abstract,
        chapterUid = tonumber(chapter_uid) or chapter_uid,
    }, nil
end

--- KOReader 注解 → ``/web/review/edit`` 请求体。
---@param book_id string
---@param chapter_uid string|number
---@param annotation table
---@return table|nil body
---@return string|nil err
function Notes.toReviewEditBody(book_id, chapter_uid, annotation)
    if type(annotation) ~= "table" then
        return nil, "invalid annotation"
    end
    local review_id = annotation.wr_review_id
    if type(review_id) ~= "string" and type(review_id) ~= "number" then
        return nil, "missing review id"
    end
    local body, err = Notes.toReviewBody(book_id, chapter_uid, annotation)
    if not body then return nil, err end
    body.reviewId = tostring(review_id)
    return body, nil
end

--- 待上传的本地划线（跳过已登记远端 id）。
---@param annotations table[]|nil
---@return table[]
function Notes.pushCandidates(annotations)
    local out = {}
    for _, item in ipairs(annotations or {}) do
        if type(item) == "table" and item.drawer
                and type(item.text) == "string" and item.text ~= ""
                and (type(item.note) ~= "string" or item.note == "")
                and not item.wr_bookmark_id and not item.wr_review_id then
            out[#out + 1] = item
        end
    end
    return out
end

--- 用 bookmarklist 的 canonical 字段回填本地注解。
--- 已有 id 优先；无 id 时只接受 ``text + 当前 wire range`` 精确匹配，避免同文句串线。
---@param annotations table[]
---@param wire table|nil
---@param chapter_uid string|number
---@return integer matched
---@return table<table, boolean> confirmed
function Notes.reconcileBookmarks(annotations, wire, chapter_uid)
    local by_id, by_key = {}, {}
    for _, row in ipairs(type(wire) == "table" and wire.updated or {}) do
        local uid = tostring(row.chapterUid or row.chapter_uid or "")
        if type(row) == "table" and uid == tostring(chapter_uid) and Notes.isHighlightRow(row) then
            local id = row.bookmarkId or row.id
            local range = tostring(row.range or "")
            local text = Notes.decodeMarkText(row.markText or row.bookmarkText or row.text or "")
            if id then by_id[tostring(id)] = row end
            if text ~= "" and range ~= "" then
                local key = text .. "\31" .. range
                if by_key[key] == nil then
                    by_key[key] = row
                else
                    by_key[key] = false
                end
            end
        end
    end
    local matched, confirmed = 0, {}
    for _, item in ipairs(annotations or {}) do
        if type(item) == "table" then
            local row = item.wr_bookmark_id and by_id[tostring(item.wr_bookmark_id)] or nil
            if not row and not item.wr_bookmark_id and item.text and item.wr_range then
                row = by_key[item.text .. "\31" .. tostring(item.wr_range)]
            end
            if row then
                item.wr_bookmark_id = row.bookmarkId or row.id
                item.wr_range = tostring(row.range)
                matched = matched + 1
                confirmed[item] = true
            end
        end
    end
    return matched, confirmed
end

--- KOReader 注解 → addBookmark 请求体。
---@param book_id string
---@param chapter_uid string|number
---@param chapter_idx integer
---@param book_version number
---@param annotation table
---@return table|nil body
---@return string|nil err
function Notes.toBookmarkBody(book_id, chapter_uid, chapter_idx, book_version, annotation)
    if type(annotation) ~= "table" then
        return nil, "invalid annotation"
    end
    local text = annotation.text
    if type(text) ~= "string" or text == "" then
        return nil, "empty highlight"
    end
    local range = annotation.wr_range
    if type(range) ~= "string" or range == "" then
        return nil, "无法定位划线范围"
    end
    return {
        bookId = tostring(book_id),
        chapterUid = tonumber(chapter_uid) or chapter_uid,
        chapterIdx = chapter_idx,
        bookVersion = book_version,
        type = 1,
        style = 1,
        colorStyle = Notes.colorStyle(annotation.color),
        range = range,
        -- addBookmark 的 markText 需 base64(UTF-8)
        markText = Text.base64Encode(text),
    }, nil
end

return Notes
