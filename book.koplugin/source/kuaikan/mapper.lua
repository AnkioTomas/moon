--[[--
快看漫画响应到书籍、目录和页图。

目录不在 JSON 里。话题页把章节嵌进 `window.__NUXT__`，由 page.lua 拆开后再交给这里。
未解锁章节 `locked == true`，不给页图。

@module source.kuaikan.mapper
--]]

local Text = require("utils.text")

local Mapper = {}

Mapper.TOC_VERSION = 1
local SOURCE_ID = "kuaikan"

---@param value any
---@return string
local function clean(value)
    if type(value) ~= "string" then return "" end
    return Text.trim(value)
end

---@param row table
---@return string
local function author(row)
    local user = row.user
    if type(user) == "table" then return clean(user.nickname) end
    return ""
end

---@param row table
---@return string|nil
local function cover(row)
    local url = row.vertical_image_url or row.cover_image_url
    if type(url) ~= "string" or url == "" then return nil end
    return url
end

---@param row table
---@return Book|nil
local function book(row)
    if type(row) ~= "table" or row.id == nil or clean(row.title) == "" then return nil end
    return {
        source_id = SOURCE_ID,
        stable_id = tostring(row.id),
        title = clean(row.title),
        authors = author(row),
        cover = cover(row),
        intro = clean(row.description),
    }
end

---@param rows table|nil
---@return Book[]
local function books(rows)
    local out = {}
    if type(rows) ~= "table" then return out end
    for _idx, row in ipairs(rows) do
        local item = book(row)
        if item then out[#out + 1] = item end
    end
    return out
end

---@param wire table|nil
---@return Book[]|nil
function Mapper.search(wire)
    if type(wire) ~= "table" or tonumber(wire.code) ~= 200 then return nil end
    local topics = type(wire.data) == "table" and wire.data.topics or nil
    local hit = type(topics) == "table" and topics.hit or nil
    if type(hit) ~= "table" then return nil end
    return books(hit)
end

---@param wire table|nil
---@return Book[]|nil
function Mapper.home(wire)
    if type(wire) ~= "table" or tonumber(wire.code) ~= 200 then return nil end
    local rows = type(wire.data) == "table" and wire.data.popularity_topics or nil
    if type(rows) ~= "table" then return nil end
    return books(rows)
end

--- 收藏列表。`data.topics` 是书卡数组，空数组是空收藏。
---@param wire table|nil
---@return Book[]|nil
function Mapper.fav(wire)
    if type(wire) ~= "table" or tonumber(wire.code) ~= 200 then return nil end
    local data = type(wire.data) == "table" and wire.data or nil
    local rows = data and data.topics or nil
    if type(rows) ~= "table" then return nil end
    return books(rows)
end

--- 话题页拆出来的章节行。
---@param rows table[]|nil
---@return BookChapter[]|nil
function Mapper.chapters(rows)
    if type(rows) ~= "table" then return nil end
    local out = {}
    for _idx, row in ipairs(rows) do
        if type(row) == "table" and row.id ~= nil and clean(row.title) ~= "" then
            out[#out + 1] = {
                idx = #out + 1,
                uid = tostring(row.id),
                title = clean(row.title),
                vip = row.locked == true,
            }
        end
    end
    if not out[1] then return nil end
    out[1].toc_version = Mapper.TOC_VERSION
    return out
end

--- 详情。作者是页面脚本里单独赋的昵称。
---@param info table|nil
---@param nickname string|nil
---@return Book|nil
function Mapper.detail(info, nickname)
    local item = book(info or {})
    if item and type(nickname) == "string" and nickname ~= "" then item.authors = nickname end
    return item
end

--- 话题评论。网页只展示 `replied_comment_id` 为 0 的楼，字段是 user.nickname、content、created_at_info、likes_count。
--- 第二返回值是 data.total。
---@param wire table|nil
---@return { author: string, text: string, time: string|nil, likes: number|nil }[]|nil
---@return integer|nil
function Mapper.comments(wire)
    if type(wire) ~= "table" or tonumber(wire.code) ~= 200 or type(wire.data) ~= "table" then
        return nil
    end
    local rows = wire.data.comments
    if type(rows) ~= "table" then return nil end
    local out = {}
    for _idx, row in ipairs(rows) do
        if type(row) == "table" and tonumber(row.replied_comment_id) == 0 and type(row.content) == "string" then
            local user = type(row.user) == "table" and row.user or {}
            local stamp = type(row.created_at_info) == "string" and row.created_at_info:match("^(%S+)") or nil
            out[#out + 1] = {
                author = type(user.nickname) == "string" and user.nickname or "",
                text = row.content,
                time = stamp,
                likes = tonumber(row.likes_count),
            }
        end
    end
    return out, tonumber(wire.data.total)
end

--- 一话的页图 URL。locked 的章节没有图。
---@param wire table|nil
---@return string[]|nil
---@return string|nil
function Mapper.images(wire)
    if type(wire) ~= "table" or tonumber(wire.code) ~= 200 then return nil end
    local info = type(wire.data) == "table" and wire.data.comic_info or nil
    if type(info) ~= "table" then return nil end
    if info.locked == true then return nil, "locked" end
    local rows = info.comic_images
    if type(rows) ~= "table" then return nil end
    local urls = {}
    for _idx, row in ipairs(rows) do
        local url = type(row) == "table" and row.url or nil
        if type(url) == "string" and url ~= "" then urls[#urls + 1] = url end
    end
    if #urls == 0 then return nil end
    return urls
end

return Mapper
