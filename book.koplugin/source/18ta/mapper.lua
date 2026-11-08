--[[--
18ta 页面解析：纯函数，无网络。

书目卡片是 /sort/<cat>/<page>.html 的 `<li>…</li>` 块；书页用 og:novel meta、.intro 简介与 og:image 封面；
目录在 <ul id="ul_all_chapters">（章序升序；页首「最新章节」块是另一个 <ul>，不在其内）。
章节正文在 <article id="article"> 内，纯 <p> 段落，无图无脚本。

@module source.18ta.mapper
--]]

local Text = require("utils.text")
local _ = require("l10n").get("source.18ta")

local BASE = "https://www.18ta.com"

local Mapper = {}

Mapper.CONTENT_MARK = "moon:18ta:complete"

---@param node string|nil
---@return string|nil
function Mapper.storeNode(node)
    if type(node) ~= "string" then return nil end
    local path = node:gsub("^/quanben/", "/")
    if path == "/sort/" or path:match("^/sort/%d+/1%.html$") then return node end
end

---@param node string
---@param page integer
---@return string
function Mapper.storePage(node, page)
    if node:sub(-1) == "/" then return node .. page .. ".html" end
    return (node:gsub("/1%.html$", "/" .. page .. ".html"))
end

--- 分类来自官网筛选区；完本首页的分页链接漏掉 quanben，仍按选中频道构造请求。
---@param html string
---@param node string
---@return StoreChipGroup[]|nil
function Mapper.storeGroups(html, node)
    local filters = html:match('<div id="after_menu">(.-)</div>%s*</div>')
    if not filters then return nil end
    local completed = node:find("^/quanben/") ~= nil
    local category = node:gsub("^/quanben/", "/")
    local chips, seen = {}, {}
    for href, title in filters:gmatch('<a[^>]-href="([^"]+)"[^>]*>(.-)</a>') do
        local path = href:gsub("^/quanben/", "/")
        if Mapper.storeNode(path) and not seen[path] then
            seen[path] = true
            chips[#chips + 1] = {
                id = completed and "/quanben" .. path or path,
                title = _(Text.trim(Text.stripHtml(title))),
            }
        end
    end
    if #chips == 0 or not seen[category] then return nil end
    return {
        { title = _("分类"), chips = chips, active = node },
        { title = _("状态"), chips = {
            { id = category, title = _("全部") },
            { id = "/quanben" .. category, title = _("完本") },
        }, active = node },
    }
end

---@param html string
---@param node string
---@param page integer
---@return boolean
function Mapper.storeMore(html, node, page)
    local pager = html:match('<div[^>]-id="pagelink"[^>]*>(.-)</div>')
    if not pager then return false end
    local next_path = Mapper.storePage(node, page + 1):gsub("^/quanben/", "/")
    for href in pager:gmatch('href="([^"]+)"') do
        if href:gsub("^/quanben/", "/") == next_path then return true end
    end
    return false
end

--- 分类书库一页。
---@param html string
---@return Book[]|nil books
function Mapper.list(html)
    if not html:find('<ul class="flex">', 1, true) then return nil end
    local books = {}
    for card in html:gmatch('<div class="img_span">.-</li>') do
        local id = card:match('href="/akshtml(%d+)%.html"')
        if id then
            local title = card:match("<h2>(.-)</h2>")
            if not title then return nil end
            local author = card:match('fa%-user%-circle%-o">([^<]*)</i>')
            local intro = card:match('<p class="indent">(.-)</p>')
            local cover = card:match('data%-original="([^"]+)"')
            local cat, status = card:match("<span>(.-)%s*/%s*(.-)</span>")
            books[#books + 1] = {
                source_id = "18ta",
                stable_id = id,
                title = Text.trim(Text.xmlDecode(title)),
                authors = author and Text.trim(Text.stripHtml(author)) or "",
                category = cat and Text.trim(cat) or nil,
                intro = intro and Text.trim(Text.stripHtml(intro)) or "",
                cover = cover and Text.absoluteUrl(BASE, cover) or nil,
                meta = { status = status and Text.trim(status) or nil },
            }
        else return nil end
    end
    return books
end

--- 书籍详情页。source_id / stable_id 由调用方带上。
---@param html string
---@return table|nil
function Mapper.book(html)
    local function og(prop)
        local v = html:match('<meta property="og:novel:' .. prop .. '" content="([^"]*)"')
        if not v or v == "" or v == "None" then return nil end
        return Text.xmlDecode(v)
    end
    local title = og("book_name")
    if not title then return nil end
    local intro = html:match('<div class="intro">(.-)</div>')
    local cover = html:match('<meta property="og:image" content="([^"]*)"')
    return {
        title = title,
        authors = og("author") or "",
        category = og("category"),
        intro = intro and Text.trim(Text.stripHtml(intro)) or "",
        cover = cover and Text.absoluteUrl(BASE, cover) or nil,
        meta = { status = og("status") },
    }
end

--- 目录（章序升序）。
---@param html string
---@return table[] toc
function Mapper.toc(html)
    local ul = html:match('<ul id="ul_all_chapters">(.-)</ul>')
    if not ul then return {} end
    local toc = {}
    for href, text in ul:gmatch('<li><a href="([^"]+)" title="[^"]*">([^<]*)</a></li>') do
        toc[#toc + 1] = {
            idx = #toc + 1,
            uid = href,
            title = Text.trim(Text.xmlDecode(text)),
            origin = Text.absoluteUrl(BASE, href),
        }
    end
    return toc
end

--- 章节正文片段（<article> 内部）。
---@param html string
---@return string|nil
function Mapper.chapterContent(html)
    local body = html:match('<article[^>]-id="article"[^>]*>(.-)</article>')
    if not body then return nil end
    body = body:gsub("<script[^>]*>.-</script>", ""):gsub("<style[^>]*>.-</style>", "")
    if not body:find("<p", 1, true) or Text.trim(Text.stripHtml(body)) == "" then return nil end
    return body
end

---@param html string
---@param current string
---@return string|nil next_path
---@return string|nil err
function Mapper.chapterNext(html, current)
    local next_tag = html:match('<a[^>]-id="next_url"[^>]*>')
    local href = next_tag and next_tag:match('href="([^"]+)"')
    current = current:gsub("^https://www%.18ta%.com/", "/")
    local stem, suffix = current:match("^(/aks/%d+/%d+/%d+)([^/]*)%.html$")
    if not stem or not href then return nil, _("响应无效") end
    local page = suffix == "" and 1 or tonumber(suffix:match("^_(%d+)$"))
    if not page then return nil, _("响应无效") end
    if href == stem .. "_" .. (page + 1) .. ".html" then return href end
    local book_dir = stem:match("^(/aks/%d+/%d+/)")
    local book_id = stem:match("^/aks/%d+/(%d+)/")
    if href == "/akshtml" .. book_id .. ".html"
        or (href:match("^/aks/%d+/%d+/%d+%.html$") and href:sub(1, #book_dir) == book_dir
            and href ~= stem .. ".html") then
        return nil
    end
    return nil, _("响应无效")
end

return Mapper
