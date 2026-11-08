--[[--
知乎盐选响应到榜单书籍、短篇与长篇目录。

搜索页打开 `search?type=km_general`，接口是 `/api/v4/search_v3`。
短篇 `stable_id` 是专栏 id 加节 id，长篇为专栏 id。`is_fold ~= false` 的节未购买。

@module source.zhihu.mapper
--]]

local Text = require("utils.text")

local Mapper = {}

Mapper.TOC_VERSION = 1
local SOURCE_ID = "zhihu"

---@param value any
---@return string
local function clean(value)
    if type(value) ~= "string" then return "" end
    return Text.trim(value:gsub("<[^>]+>", ""))
end

---@param url string|nil
---@return string|nil
---@return string|nil
local function idsOf(url)
    if type(url) ~= "string" then return nil end
    local well, section = url:match("/paid_column/(%d+)/section/(%d+)")
    if well then return well, section end
    return url:match("/paid_column/(%d+)")
end

---@param value any
---@return string
local function authors(value)
    if type(value) == "string" then return clean(value) end
    if type(value) ~= "table" then return "" end
    local names = {}
    for _idx, author in ipairs(value[1] and value or { value }) do
        local name = clean(type(author) == "table" and (author.name or author.user and author.user.name) or author)
        if name ~= "" then names[#names + 1] = name end
    end
    return table.concat(names, "、")
end

---@param value any
---@return string|nil
local function cover(value)
    if type(value) == "string" and value ~= "" then return value end
    if type(value) ~= "table" then return nil end
    local first = value[1]
    if type(first) == "string" and first ~= "" then return first end
    if type(first) == "table" and type(first.url) == "string" and first.url ~= "" then return first.url end
    return nil
end

---@param row table
---@return Book|nil
local function book(row)
    local well, section = idsOf(row.url)
    local title = clean(row.title)
    if not well or title == "" then return nil end
    local body = type(row.body) == "table" and row.body or row
    return {
        source_id = SOURCE_ID,
        stable_id = section and well .. "/" .. section or well,
        title = title,
        authors = authors(row.producer_name or body.authors or row.authors),
        cover = cover(row.artwork or row.tab_artwork or body.images),
        intro = section and clean(row.description or body.description) or nil,
    }
end

---@param wire table|nil
---@param rank string
---@return Book[]|nil
---@return table[]|nil
function Mapper.feed(wire, rank)
    if type(wire) ~= "table" or type(wire.data) ~= "table" or wire.error then return nil end
    for _idx, module in ipairs(wire.data) do
        local data = module.module_type == "billboard" and module.module_data and module.module_data.data
        for _row_idx, row in ipairs(data and data.data or {}) do
            if row.head and row.head.type == rank and type(row.content_list) == "table"
                and type(row.head.filters) == "table" then
                local out, seen = {}, {}
                for _book_idx, entry in ipairs(row.content_list) do
                    local item = book(entry)
                    if item and not seen[item.stable_id] then
                        seen[item.stable_id] = true
                        out[#out + 1] = item
                    end
                end
                return out, row.head.filters
            end
        end
    end
    return nil
end

---@param wire table|nil
---@return Book[]|nil
function Mapper.search(wire)
    if type(wire) ~= "table" or type(wire.data) ~= "table" or wire.error then return nil end
    local out, seen = {}, {}
    for _idx, row in ipairs(wire.data) do
        local object = type(row) == "table" and row.object or nil
        if type(object) == "table" then
            local body = type(object.body) == "table" and object.body or {}
            local item = book({
                url = object.url,
                title = body.title or object.title,
                authors = body.authors,
                description = body.description,
                artwork = body.images,
            })
            if item and not seen[item.stable_id] then
                seen[item.stable_id] = true
                out[#out + 1] = item
            end
        end
    end
    return out
end

---@param wire table|nil
---@param stable_id string
---@return BookChapter[]|nil
function Mapper.chapters(wire, stable_id)
    if stable_id:match("^%d+$") then
        if type(wire) ~= "table" or type(wire.data) ~= "table" then return nil end
        local chapters = {}
        for _idx, row in ipairs(wire.data) do
            if row.section_cell and row.section_cell.type == "article" then
                local uid, title = row.id, clean(row.title)
                if type(uid) ~= "string" or not uid:match("^%d+$") or title == "" then return nil end
                local right = row.right or {}
                chapters[#chapters + 1] = {
                    idx = #chapters + 1, uid = uid, title = title,
                    vip = row.is_free ~= true and right.has_purchased ~= true and right.has_ownership ~= true,
                    toc_version = Mapper.TOC_VERSION,
                }
            end
        end
        return chapters
    end
    if type(wire) ~= "table" or type(wire.section) ~= "table" then return nil end
    local _well, section = tostring(stable_id):match("^(%d+)/(%d+)$")
    local title = clean(wire.section.title)
    if not section or title == "" then return nil end
    return { {
        idx = 1,
        uid = section,
        title = title,
        vip = wire.is_fold ~= false,
        toc_version = Mapper.TOC_VERSION,
    } }
end

---@param wire table|nil
---@param stable_id string
---@param grading table|nil
---@return Book|nil
function Mapper.detail(wire, stable_id, grading)
    if stable_id:match("^%d+$") then
        if type(wire) ~= "table" or wire.error or clean(wire.title) == "" then return nil end
        local intro = {}
        for _idx, value in ipairs({ Text.stripHtml(wire.keypoint), Text.stripHtml(wire.content) }) do
            if value ~= "" then intro[#intro + 1] = value end
        end
        local score = grading and grading.show_score == true and tonumber(grading.score)
        return {
            source_id = SOURCE_ID, stable_id = stable_id,
            title = clean(wire.title), authors = authors(wire.authors),
            cover = cover(wire.tab_artwork or wire.artwork), intro = table.concat(intro, "\n\n"),
            meta = score and score > 0 and score <= 10 and { rating = { score = score, by = SOURCE_ID } } or nil,
        }
    end
    local chapters = Mapper.chapters(wire, stable_id)
    if not chapters then return nil end
    local column = type(wire.paid_column) == "table" and wire.paid_column or {}
    local section = wire.section
    local artwork = clean(section.head_artwork)
    if artwork == "" then artwork = clean(column.artwork) end
    return {
        source_id = SOURCE_ID,
        stable_id = tostring(stable_id),
        title = chapters[1].title,
        authors = "",
        cover = artwork ~= "" and artwork or nil,
        intro = "",
    }
end

---@param wire table
---@return { section_id: string, fraction?: number, updated_at?: integer }|nil
function Mapper.progress(wire)
    local progress = type(wire.cli_progress) == "table" and wire.cli_progress.unit_progress
    if type(progress) ~= "table" or type(wire.id) ~= "string" or not wire.id:match("^%d+$")
        or progress.unit_id ~= wire.id then return nil end
    local fraction = progress.progress
    if fraction ~= nil and (type(fraction) ~= "number" or fraction ~= fraction
        or fraction < 0 or fraction > 1) then return nil end
    if fraction == nil and progress.is_finished == true then fraction = 1 end
    local timestamp = progress.client_updated_at
    if timestamp ~= nil and (type(timestamp) ~= "number" or timestamp ~= timestamp
        or timestamp < 0 or timestamp == math.huge) then return nil end
    return {
        section_id = wire.id,
        fraction = fraction,
        updated_at = timestamp and math.floor(timestamp / 1000) or nil,
    }
end

---@param wire table|nil
---@param offset integer|string
---@return WechatReviewPage|nil
function Mapper.reviewPage(wire, offset)
    if type(wire) ~= "table" or wire.error or type(wire.data) ~= "table"
        or type(wire.paging) ~= "table" or type(wire.paging.is_end) ~= "boolean" then return nil end
    local paging = wire.paging
    local total = tonumber(type(wire.counts) == "table" and wire.counts.total_counts) or tonumber(paging.totals)
    if not total or total < 0 then return nil end
    local more = not paging.is_end
    local next_offset = type(paging.next) == "string" and paging.next:match("[?&]offset=([^&]+)")
    next_offset = next_offset and Text.urlDecode(next_offset)
    if more and (#wire.data == 0 or not next_offset or next_offset == ""
        or next_offset == (offset == 0 and "" or tostring(offset))) then return nil end
    local items = {}
    for _idx, row in ipairs(wire.data) do
        if type(row) ~= "table" or type(row.id) ~= "string" or type(row.content) ~= "string" then return nil end
        local images, inline_images = {}, {}
        local emoticons = require("source.zhihu.emoticons")
        local content = row.content:gsub("<img%s[^>]*>", function(tag)
            local _quote, alt = tag:match("alt%s*=%s*([\"'])(.-)%1")
            return alt and emoticons[Text.xmlDecode(alt)] and Text.xmlDecode(alt) or tag
        end)
        for _quote, src in content:gmatch("<img[^>]-src=([\"'])(.-)%1") do
            src = Text.xmlDecode(src)
            if src:match("^https?://") then
                images[#images + 1] = { url = src, headers = { Referer = "https://www.zhihu.com/" } }
            end
        end
        content = Text.stripHtml(content)
        for placeholder in content:gmatch("%b[]") do
            local url = emoticons[placeholder]
            if url then inline_images[placeholder] = { url = url, headers = { Referer = "https://www.zhihu.com/" } } end
        end
        items[#items + 1] = {
            id = row.id, author = clean(type(row.author) == "table" and row.author.name),
            content = content, likes = tonumber(row.like_count) or 0,
            inline_images = next(inline_images) and inline_images or nil,
            replies = tonumber(row.child_comment_count) or 0, time = tonumber(row.created_time) or 0,
            reply_to = type(row.reply_to_author) == "table" and clean(row.reply_to_author.name) or nil,
            images = images,
        }
    end
    return { items = items, total = total, max_idx = next_offset or offset, more = more }
end

return Mapper
