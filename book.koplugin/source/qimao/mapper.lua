--[[--
七猫 App 接口数据映射（纯函数）。

@module koplugin.book.source.qimao.mapper
--]]

local Text = require("utils.text")

local Mapper = {}

local SOURCE_ID = "qimao"

local CDN = "https://cdn.wtzw.com"

--- 书架行的封面是 `/bookimg/…` 相对路径。
---@param link string|nil
---@return string|nil
local function cover(link)
    if type(link) == "string" and link:sub(1, 1) == "/" then return CDN .. link end
    return link
end

--- 搜索 / 详情行用 id、title；个人书架行用 book_id、book_title。
---@param row table
---@return Book|nil
local function book(row)
    local raw = row.id or row.book_id
    local id = raw and tostring(raw)
    if not id or id == "" then return nil end
    return {
        source_id = SOURCE_ID,
        stable_id = id,
        title = row.original_title or row.title or row.book_title,
        authors = row.original_author or row.author,
        category = row.category2_name or row.ptags,
        intro = row.intro and Text.stripHtml(row.intro),
        cover = cover(row.image_link),
    }
end

--- 个人书架行 → Book[]。
---@param rows table[]
---@return Book[]
function Mapper.shelfList(rows)
    local out = {}
    for _idx, row in ipairs(rows) do out[#out + 1] = book(row) end
    return out
end

--- 本地书 → 书架同步条目（网页「加入书架」同款字段，图片只留 /bookimg/ 路径）。
---@param stable_id string
---@param row Book
---@param push_type "1"|"2"
---@return table
function Mapper.shelfItem(stable_id, row, push_type)
    local image = tostring(row.cover or ""):match("/bookimg/.*$") or ""
    return {
        book_id = stable_id,
        book_title = row.title or "",
        author = row.authors or "",
        image_link = image,
        push_type = push_type,
        add_type = "1",
        is_voice = "0",
        page_offset = "",
        alias_title = "",
        group_name = "",
        chapter_ver = "0",
        latest_read_chapter_id = "",
        latest_read_chapter_name = "",
        updated_at = tostring(os.time()),
    }
end

--- 书架行里的阅读位置。没有章号就是没读过。
---@param row table|nil
---@return { uid: string, title: string|nil }|nil
function Mapper.readChapter(row)
    local uid = type(row) == "table" and row.latest_read_chapter_id
    if uid == nil or tostring(uid) == "" or tonumber(uid) == 0 then return nil end
    local title = row.latest_read_chapter_name
    return { uid = tostring(uid), title = type(title) == "string" and title or nil }
end

--- 用书架上的原行改阅读位置再上行，避免空字段把书名、分组清掉。
--- 章没变就留着原来的段内偏移；换章则清掉，段内位置同步不了。
---@param row table
---@param chapter { uid: string, title: string|nil, idx: integer }
---@return table
function Mapper.progressItem(row, chapter)
    local item = {}
    for key, value in pairs(row) do item[key] = value end
    local same = tostring(row.latest_read_chapter_id or "") == chapter.uid
    item.push_type = "1"
    item.latest_read_chapter_id = chapter.uid
    item.latest_read_chapter_name = chapter.title or ""
    item.latest_read_chapter_index = tostring(chapter.idx)
    item.updated_at = tostring(os.time())
    if not same then
        item.page_offset = ""
        item.paragraph_index = "0"
    end
    return item
end

--- 搜索回包。高亮标签只出现在 title / author，原始值在 original_*。
---@param wire table|nil
---@return Book[]
function Mapper.search(wire)
    local rows = wire and wire.data and wire.data.books
    local out = {}
    for _idx, row in ipairs(type(rows) == "table" and rows or {}) do
        out[#out + 1] = book(row)
    end
    return out
end

--- 书库列表 → Book[]，并给出是否还有下一页。
---@param wire table|nil
---@return Book[], boolean
function Mapper.classify(wire)
    local data = wire and wire.data or {}
    local out = {}
    for _idx, row in ipairs(type(data.book_list) == "table" and data.book_list or {}) do
        out[#out + 1] = book(row)
    end
    local paging = data.page_data or {}
    return out, (tonumber(paging.page) or 0) * (tonumber(paging.page_size) or 0) < (tonumber(paging.count) or 0)
end

--- 目录：按 chapter_sort 排，idx 连续；章节 id 是 uid。
---@param wire table|nil
---@return BookChapter[]
function Mapper.toc(wire)
    local rows = wire and wire.data and wire.data.chapter_lists
    rows = type(rows) == "table" and rows or {}
    local sorted = {}
    for _idx, row in ipairs(rows) do
        if row.id then sorted[#sorted + 1] = row end
    end
    table.sort(sorted, function(a, b) return (tonumber(a.chapter_sort) or 0) < (tonumber(b.chapter_sort) or 0) end)
    local toc = {}
    for i, row in ipairs(sorted) do
        toc[i] = { idx = i, uid = tostring(row.id), title = row.title, words = tonumber(row.words) }
    end
    return toc
end

return Mapper
