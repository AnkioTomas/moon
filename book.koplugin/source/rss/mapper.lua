--[[--
RSS feed/item → Book / BookChapter / ChapterContentPayload。

@module koplugin.book.source.rss.mapper
--]]

local BookRef = require("types.book").BookRef
local BookListResult = require("types.book_list")
local Parser = require("source.rss.parser")

local Mapper = {}
local SOURCE_ID = "rss"

local function displayTitle(feed)
    if type(feed.title) == "string" and feed.title ~= "" then
        return feed.title
    end
    return feed.url
end

--- 配置订阅 → Book。
---@param feed table
---@param parsed table|nil
---@return Book|nil
function Mapper.book(feed, parsed)
    local url = Parser.normalizeUrl(feed and feed.url)
    if not url then return nil end
    local title = displayTitle(feed)
    if (not feed.title or feed.title == "") and parsed and parsed.title then
        title = parsed.title
    end
    return {
        ref = BookRef.new(SOURCE_ID, url),
        title = title,
        authors = parsed and parsed.title or nil,
        intro = parsed and parsed.intro or nil,
        category = "RSS",
        percent = 0,
    }
end

---@param feeds table[]|nil
---@param parsed_by_url table<string, table>|nil
---@return BookListResult
function Mapper.library(feeds, parsed_by_url)
    local books = {}
    local seen = {}
    for _, feed in ipairs(feeds or {}) do
        local url = Parser.normalizeUrl(feed.url)
        if url and not seen[url] then
            seen[url] = true
            local book = Mapper.book(feed, parsed_by_url and parsed_by_url[url])
            if book then books[#books + 1] = book end
        end
    end
    return BookListResult.new(books)
end

---@param ref BookRef
---@param feed table|nil
---@param parsed table
---@return BookDetail
function Mapper.detail(ref, feed, parsed)
    local book = Mapper.book(feed or { url = ref.stable_id }, parsed)
    book.ref = ref
    return book
end

--- 解析结果 → 连续 1-based TOC（源顺序即新文在前）。
---@param parsed table
---@return BookChapter[]
function Mapper.chapters(parsed)
    local chapters = {}
    for i, item in ipairs(parsed and parsed.items or {}) do
        chapters[#chapters + 1] = {
            idx = i,
            source_idx = item.link,
            uid = item.uid ~= "" and item.uid or item.link,
            title = item.title ~= "" and item.title or tostring(i),
        }
    end
    return chapters
end

--- 按 uid（回退 idx）取正文。
---@param parsed table
---@param chapter BookChapter
---@return ChapterContentPayload|nil, string|nil
function Mapper.chapterContent(parsed, chapter)
    local items = parsed and parsed.items or {}
    local target_uid = tostring(chapter and chapter.uid or "")
    local item
    if target_uid ~= "" then
        for _, row in ipairs(items) do
            if tostring(row.uid or row.link or "") == target_uid then
                item = row
                break
            end
        end
    end
    item = item or items[tonumber(chapter and chapter.idx)]
    if not item then return nil, "article not found" end
    if type(item.content) ~= "string" or item.content == "" then
        return {
            title = item.title,
            text = item.link ~= "" and item.link or item.title,
        }
    end
    return {
        title = item.title,
        html = item.content,
    }
end

return Mapper
