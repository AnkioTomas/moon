--[[--
掌阅网页响应 → 领域对象。纯函数，不发请求。

@module source.ireader.mapper
--]]

local Text = require("utils.text")

local Mapper = {}

local SOURCE_ID = "ireader"

-- 官网 FZYouH_509R_V1.10.ttf 的二十个私用字形；两个连续区间，中间 A–F 没有字形。
local CONTENT_CHARS = {}
for first, chars in pairs({
    [0xF0000] = "的一是了在有他我这们",
    [0xF0010] = "来去说就事你对也还但",
}) do
    for idx, ch in ipairs(Text.chars(chars)) do
        CONTENT_CHARS[Text.utf8char(first + idx - 1)] = ch
    end
end

--- 官网用补充私用区 A 代替常用字；还原为普通 Unicode，不要求用户安装官网字体。
---@param html string
---@return string|nil 未知私用字码不能当作有效正文缓存
function Mapper.content(html)
    local unknown = false
    local decoded = html:gsub("\243[\176-\191][\128-\191][\128-\191]", function(ch)
        local plain = CONTENT_CHARS[ch]
        if not plain then unknown = true end
        return plain
    end)
    return not unknown and decoded or nil
end

--- 只读取官网书评首屏。
---@class IReaderReviewPage
---@field items { author: string, text: string, time: string, grade: number|nil }[]

---@param html string
---@return IReaderReviewPage|nil
function Mapper.reviews(html)
    local list = html:match('<ul[^>]*class="sns_commentlist"[^>]*>(.-)</ul>')
    if not list then return nil end
    local items = {}
    for card in list:gmatch("<li[^>]*>(.-)</li>") do
        local author = card:match('<i[^>]*class="vm"[^>]*>(.-)</i>')
        local body = card:match('<p[^>]*class="con_dec"[^>]*>(.-)</p>')
        local time = card:match('<span[^>]*class="sns_time"[^>]*>(.-)</span>')
        if not author or not body or not time then return nil end
        items[#items + 1] = {
            author = Text.stripHtml(author),
            text = Text.stripHtml(body),
            time = Text.stripHtml(time),
            grade = tonumber(card:match('class="cur r(%d+)"')),
        }
    end
    if #items == 0 and Text.trim(list) ~= "" then return nil end
    return { items = items }
end

--- 目录缓存格式。首章携带，变了就当缓存失效。
Mapper.TOC_VERSION = 1

--- 扫码回包 body 是带引号的 JSON 字符串，网页用 replace 去掉引号。两种都认。
---@param body any
---@return string|nil
function Mapper.qrCode(body)
    if type(body) ~= "string" or body == "" then return nil end
    local ok, inner = pcall(require("json").decode, body)
    if ok and type(inner) == "string" and inner ~= "" then return inner end
    local stripped = body:gsub('"', "")
    if stripped == "" then return nil end
    return stripped
end

--- 轮询回包。等待是 30059（网页常量 WAIT_LOGIN），成功 body 里 name 是账号、session_id 是 zysid。
---@param wire table|nil
---@return table|nil user
---@return "wait"|"fail"|nil kind
function Mapper.login(wire)
    if type(wire) ~= "table" then return nil, "fail" end
    local code = tonumber(wire.code)
    if code == 30059 then return nil, "wait" end
    local body = wire.body
    if code == 0 and type(body) == "table" and type(body.name) == "string" and body.name ~= ""
        and type(body.session_id) == "string" and body.session_id ~= "" then
        local nick = type(body.nick) == "string" and body.nick ~= "" and body.nick or body.name
        return {
            usr = body.name,
            zysid = body.session_id,
            name = nick,
            avatar = type(body.avatar) == "string" and body.avatar or nil,
        }
    end
    return nil, "fail"
end

---@param id string|number
---@param title string|nil
---@param author string|nil
---@param intro string|nil
---@param cover string|nil
---@return Book
local function book(id, title, author, intro, cover)
    local function clean(value)
        if type(value) ~= "string" then return "" end
        return Text.trim(Text.xmlDecode(value))
    end
    local picture = type(cover) == "string" and cover ~= "" and Text.xmlDecode(cover) or nil
    return {
        source_id = SOURCE_ID,
        stable_id = tostring(id),
        title = clean(title),
        authors = clean(author),
        intro = clean(intro),
        cover = picture,
    }
end

--- 书架行。文件夹和本机上传的书网页读不了，不进月读书架。
---@param wire table|nil
---@return Book[]
function Mapper.shelf(wire)
    local out = {}
    local rows = type(wire) == "table" and wire.data or nil
    if type(rows) ~= "table" then return out end
    for _idx, row in ipairs(rows) do
        if type(row) == "table" and row.book_id and row.dtype ~= 1 and row.is_local_book ~= true then
            local item = book(row.book_id, row.book_name, row.author, nil, row.icon or row.cover)
            if item.title ~= "" then out[#out + 1] = item end
        end
    end
    return out
end

--- 搜索结果页。卡片是 data-id + data-src + name / author / brief。
---@param html string|nil
---@return Book[]
function Mapper.search(html)
    local out, seen = {}, {}
    if type(html) ~= "string" then return out end
    local pos = 1
    while true do
        local _start, stop, id = html:find('data%-id="(%d+)"', pos)
        if not _start then break end
        if not seen[id] then
            seen[id] = true
            local window = html:sub(stop, math.min(#html, stop + 1500))
            local cover = window:match('data%-src="([^"]+)"')
            local title = window:match('class="name[^"]*"[^>]*>([^<]*)')
            local author = window:match('class="author[^"]*"[^>]*>([^<]*)')
            local intro = window:match('class="brief"[^>]*>([^<]*)')
            if title and Text.trim(title) ~= "" then
                out[#out + 1] = book(id, title, author, intro, cover)
            end
        end
        pos = stop
    end
    return out
end

--- 频道页 data-point 里的 cli_res_id / cli_res_name。同一本书滑块里会重复，只留第一次。
---@param html string|nil
---@return Book[]
function Mapper.channel(html)
    local out, seen = {}, {}
    if type(html) ~= "string" then return out end
    local pattern = '"cli_res_id"%s*:%s*(%d+)%s*,%s*"cli_res_name"%s*:%s*"([^"]*)"'
    local pos = 1
    while true do
        local _start, stop, id, title = html:find(pattern, pos)
        if not _start then break end
        if not seen[id] then
            seen[id] = true
            local cover = html:sub(stop, math.min(#html, stop + 500)):match('src="(https://[^"]+)"')
            out[#out + 1] = book(id, title, nil, nil, cover)
        end

        pos = stop
    end
    return out
end

---@param html string
---@return Book[]
function Mapper.catalog(html)
    local out, seen = {}, {}
    for id, card in html:gmatch('<li[^>]-data%-type="book"[^>]-data%-id="(%d+)"[^>]*>(.-)</li>') do
        local title = card:match("<dt[^>]*>(.-)</dt>")
        if title and not seen[id] then
            seen[id] = true
            out[#out + 1] = book(id, title, card:match('class="author[^"]*"[^>]*>([^<]*)'),
                card:match('class="content[^"]*"[^>]*>([^<]*)'), card:match('data%-src="([^"]+)"'))
        end
    end
    return out
end

---@param html string
---@return table|nil
function Mapper.categories(html)
    local parent, category = html:match("var parentId%s*=%s*'(%d+)'%s*,%s*categoryId%s*=%s*'(%d+)'")
    if not parent then return nil end
    local result = { parent = parent, category = category, channels = {}, categories = {}, orders = {}, statuses = {} }
    local seen = {}
    for p, id, title in html:gmatch('<a[^>]-href="[^"]-/category/(%d+)/(%d+)[^"]*"[^>]*>([^<]+)</a>') do
        local key = p .. ":" .. id
        if not seen[key] then
            seen[key] = true
            if p == id then
                result.channels[#result.channels + 1] = { id = p, title = Text.xmlDecode(title) }
            elseif p == parent then
                result.categories[#result.categories + 1] = { id = id, title = Text.xmlDecode(title) }
            end
        end
    end
    for field, list in pairs({ order = result.orders, status = result.statuses }) do
        for id, title in html:gmatch('<span[^>]-data%-' .. field .. '="([%w]+)"[^>]*>([^<]+)</span>') do
            list[#list + 1] = { id = id, title = Text.xmlDecode(title) }
        end
    end
    if #result.channels == 0 or #result.categories == 0 or #result.orders == 0 or #result.statuses == 0 then return nil end
    return result
end

---@param body table|nil
---@param stable_id string
---@return Book|nil
function Mapper.detail(body, stable_id)
    if type(body) ~= "table" then return nil end
    local id = body.book_id or body.id or stable_id
    if not id then return nil end
    return book(id, body.name or body.book_name, body.author, body.description or body.brief, body.icon or body.cover or body.pic)
end

--- 章节目录。网页列表项是 id + name，本地书才有 children。
---@param rows table[]|nil
---@return BookChapter[]
function Mapper.chapters(rows)
    local out = {}
    local function walk(list, depth)
        for _idx, row in ipairs(type(list) == "table" and list or {}) do
            local id = row.id or row.chapter_id
            if id ~= nil then
                out[#out + 1] = {
                    uid = tostring(id),
                    title = Text.trim(tostring(row.name or row.title or "")),
                    depth = depth,
                }
            end
            if type(row.children) == "table" then walk(row.children, depth + 1) end
        end
    end
    walk(rows, 1)
    for idx, chapter in ipairs(out) do chapter.idx = idx end
    if out[1] then out[1].toc_version = Mapper.TOC_VERSION end
    return out
end

--- 进度接口把章节 id 存成「列表 id - 1」，读回来要加回去才能对上目录 uid。
---@param chapter_id number|string|nil
---@return string|nil
function Mapper.progressUid(chapter_id)
    local stored = tonumber(chapter_id)
    if not stored then return nil end
    return tostring(stored + 1)
end

return Mapper
