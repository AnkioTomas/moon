--[[--
京东读书 wire → 领域对象。

@module koplugin.book.source.jdread.mapper
--]]

local Progress = require("book.progress")
local Text = require("utils.text")

local Mapper = {}
local SOURCE_ID = "jdread"

--- 京东图片地址带 .dpg 后缀（图床转 webp），去掉取原图。
---@param value any
---@return string|nil
local function imageUrl(value)
    return type(value) == "string" and (value:gsub("%.dpg$", "")) or nil
end

--- ebook/lite、ebooks/lite 的一行 → Book。
--- 实际字段只有 ebook_id/name/author/image_url/cate_third_names（详情另有 word_count）；没有简介与进度。
---@param row table
---@return Book
function Mapper.book(row)
    return {
        source_id = SOURCE_ID,
        stable_id = tostring(row.ebook_id),
        title = row.name,
        authors = row.author,
        category = type(row.cate_third_names) == "table" and table.concat(row.cate_third_names, ", ") or nil,
        cover = imageUrl(row.image_url),
        meta = { words = row.word_count },
    }
end

--- 京东书架 ebooks/lite 行数组 → Book[]。
---@param rows table[]
---@return Book[]
function Mapper.shelfList(rows)
    local books = {}
    for _idx, row in ipairs(rows) do books[#books + 1] = Mapper.book(row) end
    return books
end

--- EPUB 目录 /jdread/api/ebook/catalog/v2/{id} → BookChapter[]，与网页阅读器同一成章规则：
--- 一个文件一章（chapter_uri 去掉 #锚点，试读版 x.html 与完整版 x-CD.html 算同一文件），
--- 带锚点的小节并入所在文件，同文件不带锚点的行丢弃。小节各自下载会拿到整份文件，正文重复。
--- 下载只认 0-based indexes：组内首个已购完整版，没有再取首个试读版，都没有取组首行；uid 就是它。
--- 封面页正文是空 body，首章挂上封面图供补页。
---@param rows table
---@param cover string|nil
---@return BookChapter[]|nil
local function downloadChapters(rows, cover)
    local chapters, by_file, full, try = {}, {}, {}, {}
    for pos, row in ipairs(rows) do
        local index = tonumber(row.chapter_index) or pos - 1
        local file = row.chapter_uri and (row.chapter_uri:gsub("#.*$", ""):gsub("%-CD%.", "."))
            or row.chapter_item or tostring(index)
        local title = row.chapter_name ~= nil and tostring(row.chapter_name) or ""
        local chapter = by_file[file]
        if not chapter then
            chapter = {
                idx = #chapters + 1,
                source_idx = tostring(index),
                title = title ~= "" and title or ("第" .. (index + 1) .. "章"),
                depth = 1,
            }
            by_file[file] = chapter
            chapters[#chapters + 1] = chapter
        elseif row.anchor then
            chapter.anchors = chapter.anchors or {}
            chapter.anchors[#chapter.anchors + 1] = { title = title, depth = 2, id = tostring(row.anchor) }
        else
            chapter = nil
        end
        if chapter then
            local idx = chapter.idx
            if not row.is_try and row.is_buy then
                full[idx] = full[idx] or index
            elseif row.is_try then
                try[idx] = try[idx] or index
            end
        end
    end
    if #chapters == 0 then return nil end
    for idx, chapter in ipairs(chapters) do
        chapter.uid = tostring(full[idx] or try[idx] or chapter.source_idx)
    end
    chapters[1].toc_version = 5
    chapters[1].cover = cover
    return chapters
end

--- txt 网文目录：type 0 是卷标题（无 chapter_id，不计入 total_count），type 1 是正文章。
--- 下载按 { type = 1, ids = chapter_id }，故 uid 就是 chapter_id。
---@param rows table
---@return BookChapter[]|nil
local function netChapters(rows)
    local chapters = {}
    for _idx, row in ipairs(rows) do
        if tonumber(row.type) == 1 and row.chapter_id ~= nil and tostring(row.chapter_id) ~= "" then
            local title = row.chapter_name
            if title == nil or tostring(title) == "" then
                title = "第" .. (#chapters + 1) .. "章"
            end
            chapters[#chapters + 1] = {
                idx = #chapters + 1,
                uid = tostring(row.chapter_id),
                title = tostring(title),
                depth = 1,
            }
        end
    end
    if #chapters == 0 then return nil end
    chapters[1].toc_version = 3
    return chapters
end

--- 目录 wire → BookChapter[]。
---@param wire table
---@return BookChapter[]|nil
function Mapper.chapters(wire)
    local root = type(wire.data) == "table" and wire.data or wire
    if type(root.chapter_info) ~= "table" then return nil end
    if root.format == "txt" then return netChapters(root.chapter_info) end
    return downloadChapters(root.chapter_info, imageUrl(root.image_url))
end

---@param content string
---@return string
local function netBody(content)
    return Text.textToBody(Text.stripLineIndent(content))
end

--- download/chapter 正文 wire → 标准章节内容。
--- txt 网文正文 content_type = "net"，是 \r\n 分段的纯文本，
--- 行首全角缩进时有时无，统一剥掉交给章节模板的 text-indent。
--- 网页版封面页去掉了图只剩空 body，传入 cover 时用封面图补成一页，否则落盘会报章节内容为空。
---@param wire table
---@param title string|nil
---@param cover string|nil
---@return ChapterContentPayload|nil
function Mapper.content(wire, title, cover)
    local data = type(wire.data) == "table" and wire.data or wire
    local parts = data.chapter
    if type(parts) ~= "table" then return nil end
    local toBody = data.content_type == "net" and netBody or Text.htmlBodyFragment
    local html = {}
    for _idx, part in ipairs(parts) do
        if type(part) == "table" and part.can_read == false then
            return nil
        end
        local content = type(part) == "table" and part.content or part
        if type(content) == "string" and content ~= "" then
            html[#html + 1] = toBody(content)
        end
    end
    if #html == 0 then return nil end
    local body = table.concat(html, "\n")
    if cover and not body:find("%S") then
        body = '<p><img src="' .. Text.xmlEscape(cover) .. '"/></p>'
    end
    return { title = title, html = body }
end

--- marker/sync wire → ProgressPosition 与章节 uid。
---@param wire table
---@return ProgressPosition|nil, string|nil
function Mapper.progress(wire)
    local groups = wire.data
    local markers = type(groups) == "table" and groups[1] and groups[1].list
    if type(markers) ~= "table" then return nil end
    local current
    for _idx, marker in ipairs(markers) do
        if type(marker) == "table" and tonumber(marker.data_type) == 0
            and (not current or (tonumber(marker.version) or 0) > (tonumber(current.version) or 0)) then
            current = marker
        end
    end
    if not current then return nil end
    return {
        fraction = Progress.clampFraction(current.percent),
        chapter_title = current.epub_chapter_title,
        updated_at = tonumber(current.version or current.created_at),
    }, current.chapter_id and tostring(current.chapter_id) or nil
end

return Mapper
