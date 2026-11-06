--[[--
知音漫客响应到书籍、目录和页图。

搜索走 `/apinew/getsortlist/`。章节列表是看漫画的 `getchapterlist`，
`order_num` 小的在前。`price > 0` 且没有页图的话是未购买。

@module source.zymk.mapper
--]]

local Text = require("utils.text")

local Mapper = {}

Mapper.TOC_VERSION = 1
local SOURCE_ID = "zymk"
local COVER = "https://chapter-cover.yyhao.com/file/cover/%s.jpg-300x400"

---@param value any
---@return string
local function clean(value)
    if type(value) ~= "string" then return "" end
    return Text.trim(value)
end

--- 封面路径把漫画 id 补成 9 位再按 3 位切开。4982 → `000/004/982`。
---@param comic_id string|number
---@return string|nil
function Mapper.cover(comic_id)
    local number = tonumber(comic_id)
    if not number or number < 0 then return nil end
    local digits = string.format("%09d", number)
    local path = digits:sub(1, 3) .. "/" .. digits:sub(4, 6) .. "/" .. digits:sub(7, 9)
    return COVER:format(path)
end

---@param wire table|nil
---@return Book[]|nil
function Mapper.list(wire)
    if type(wire) ~= "table" or tonumber(wire.status) ~= 0 then return nil end
    local page = type(wire.data) == "table" and wire.data.page or nil
    local rows = type(page) == "table" and page.comic_list or nil
    if type(rows) ~= "table" then return nil end
    local out = {}
    for _idx, row in ipairs(rows) do
        if type(row) == "table" and row.comic_id ~= nil and clean(row.comic_name) ~= "" then
            out[#out + 1] = {
                source_id = SOURCE_ID,
                stable_id = tostring(row.comic_id),
                title = clean(row.comic_name),
                authors = "",
                cover = Mapper.cover(row.comic_id),
                intro = clean(row.comic_feature),
            }
        end
    end
    return out
end

---@param page table|nil
---@param stable_id string|number
---@return Book|nil
function Mapper.detail(page, stable_id)
    if type(page) ~= "table" or clean(page.title) == "" or stable_id == nil then return nil end
    local cover = clean(page.cover)
    return {
        source_id = SOURCE_ID,
        stable_id = tostring(stable_id),
        title = clean(page.title),
        authors = clean(page.authors),
        cover = cover ~= "" and cover or Mapper.cover(stable_id),
        intro = clean(page.description),
    }
end

--- 看漫画章节。uid 带上漫画 id，页图接口两个都要。
---@param comic_id string|number
---@param rows table|nil
---@return BookChapter[]|nil
function Mapper.chapters(comic_id, rows)
    if comic_id == nil or type(rows) ~= "table" then return nil end
    local copy = {}
    for index, row in ipairs(rows) do copy[index] = row end
    table.sort(copy, function(left, right)
        local left_order = type(left) == "table" and tonumber(left.order_num) or 0
        local right_order = type(right) == "table" and tonumber(right.order_num) or 0
        return left_order < right_order
    end)
    local prefix = tostring(comic_id) .. "/"
    local out = {}
    for _idx, row in ipairs(copy) do
        local newid = type(row) == "table" and row.chapter_newid or nil
        local title = type(row) == "table" and clean(row.chapter_name) or ""
        if type(newid) == "string" and newid ~= "" and title ~= "" then
            out[#out + 1] = {
                idx = #out + 1,
                uid = prefix .. newid,
                title = title,
                vip = (tonumber(row.price) or 0) > 0,
            }
        end
    end
    if not out[1] then return nil end
    out[1].toc_version = Mapper.TOC_VERSION
    return out
end

--- 一话的页图。没有图且标了价格或会员，就是未购买。
---@param wire table|nil
---@return string[]|nil
---@return string|nil
function Mapper.images(wire)
    if type(wire) ~= "table" or tonumber(wire.status) ~= 0 then return nil end
    local chapter = type(wire.data) == "table" and wire.data.current_chapter or nil
    if type(chapter) ~= "table" then return nil end
    local urls = {}
    if type(chapter.chapter_img_list) == "table" then
        for _idx, url in ipairs(chapter.chapter_img_list) do
            if type(url) == "string" and url ~= "" then urls[#urls + 1] = url end
        end
    end
    if #urls == 0 then
        if (tonumber(chapter.price) or 0) > 0 or tonumber(chapter.is_vip) == 1 then
            return nil, "locked"
        end
        return nil
    end
    return urls
end

return Mapper
