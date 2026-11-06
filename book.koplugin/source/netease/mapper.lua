--[[--
网易云阅读响应到书籍、目录和正文。

正文是标准 Base64。阅读器里的换位表被注释掉了，当前就是恒等置换。
未购买章节接口直接返回 code -1，不给正文。

@module source.netease.mapper
--]]

local Text = require("utils.text")

local Mapper = {}

Mapper.TOC_VERSION = 1
local SOURCE_ID = "netease"

---@param value any
---@return string
local function clean(value)
    if type(value) ~= "string" then return "" end
    return Text.trim(value)
end

---@param value any
---@return string|nil
local function picture(value)
    if type(value) ~= "string" or value == "" then return nil end
    if value:sub(1, 2) == "//" then return "https:" .. value end
    return value
end

---@param row table
---@return string|nil
local function stableId(row)
    if row.sourceUuid ~= nil and tostring(row.sourceUuid) ~= "" then return tostring(row.sourceUuid) end
    if type(row.sourceUrl) == "string" then
        local id = row.sourceUrl:match("/source/([^/?#]+)")
        if id and id ~= "" then return id end
    end
    return nil
end

---@param row table
---@return Book|nil
local function book(row)
    local id = stableId(row)
    local title = clean(row.title or row.bookName)
    if not id or title == "" then return nil end
    return {
        source_id = SOURCE_ID,
        stable_id = id,
        title = title,
        authors = clean(row.author or row.authorName),
        intro = clean(row.description or row.intro),
        cover = picture(row.iconUrl or row.coverImage or row.cover),
    }
end

---@param rows table|nil
---@return Book[]
function Mapper.books(rows)
    local out = {}
    if type(rows) ~= "table" then return out end
    for _idx, row in ipairs(rows) do
        if type(row) == "table" then
            local item = book(row)
            if item then out[#out + 1] = item end
        end
    end
    return out
end

---@param wire table|nil
---@return Book[]|nil
---@return string|nil
function Mapper.searchBooks(wire)
    if type(wire) ~= "table" or tonumber(wire.code) ~= 0 or type(wire.data) ~= "table" then
        return nil, type(wire) == "table" and wire.error or nil
    end
    return Mapper.books(wire.data.books)
end

---@param wire table|nil
---@return Book|nil
function Mapper.detail(wire)
    local data = type(wire) == "table" and wire.data or nil
    local row = type(data) == "table" and data.book or nil
    if type(row) ~= "table" then return nil end
    return book(row)
end

---@param wire table|nil
---@return BookChapter[]|nil
function Mapper.chapters(wire)
    local data = type(wire) == "table" and wire.data or nil
    local rows = type(data) == "table" and data.catalog or nil
    if type(rows) ~= "table" then return nil end
    local out = {}
    for _idx, row in ipairs(rows) do
        if type(row) == "table" and row.uuid ~= nil and tostring(row.uuid) ~= "" then
            local paid = row.paid == true
            out[#out + 1] = {
                idx = #out + 1,
                uid = tostring(row.uuid),
                title = clean(row.title),
                sec_id = row.secId ~= nil and tostring(row.secId) or nil,
                word_count = tonumber(row.wordCount),
                vip = row.needPay == true and not paid,
            }
        end
    end
    if out[1] then out[1].toc_version = Mapper.TOC_VERSION end
    return out
end

--- 阅读位置。firstRead 表示云端还没有读过，articleIndex 从 1 起。
---@param wire table|nil
---@return integer|nil
function Mapper.progressIndex(wire)
    local data = type(wire) == "table" and wire.data or nil
    local config = type(data) == "table" and data.config or nil
    if type(config) ~= "table" or config.firstRead == true then return nil end
    local idx = tonumber(config.articleIndex)
    if not idx or idx < 1 then return nil end
    return math.floor(idx)
end

--- 阅读位置上报。page_precent 是网页接口里的拼写，offset 按章字数累加。
---@param stable_id string
---@param toc BookChapter[]|nil
---@param idx number|nil
---@param fraction number|nil
---@param csrf string|nil
---@param now_ms number
---@return table|nil
function Mapper.readlog(stable_id, toc, idx, fraction, csrf, now_ms)
    if type(toc) ~= "table" or type(idx) ~= "number" then return nil end
    if type(csrf) ~= "string" or csrf == "" then return nil end
    idx = math.floor(idx)
    local chapter = toc[idx]
    if type(chapter) ~= "table" or type(chapter.sec_id) ~= "string" or chapter.sec_id == "" then
        return nil
    end
    local page = tonumber(fraction) or 0
    if page < 0 then page = 0 end
    if page > 1 then page = 1 end
    local chars = 0
    for i = 1, idx - 1 do
        local row = toc[i]
        chars = chars + (type(row) == "table" and tonumber(row.word_count) or 0)
    end
    local current = tonumber(chapter.word_count) or 0
    return {
        source_uuid = stable_id,
        article_index = idx,
        secId = chapter.sec_id,
        page_precent = page,
        offset = chars + math.floor(current * page),
        csrf_token = csrf,
        curDate = now_ms,
    }
end

--- 书评。网页模板用的字段：username、text、posttime、grade、likes、replied.username。
--- 第二返回值是总页数，没有分页信息就是 nil。
---@param wire table|nil
---@return { author: string, text: string, time: string|nil, grade: number|nil, likes: number|nil, reply_to: string|nil }[]|nil
---@return integer|nil
function Mapper.comments(wire)
    if type(wire) ~= "table" or tonumber(wire.code) ~= 0 or type(wire.data) ~= "table" then
        return nil
    end
    local data = wire.data
    local rows = type(data.data) == "table" and data.data or data.list
    if type(rows) ~= "table" then return nil end
    local out = {}
    for _idx, row in ipairs(rows) do
        if type(row) == "table" and type(row.text) == "string" then
            local item = {
                author = type(row.username) == "string" and row.username or "",
                text = row.text,
                time = type(row.posttime) == "string" and row.posttime or nil,
                grade = tonumber(row.grade),
                likes = tonumber(row.likes),
            }
            if type(row.replied) == "table" and type(row.replied.username) == "string" then
                item.reply_to = row.replied.username
            end
            out[#out + 1] = item
        end
    end
    local query = type(data.pageQuery) == "table" and data.pageQuery or nil
    local pages = query and tonumber(query.pageCount) or nil
    return out, pages
end

--- 正文。标准 Base64，解出来是 HTML。
---@param wire table|nil
---@return string|nil
function Mapper.content(wire)
    local data = type(wire) == "table" and wire.data or nil
    local cipher = type(data) == "table" and data.content or nil
    if type(cipher) ~= "string" or cipher == "" then return nil end
    local html = Text.base64Decode(cipher)
    if html == "" then return nil end
    return html
end

return Mapper
