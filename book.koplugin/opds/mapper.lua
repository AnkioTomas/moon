--[[--
OPDS wire（1.x Atom / 2.0 JSON）→ 书城展示对象。

Atom 只取目录浏览需要的字段（entry / link / title / author / summary / category），
不是通用 XML 解析器；2.0 读 navigation / publications / groups。
导航条目映射为 { title, feed }，点开即下钻；
书籍条目映射为 Book，download/format 取本地书库能打开的最优格式。

@module koplugin.book.opds.mapper
--]]

local JSON = require("json")
local Text = require("utils.text")
local _ = require("gettext")

local Mapper = {}

-- MIME → 扩展名。只收本地书库能扫到的格式（source/local/client BOOK_EXT）；kepub 就是 EPUB。
local MIME_EXT = {
    ["application/epub+zip"] = "epub",
    ["application/kepub+zip"] = "epub",
    ["application/x-mobi8-ebook"] = "azw3",
    ["application/x-mobipocket-ebook"] = "mobi",
    ["application/vnd.amazon.ebook"] = "azw",
    ["application/x-fictionbook+xml"] = "fb2",
    ["text/fb2+xml"] = "fb2",
    ["application/pdf"] = "pdf",
    ["image/vnd.djvu"] = "djvu",
    ["image/x-djvu"] = "djvu",
    ["application/vnd.comicbook+zip"] = "cbz",
    ["application/x-cbz"] = "cbz",
    ["application/x-cbt"] = "cbt",
    ["application/vnd.openxmlformats-officedocument.wordprocessingml.document"] = "docx",
    ["application/rtf"] = "rtf",
    ["text/rtf"] = "rtf",
    ["text/plain"] = "txt",
}

-- 同一本书给多种格式时的优先级（小者优先）；也是按 href 后缀兜底时的白名单。
local EXT_RANK = {
    epub = 1, azw3 = 2, mobi = 3, azw = 4, fb2 = 5, pdf = 6, djvu = 7,
    cbz = 8, cbt = 9, docx = 10, rtf = 11, txt = 12,
}

local ACQUISITION = {
    ["http://opds-spec.org/acquisition"] = true,
    ["http://opds-spec.org/acquisition/open-access"] = true,
}

local COVER_RELS = {
    ["http://opds-spec.org/image/thumbnail"] = 1,
    ["http://opds-spec.org/thumbnail"] = 1,
    ["x-stanza-cover-image-thumbnail"] = 1,
    ["http://opds-spec.org/image"] = 2,
    ["http://opds-spec.org/cover"] = 2,
    ["x-stanza-cover-image"] = 2,
}

-- 这些 atom 链接指回自身或上层，不是下钻目标。
local NOT_NAV = { self = true, start = true, up = true, search = true, next = true, previous = true, first = true, last = true }

--- 顺序取出名为 name（可带命名空间前缀）的元素。
--- 同名元素不嵌套（entry / link / author 都满足），遇到开标签直接找对应闭标签。
---@param xml string
---@param name string
---@return { attrs: string, body: string }[]
local function elements(xml, name)
    local out, pos = {}, 1
    local open = "<([%w_%-%.]*:?)" .. name .. "([%s/>])"
    while true do
        local s, e, prefix, delim = xml:find(open, pos)
        if not s then return out end
        pos = e + 1
        if prefix == "" or prefix:sub(-1) == ":" then
            local tag_end = delim == ">" and e or xml:find(">", e, true)
            if not tag_end then return out end
            local attrs = delim == ">" and "" or xml:sub(e, tag_end - 1)
            local body = ""
            pos = tag_end + 1
            if attrs:sub(-1) == "/" then
                attrs = attrs:sub(1, -2)
            else
                local close = "</" .. (prefix .. name):gsub("%p", "%%%0") .. "%s*>"
                local cs, ce = xml:find(close, pos)
                if cs then
                    body = xml:sub(pos, cs - 1)
                    pos = ce + 1
                end
            end
            out[#out + 1] = { attrs = attrs, body = body }
        end
    end
end

---@param attrs string
---@return table<string, string>
local function parseAttrs(attrs)
    local out = {}
    for key, _q, value in attrs:gmatch("([%w_:%-]+)%s*=%s*([\"'])(.-)%2") do
        out[key:lower()] = Text.xmlDecode(value)
    end
    return out
end

--- 元素正文 → 纯文本：去 CDATA、标签（xhtml 内联与转义后的 html 两层）并折叠空白。
---@param body string|nil
---@return string
local function plain(body)
    local s = tostring(body or ""):gsub("<!%[CDATA%[(.-)%]%]>", "%1"):gsub("<[^>]+>", " ")
    s = Text.xmlDecode(s):gsub("<[^>]+>", " "):gsub("%s+", " ")
    return Text.trim(s)
end

---@param xml string
---@param name string
---@return string|nil
local function firstText(xml, name)
    local el = elements(xml, name)[1]
    local s = el and plain(el.body)
    return s ~= "" and s or nil
end

---@param xml string
---@param base string
---@return table[]
local function links(xml, base)
    local out = {}
    for _i, el in ipairs(elements(xml, "link")) do
        local a = parseAttrs(el.attrs)
        a.href = Text.absoluteUrl(base, a.href)
        if a.href then
            a.rel = a.rel or ""
            a.type = (a.type or ""):lower()
            out[#out + 1] = a
        end
    end
    return out
end

--- 获取链接 → 扩展名：先认 MIME，application/zip 这类泛型再看 href 路径后缀。
---@param link table
---@return string|nil
local function formatOf(link)
    local ext = MIME_EXT[link.type:match("^[^;%s]+") or ""]
    if ext then return ext end
    local suffix = link.href:match("^[^?#]*%.(%w+)$")
    suffix = suffix and suffix:lower()
    return EXT_RANK[suffix] and suffix or nil
end

---@param list string[]
---@return string|nil
local function joined(list, sep)
    return #list > 0 and table.concat(list, sep) or nil
end

--- 获取链接择优：返回获取链接条数与本地书库能打开的最优一条。
---@param list { rel: string, type: string, href: string, length: any }[] 已归一化的链接
---@return integer count
---@return { href: string, format: string, length: number|nil }|nil
local function bestAcquisition(list)
    local count, best, best_rank = 0, nil, nil
    for _i, l in ipairs(list) do
        if ACQUISITION[l.rel] then
            count = count + 1
            local ext = formatOf(l)
            if ext and (not best_rank or EXT_RANK[ext] < best_rank) then
                best, best_rank = { href = l.href, format = ext, length = tonumber(l.length) }, EXT_RANK[ext]
            end
        end
    end
    return count, best
end

--- Atom 与 OPDS 2.0 共用的书籍构造；无身份（无 id 且无可用下载）丢弃。
---@param m { id: string|nil, title: string|nil, authors: string[], categories: string[], intro: string|nil, cover: string|nil }
---@param best table|nil bestAcquisition 结果
---@return Book|nil
local function book(m, best)
    local stable_id = m.id or (best and best.href)
    if not stable_id then return nil end
    return {
        source_id = "opds",
        stable_id = stable_id,
        title = m.title or _("未知书名"),
        authors = joined(m.authors, ", "),
        category = joined(m.categories, ","),
        intro = m.intro,
        percent = 0,
        cover = m.cover,
        cover_url = m.cover,
        download = best and best.href,
        format = best and best.format,
        filesize = best and best.length,
    }
end

--- 单个 entry：有获取链接即书，否则找可下钻的 atom 链接当导航；两者都没有丢弃。
---@param xml string entry 正文
---@param base string feed URL，解析相对链接用
---@return table|nil
local function entry(xml, base)
    local list = links(xml, base)
    local nav, cover, cover_rank
    for _i, l in ipairs(list) do
        local rank = COVER_RELS[l.rel]
        if rank then
            if not cover_rank or rank < cover_rank then cover, cover_rank = l.href, rank end
        elseif not nav and not ACQUISITION[l.rel] and not NOT_NAV[l.rel]
            and l.type:find("application/atom+xml", 1, true) and not l.type:find("type=entry", 1, true) then
            nav = l.href
        end
    end
    local count, best = bestAcquisition(list)
    local title = firstText(xml, "title")
    if count == 0 then
        return nav and { title = title or _("未知书名"), feed = nav, cover_url = cover } or nil
    end
    local authors, categories = {}, {}
    for _i, a in ipairs(elements(xml, "author")) do
        authors[#authors + 1] = firstText(a.body, "name")
    end
    for _i, c in ipairs(elements(xml, "category")) do
        local a = parseAttrs(c.attrs)
        categories[#categories + 1] = a.label or a.term
    end
    return book({
        id = firstText(xml, "id"),
        title = title,
        authors = authors,
        categories = categories,
        intro = firstText(xml, "summary") or firstText(xml, "content"),
        cover = cover,
    }, best)
end

--- OPDS 2.0 的文本字段可能是本地化映射 { en = "...", fr = "..." }。
---@param v any
---@return string|nil
local function localized(v)
    if type(v) == "table" then v = v.en or select(2, next(v)) end
    return type(v) == "string" and v ~= "" and v or nil
end

--- OPDS 2.0 的 author / subject：字符串、{ name } 或它们的数组。
---@param v any
---@return string[]
local function names(v)
    if type(v) ~= "table" or v.name then v = { v } end
    local out = {}
    for _i, item in ipairs(v) do
        out[#out + 1] = localized(type(item) == "table" and item.name or item)
    end
    return out
end

--- OPDS 2.0 Link Object → 与 Atom 相同的归一化链接；rel 可以是数组，按每个 rel 各出一条。
---@param raw any
---@param base string
---@return table[]
local function jsonLinks(raw, base)
    local out = {}
    for _i, l in ipairs(type(raw) == "table" and raw or {}) do
        local href = type(l) == "table" and type(l.href) == "string" and Text.absoluteUrl(base, l.href)
        if href then
            local rels = type(l.rel) == "table" and l.rel or { l.rel or "" }
            for _i, rel in ipairs(rels) do
                out[#out + 1] = {
                    rel = tostring(rel), type = tostring(l.type or ""):lower(), href = href,
                    title = localized(l.title), templated = l.templated == true,
                    length = type(l.properties) == "table" and l.properties.size or nil,
                }
            end
        end
    end
    return out
end

--- OPDS 2.0 publication → Book。封面取最窄的一张（网格里只画缩略图）。
---@param p table
---@param base string
---@return Book|nil
local function publication(p, base)
    local m = type(p.metadata) == "table" and p.metadata or {}
    local cover, cover_w
    for _i, img in ipairs(type(p.images) == "table" and p.images or {}) do
        local href = type(img) == "table" and type(img.href) == "string" and Text.absoluteUrl(base, img.href)
        local w = href and tonumber(img.width) or 0
        if href and (not cover or (w > 0 and (cover_w == 0 or w < cover_w))) then cover, cover_w = href, w end
    end
    local _count, best = bestAcquisition(jsonLinks(p.links, base))
    return book({
        id = localized(m.identifier),
        title = localized(m.title),
        authors = names(m.author),
        categories = names(m.subject),
        intro = m.description and plain(localized(m.description)) or nil,
        cover = cover,
    }, best)
end

--- OPDS 2.0 navigation 数组 → 导航项。
---@param raw any
---@param base string
---@param items table[] 追加目标
local function navigation(raw, base, items)
    for _i, l in ipairs(jsonLinks(raw, base)) do
        items[#items + 1] = { title = l.title or _("未知书名"), feed = l.href }
    end
end

--- 解析 OPDS 2.0 feed。groups 有 self 链接时折叠成一个可下钻的导航项，否则内容平铺。
---@param data table
---@param base string
---@return OpdsFeed
local function jsonFeed(data, base)
    local items = {}
    local function fill(node)
        navigation(node.navigation, base, items)
        for _i, p in ipairs(type(node.publications) == "table" and node.publications or {}) do
            items[#items + 1] = type(p) == "table" and publication(p, base) or nil
        end
    end
    fill(data)
    for _i, g in ipairs(type(data.groups) == "table" and data.groups or {}) do
        local self_href
        for _i, l in ipairs(jsonLinks(g.links, base)) do
            if l.rel == "self" then self_href = l.href end
        end
        local title = type(g.metadata) == "table" and localized(g.metadata.title)
        if self_href then
            items[#items + 1] = { title = title or _("未知书名"), feed = self_href }
        else
            fill(g)
        end
    end
    local feed = { title = type(data.metadata) == "table" and localized(data.metadata.title) or nil, items = items }
    for _i, l in ipairs(jsonLinks(data.links, base)) do
        if l.rel == "next" then
            feed.next = feed.next or l.href
        elseif l.rel == "search" and l.templated then
            feed.search_template = feed.search_template or l.href
        end
    end
    return feed
end

---@class OpdsFeed
---@field title string|nil
---@field items table[] 书籍（Book）与导航项（{ title, feed }）混排，保持 feed 顺序
---@field next string|nil 下一页 feed
---@field search_template string|nil 直接可用的搜索模板（{searchTerms} 或 RFC 6570 {?query}）
---@field search_osd string|nil OpenSearch 描述地址

--- 解析一份 feed：`{` 开头按 OPDS 2.0 JSON，否则按 1.x Atom。两者都不是（HTML 登录页等）直接失败。
---@param xml string|nil
---@param base string 本 feed 的 URL
---@return OpdsFeed|nil, string|nil
function Mapper.feed(xml, base)
    if type(xml) == "string" and xml:match("^%s*{") then
        -- 服务端回的 JSON 可能截断或是错误页，解析失败就是「不是目录」，不往上抛。
        local ok, data = pcall(JSON.decode, xml)
        if ok and type(data) == "table" and (data.metadata or data.navigation or data.publications or data.groups) then
            return jsonFeed(data, base)
        end
        return nil, _("不是有效的 OPDS 目录")
    end
    if type(xml) ~= "string" or not xml:find("<[%w_%-%.]*:?feed[%s>]") then
        return nil, _("不是有效的 OPDS 目录")
    end
    local items = {}
    for _i, el in ipairs(elements(xml, "entry")) do
        items[#items + 1] = entry(el.body, base)
    end
    local head = xml:gsub("<([%w_%-%.]*:?)entry[%s>].-</%1entry%s*>", "")
    local feed = { title = firstText(head, "title"), items = items }
    for _i, l in ipairs(links(head, base)) do
        if l.rel == "next" then
            feed.next = feed.next or l.href
        elseif l.rel == "search" then
            if l.type:find("opensearchdescription", 1, true) then
                feed.search_osd = feed.search_osd or l.href
            elseif l.href:find("{searchTerms}", 1, true) then
                feed.search_template = feed.search_template or l.href
            end
        end
    end
    return feed
end

--- OpenSearch 描述 → 搜索模板：优先 Atom 结果的 Url。
---@param xml string
---@param base string 描述文档 URL
---@return string|nil
function Mapper.searchTemplate(xml, base)
    local fallback
    for _i, el in ipairs(elements(xml, "Url")) do
        local a = parseAttrs(el.attrs)
        if a.template then
            if (a.type or ""):find("atom", 1, true) then return Text.absoluteUrl(base, a.template) end
            fallback = fallback or a.template
        end
    end
    return Text.absoluteUrl(base, fallback)
end

-- 模板里代表关键词的变量：OpenSearch 用 searchTerms，OPDS 2.0（RFC 6570）用 query。
local QUERY_VARS = { searchTerms = true, query = true }

--- 填搜索模板：关键词变量换成关键词，其余变量清空。
--- 认 OpenSearch `{searchTerms}` / `{startPage?}` 与 RFC 6570 的 `{query}`、`{?query,title}`、`{&query}`。
---@param template string
---@param query string
---@return string
function Mapper.searchUrl(template, query)
    local encoded = Text.urlEncode(query)
    return (template:gsub("{([?&]?)([^}]*)}", function(op, vars)
        local pairs_ = {}
        for var in vars:gmatch("[^,]+") do
            if QUERY_VARS[var] then
                if op == "" then return encoded end
                pairs_[#pairs_ + 1] = var .. "=" .. encoded
            end
        end
        return #pairs_ > 0 and op .. table.concat(pairs_, "&") or ""
    end))
end

return Mapper
