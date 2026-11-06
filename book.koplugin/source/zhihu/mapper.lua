--[[--
知乎盐选响应到书籍和单节目录。

搜索页打开 `search?type=km_general`，接口是 `/api/v4/search_v3`。
一节就是一篇，`stable_id` 是专栏 id 加节 id。`is_fold ~= false` 的节未购买。

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
    return url:match("/paid_column/(%d+)/section/(%d+)")
end

---@param value any
---@return string
local function authors(value)
    if type(value) == "string" then return clean(value) end
    if type(value) ~= "table" then return "" end
    local first = value[1] or value
    if type(first) == "string" then return clean(first) end
    if type(first) == "table" then return clean(first.name) end
    return ""
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
        stable_id = well .. "/" .. section,
        title = title,
        authors = authors(row.producer_name or body.authors or row.authors),
        cover = cover(row.artwork or row.tab_artwork or body.images),
        intro = clean(row.description or body.description),
    }
end

---@param node any
---@param out Book[]
---@param seen table<string, boolean>
local function collect(node, out, seen)
    if type(node) ~= "table" then return end
    local item = type(node.url) == "string" and type(node.title) == "string" and book(node) or nil
    if item then
        if not seen[item.stable_id] then
            seen[item.stable_id] = true
            out[#out + 1] = item
        end
        return
    end
    for _key, value in pairs(node) do
        if type(value) == "table" then collect(value, out, seen) end
    end
end

---@param wire table|nil
---@return Book[]|nil
function Mapper.feed(wire)
    if type(wire) ~= "table" or type(wire.data) ~= "table" or wire.error then return nil end
    local out, seen = {}, {}
    collect(wire.data, out, seen)
    return out
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

--- 一篇盐选只有这一节。
---@param wire table|nil
---@param stable_id string
---@return BookChapter[]|nil
function Mapper.chapters(wire, stable_id)
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
---@return Book|nil
function Mapper.detail(wire, stable_id)
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

return Mapper
