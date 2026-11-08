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

---@class ZymkAccount
---@field openid string
---@field type string

--- 官网用 type + openid 访问账号；device 是匿名身份，不能算登录。
---@param data any
---@return ZymkAccount|nil
function Mapper.account(data)
    if type(data) ~= "table" or type(data.openid) ~= "string" or data.openid == ""
        or type(data.type) ~= "string" or data.type == "" or data.type == "device" then return nil end
    return { openid = data.openid, type = data.type }
end

---@class ZymkCaptcha
---@field image string
---@field width number
---@field height number
---@field content string

---@param data any
---@return ZymkCaptcha|nil
function Mapper.captcha(data)
    if type(data) ~= "table" or type(data.Image) ~= "string" or data.Image == ""
        or type(data.Content) ~= "string" or data.Content == "" then return nil end
    local width, height = tonumber(data.Width), tonumber(data.Height)
    if not width or width <= 0 or not height or height <= 0 then return nil end
    return { image = data.Image, width = width, height = height, content = data.Content }
end


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
        if type(row) ~= "table" or row.comic_id == nil or clean(row.comic_name) == "" then return nil end
        out[#out + 1] = {
            source_id = SOURCE_ID,
            stable_id = tostring(row.comic_id),
            title = clean(row.comic_name),
            authors = "",
            cover = Mapper.cover(row.comic_id),
            intro = clean(row.comic_feature),
        }
    end
    return out
end

--- 官网空收藏可能省略 ubook；非空的坏行不能变成空书架。
---@param data any
---@return Book[]|nil
function Mapper.shelf(data)
    if type(data) ~= "table" then return nil end
    local rows = data.ubook
    if rows == nil then
        if next(data) == nil or type(data.urecord) == "table" then return {} end
        return nil
    end
    if type(rows) ~= "table" then return nil end
    local count = 0
    for index, row in pairs(rows) do
        count = count + 1
        if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #rows
            or type(row) ~= "table" or not tostring(row.comic_id):match("^%d+$")
            or clean(row.comic_name) == "" then return nil end
    end
    if count ~= #rows then return nil end
    local books = {}
    for _index, row in ipairs(rows) do
        local added = tonumber(row.addtime)
        books[#books + 1] = {
            source_id = SOURCE_ID, stable_id = tostring(row.comic_id),
            title = clean(row.comic_name), cover = Mapper.cover(row.comic_id),
            inserted_at = added and math.floor(added / 1000) or nil,
        }
    end
    return books
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
    for index, row in ipairs(rows) do
        if type(row) ~= "table" or not tonumber(row.order_num)
            or type(row.chapter_newid) ~= "string" or row.chapter_newid == ""
            or clean(row.chapter_name) == "" then return nil end
        copy[index] = row
    end
    table.sort(copy, function(left, right)
        return tonumber(left.order_num) < tonumber(right.order_num)
    end)
    local prefix = tostring(comic_id) .. "/"
    local out = {}
    for _idx, row in ipairs(copy) do
        out[#out + 1] = {
            idx = #out + 1,
            uid = prefix .. row.chapter_newid,
            title = clean(row.chapter_name),
            vip = (tonumber(row.price) or 0) > 0,
        }
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
            if type(url) ~= "string" or not url:match("^https?://") then return nil end
            urls[#urls + 1] = url
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

---@param stable_id string
---@param page integer
---@param wire table
---@return table|nil
function Mapper.reviews(stable_id, page, wire)
    if type(wire) ~= "table" or tonumber(wire.status) ~= 1 or type(wire.data) ~= "table" then return nil end
    local items = {}
    for _idx, row in ipairs(wire.data) do
        if type(row) ~= "table" or row.id == nil or tostring(row.ssid) ~= stable_id or tonumber(row.ssidtype) ~= 0
            or type(row.content) ~= "string" or type(row.uname) ~= "string" then return nil end
        local timestamp = tonumber(row.createtime) or 0
        if timestamp >= 1e12 then timestamp = timestamp / 1000 end
        items[#items + 1] = {
            id = tostring(row.id),
            author = row.uname,
            text = Text.stripHtml(row.content),
            time = timestamp > 0 and os.date("%Y-%m-%d", timestamp) or "",
        }
    end
    -- 列表没有总数；满页只表明可能还有下一页，不能伪造精确页数。
    return { items = items, more = #wire.data == 20, pages = #wire.data == 20 and page + 1 or page }
end

return Mapper
