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
---@return table[]
function Notes.localizeAnnotations(document, annotations, html_path)
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
    local out = {}
    for _, item in ipairs(annotations) do
        local ann = item
        if type(item) == "table" and not item.pos0 then
            -- range 是原始章节 HTML 的 rune 索引（含标签），不能按可见文本切片；
            -- 只能拿已解码的 markText 去正文里定位，range 仅用于重复文本消歧。
            local needle = item.text
            if type(needle) == "string" and needle ~= "" then
                local pos0, pos1 = Annotations.locate(flow, needle, item.wr_range)
                if pos0 then
                    ann = {}
                    for k, v in pairs(item) do
                        ann[k] = v
                    end
                    ann.pos0 = pos0
                    ann.pos1 = pos1
                    ann.page = pos0
                    if document and type(document.getPageFromXPointer) == "function" then
                        local ok, pageno = pcall(document.getPageFromXPointer, document, pos0)
                        if ok and pageno then
                            ann.pageno = pageno
                        end
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
    local out = {}
    for _, row in ipairs(items) do
        if type(row) == "table" and Notes.isHighlightRow(row) then
            local uid = tostring(row.chapterUid or row.chapter_uid or "")
            if not chapter_uid or uid == tostring(chapter_uid) then
                local range = tostring(row.range or "")
                local text = Notes.decodeMarkText(row.markText or row.bookmarkText or row.text or "")
                local review = review_by_range[range]
                local note = review and review.content or ""
                local wr_review_id = review and review.reviewId or nil
                local ts = tonumber(row.createTime or row.updateTime) or os.time()
                local idx = tonumber(row.chapterIdx or row.chapter_idx)
                if not idx then
                    idx = chapter_idx_by_uid[uid]
                end
                if not idx and source_id and stable_id then
                    idx = Toc.index(source_id, stable_id, row.chapterUid or row.chapter_uid)
                end
                -- page/pos0/pos1 留空：开章后由 localizeAnnotations 按 wr_range 补
                -- xpointer。数字占位会让 KOReader 误判整份注解为 mupdf 格式。
                out[#out + 1] = {
                    datetime = os.date("%Y-%m-%d %H:%M:%S", ts),
                    datetime_updated = os.date("%Y-%m-%d %H:%M:%S", ts),
                    drawer = "lighten",
                    color = "yellow",
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
    return out
end

--- 待上传的划线想法（划线已登记远端 id）。
---@param annotations table[]|nil
---@return table[]
function Notes.notePushCandidates(annotations)
    local out = {}
    for _, item in ipairs(annotations or {}) do
        if type(item) == "table" and type(item.note) == "string" and item.note ~= ""
                and type(item.wr_range) == "string" and item.wr_range ~= ""
                and item.wr_bookmark_id then
            out[#out + 1] = item
        end
    end
    return out
end

--- KOReader 注解 → ``/review/add`` 请求体（经 Agent 网关）。
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

--- KOReader 注解 → ``/review/useredit`` 请求体。
---@param annotation table
---@return table|nil body
---@return string|nil err
function Notes.toReviewEditBody(annotation)
    if type(annotation) ~= "table" then
        return nil, "invalid annotation"
    end
    local review_id = annotation.wr_review_id
    if type(review_id) ~= "string" and type(review_id) ~= "number" then
        return nil, "missing review id"
    end
    local content = annotation.note
    if type(content) ~= "string" or content == "" then
        return nil, "empty note"
    end
    return {
        reviewId = tostring(review_id),
        content = content,
    }, nil
end

--- 待上传的本地划线（跳过已登记远端 id）。
---@param annotations table[]|nil
---@return table[]
function Notes.pushCandidates(annotations)
    local out = {}
    for _, item in ipairs(annotations or {}) do
        if type(item) == "table" and item.drawer
                and type(item.text) == "string" and item.text ~= ""
                and not item.wr_bookmark_id then
            out[#out + 1] = item
        end
    end
    return out
end

--- KOReader 注解 → addBookmark 请求体。
---@param book_id string
---@param chapter_uid string|number
---@param chapter_idx integer
---@param book_version number
---@param annotation table
---@param html string|nil
---@return table|nil body
---@return string|nil err
function Notes.toBookmarkBody(book_id, chapter_uid, chapter_idx, book_version, annotation, html)
    if type(annotation) ~= "table" then
        return nil, "invalid annotation"
    end
    local text = annotation.text
    if type(text) ~= "string" or text == "" then
        return nil, "empty highlight"
    end
    local range = annotation.wr_range
    if type(range) ~= "string" or range == "" then
        range = html and Annotations.findRange(html, text) or nil
    end
    if not range then
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
