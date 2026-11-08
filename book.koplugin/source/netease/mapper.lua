--[[--
网易云阅读响应到书籍、目录和正文。

电脑端目录来自 getBook.do，分卷也保留为章节，避免改变已有章节序号。
正文的 x 字段指定 XOR / AES 解密顺序；没有 x 时为标准 Base64。

@module source.netease.mapper
--]]

local Text = require("utils.text")
local JSON = require("json")
local _ = require("l10n").get("source.netease")

---@class NeteaseChapter : BookChapter
---@field big_content_id string|nil
---@field leaf boolean|nil
local Mapper = {}

Mapper.TOC_VERSION = 2
local SOURCE_ID = "netease"

function Mapper.authorized(html)
    return type(html) == "string" and html:find("<title[^>]*>个人资料[^<]*</title>") ~= nil
        and html:find('id=["\']editNickName["\']') ~= nil
end

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

--- 分类取官网实际目录，不在客户端另存一份容易过时的分类编码。
function Mapper.categories(html)
    local categories = { male = {}, female = {}, publish = {} }
    local seen = {}
    for href, label in html:gmatch('<a[^>]-href=["\']([^"\']+)["\'][^>]*>(.-)</a>') do
        href = Text.xmlDecode(href)
        local id = href:match("[?&]id=(%d+)")
        local channel = href:match("/category/original%.do%?gender=(%a+)")
        if href:find("/category/publish.do?", 1, true) then channel = "publish" end
        if id and categories[channel] and not seen[channel .. ":" .. id] then
            seen[channel .. ":" .. id] = true
            local rows = categories[channel]
            rows[#rows + 1] = { id = id, title = Text.stripHtml(label) }
        end
    end
    for _channel, rows in pairs(categories) do
        if #rows == 0 then return nil, _("响应无效") end
    end
    return categories
end

function Mapper.catalog(wire)
    local data = type(wire) == "table" and wire.data
    if type(wire) ~= "table" or tonumber(wire.code) ~= 0 or type(data) ~= "table" or type(data.books) ~= "table"
        or type(data.pageQuery) ~= "table" or type(data.pageQuery.more) ~= "boolean" then
        return nil, _("响应无效")
    end
    local books = Mapper.books(data.books)
    if #books ~= #data.books then return nil, _("响应无效") end
    return books, nil, data.pageQuery.more
end

--- 官网书架是服务端 HTML；每行的分享数据携带结构化书籍身份，不能当搜索 JSON 解析。
---@param html string
---@param page integer
---@return Book[]|nil
---@return integer|nil next_page
---@return string|nil err
function Mapper.shelfPage(html, page)
    if not html:find("<title[^>]*>[^<]*我的书架") then
        return nil, nil, _("网易云阅读书架读取失败，请在官网确认登录")
    end
    local books, seen = {}, {}
    for row in html:gmatch('<div[^>]-class=["\']m%-bookshow["\'][^>]*>(.-)</li>') do
        if not row:find('data%-local=["\']true["\']') then
            local encoded = row:match('data%-contentinfo="([^"]*)"') or row:match("data%-contentinfo='([^']*)'")
            local ok, info = pcall(JSON.decode, Text.xmlDecode(encoded or ""))
            if not ok or type(info) ~= "table" then return nil, nil, _("响应无效") end
            local item = book({
                sourceUuid = info.sourceUuid, title = info.sourceTitle,
                iconUrl = info.imageUrl, description = info.imageDescription,
                author = Text.stripHtml(row:match("<p[^>]*>(.-)</p>") or ""),
            })
            if not item then return nil, nil, _("响应无效") end
            if not seen[item.stable_id] then
                seen[item.stable_id] = true
                books[#books + 1] = item
            end
        end
    end
    local next_page
    for encoded in html:gmatch('href=["\']([^"\']+)["\']') do
        local link = Text.xmlDecode(encoded)
        local target = tonumber(link:match("[?&]page=(%d+)"))
        if link:find("/shelf.do?", 1, true) and link:find("operation=query_current", 1, true)
            and target and target > page and (not next_page or target < next_page) then
            next_page = target
        end
    end
    return books, next_page
end

---@param wire table|nil
---@return Book|nil
function Mapper.detail(wire)
    if type(wire) ~= "table" or type(wire.portions) ~= "table" then return nil end
    return book({
        sourceUuid = wire.id, title = wire.title, author = wire.author,
        description = wire.shareDescription, coverImage = wire.coverImg,
    })
end

---@param wire table|nil
---@return NeteaseChapter[]|nil
function Mapper.chapters(wire)
    local rows = type(wire) == "table" and wire.portions or nil
    if type(rows) ~= "table" then return nil end
    local out = {}
    for _idx, row in ipairs(rows) do
        if type(row) == "table" and row.id ~= nil and tostring(row.id) ~= "" then
            out[#out + 1] = {
                idx = #out + 1,
                uid = tostring(row.id),
                title = clean(row.title),
                sec_id = tostring(row.id),
                big_content_id = row.bigContentId,
                leaf = row.leafNode,
                word_count = tonumber(row.charSize),
                vip = tonumber(row.needPay) == 1 and row.isPaid ~= true,
            }
        end
    end
    if out[1] then out[1].toc_version = Mapper.TOC_VERSION end
    return out
end

--- 电脑端以章节 UUID 定位；匿名响应带默认章节，但没有阅读时间。
---@param wire table|nil
---@return integer|nil
function Mapper.progressIndex(wire)
    if type(wire) ~= "table" or (tonumber(wire.curDate) or 0) <= 0 then return nil end
    for idx, row in ipairs(wire.portions or {}) do
        if row.id == wire.curArticleUuid then return idx end
    end
end

--- 电脑端章内百分比是 0..100，不是比例 0..1。
---@param stable_id string
---@param toc BookChapter[]|nil
---@param idx number|nil
---@param fraction number|nil
---@param now_ms number
---@return table|nil
function Mapper.readlog(stable_id, toc, idx, fraction, now_ms)
    if type(toc) ~= "table" or type(idx) ~= "number" then return nil end
    idx = math.floor(idx)
    local chapter = toc[idx]
    if type(chapter) ~= "table" or type(chapter.uid) ~= "string" or chapter.uid == "" then
        return nil
    end
    local page = tonumber(fraction) or 0
    if page < 0 then page = 0 end
    if page > 1 then page = 1 end
    return {
        sourceUuid = stable_id,
        articleUuid = chapter.uid,
        curPagePercent = page * 100,
        date = now_ms,
    }
end

--- 书评。网页模板用的字段：username、text、posttime、grade、likes、replied.username。
--- 第二返回值是总页数，没有分页信息就是 nil。
---@param wire table|nil
---@return { author: string, text: string, time: string|nil, grade: number|nil, likes: number|nil, reply_to: string|nil }[]|nil
---@return integer|nil
function Mapper.comments(wire)
    if type(wire) ~= "table" or tonumber(wire.resultCode) ~= 0 or type(wire.data) ~= "table" then
        return nil
    end
    local out = {}
    for _idx, row in ipairs(wire.data) do
        if type(row) == "table" and type(row.text) == "string" then
            local item = {
                author = type(row.username) == "string" and row.username or "",
                text = row.text,
                time = type(row.posttime) == "string" and row.posttime or nil,
                grade = tonumber(row.stars),
                likes = tonumber(row.likes),
            }
            if type(row.replied) == "table" and type(row.replied.username) == "string" then
                item.reply_to = row.replied.username
            end
            out[#out + 1] = item
        end
    end
    return out, tonumber(wire.totalPage)
end

--- XOR 作用于 JavaScript UTF-16 码元，而不是 UTF-8 字节。
local function xor(text, key)
    local bxor = require("bit").bxor
    local Glyph = require("utils.glyph")
    return (text:gsub(Text.UTF8_CHAR, function(ch)
        local cp = Glyph.codepoint(ch)
        if cp <= 0xFFFF then return Text.utf8char(bxor(cp, key)) end
        cp = cp - 0x10000
        local high = bxor(0xD800 + math.floor(cp / 0x400), key)
        local low = bxor(0xDC00 + cp % 0x400, key)
        return Text.utf8char(0x10000 + (high - 0xD800) * 0x400 + low - 0xDC00)
    end))
end

--- 正文解码失败必须报错，不得把密文写进章节缓存。
---@param wire table|nil
---@return string|nil
function Mapper.content(wire)
    local cipher = type(wire) == "table" and wire.content or nil
    if type(cipher) ~= "string" or cipher == "" then return nil, _("正文为空") end
    local html = Text.base64Decode(cipher)
    if type(wire.x) == "string" and wire.x ~= "" then
        local ok, steps = pcall(JSON.decode, Text.base64Decode(wire.x))
        if not ok or type(steps) ~= "table" or #steps < 1 or #steps > 2 then
            return nil, _("正文解析失败")
        end
        for _idx, step in ipairs(steps) do
            if type(step) ~= "table" then return nil, _("正文解析失败") end
            local decoded, value
            if step.m == 1 and tonumber(step.k) then
                decoded, value = pcall(xor, html, tonumber(step.k))
            elseif step.m == 2 and type(step.k) == "string" and html:match("^%x+$") and #html % 32 == 0 then
                local Aes = require("crypto.aes")
                decoded, value = pcall(Aes.ecb_decrypt, Aes.from_hex(html), step.k)
            end
            if not decoded then return nil, _("正文解析失败") end
            html = value
        end
    end
    if html == "" then return nil, _("正文为空") end
    return html
end

return Mapper
