--[[--
RSS 2.0 / Atom 解析与正文清理。

参考 quickrss.koplugin 的数据层；不包含网络与全文服务。

@module koplugin.book.source.rss.parser
--]]

local Xml = require("source.rss.xml")
local H = require("source.rss.xml_handler")

local Parser = {}

local function childText(node, name)
    local child = H.child(node, name)
    return child and H.text(child) or ""
end

local function contentOf(node, name)
    local child = H.child(node, name)
    if not child then return "" end
    local xml = H.innerXml(child)
    return xml ~= "" and xml or H.text(child)
end

--- 规范化 feed URL；只接受 http(s)。
---@param raw string|nil
---@return string|nil
function Parser.normalizeUrl(raw)
    local value = tostring(raw or ""):match("^%s*(.-)%s*$") or ""
    if value == "" then return nil end
    if not value:match("^[hH][tT][tT][pP][sS]?://") then
        value = "https://" .. value
    end
    local scheme, host, rest = value:match("^([%a]+)://([^/]+)(.*)$")
    scheme = scheme and string.lower(scheme)
    if scheme ~= "http" and scheme ~= "https" then return nil end
    rest = rest == "" and "/" or rest
    if rest ~= "/" then rest = rest:gsub("/+$", "") end
    return string.lower(scheme) .. "://" .. string.lower(host) .. rest
end

--- 相对 URL → 绝对 URL。
---@param base string
---@param ref string|nil
---@return string
function Parser.absoluteUrl(base, ref)
    ref = tostring(ref or ""):match("^%s*(.-)%s*$") or ""
    if ref == "" or ref:match("^[%a][%w+%.%-]*:") then
        return ref
    end
    local scheme, authority, path = tostring(base or ""):match("^(https?)://([^/]+)(/.*)$")
    if not scheme then
        scheme, authority = tostring(base or ""):match("^(https?)://([^/]+)$")
        path = "/"
    end
    if not scheme then return ref end
    if ref:sub(1, 2) == "//" then return scheme .. ":" .. ref end
    local clean_base = tostring(base):gsub("[#?].*$", "")
    if ref:sub(1, 1) == "#" or ref:sub(1, 1) == "?" then
        return clean_base .. ref
    end
    if ref:sub(1, 1) == "/" then return scheme .. "://" .. authority .. ref end
    local dir = (path or "/"):match("^(.*)/") or ""
    local combined = dir .. "/" .. ref
    local parts = {}
    for part in combined:gmatch("[^/]+") do
        if part == ".." then
            table.remove(parts)
        elseif part ~= "." and part ~= "" then
            parts[#parts + 1] = part
        end
    end
    return scheme .. "://" .. authority .. "/" .. table.concat(parts, "/")
end

local function sanitize(html)
    html = tostring(html or "")
    for _, pattern in ipairs({
        "<[sS][cC][rR][iI][pP][tT][^>]*>[%s%S]-</[sS][cC][rR][iI][pP][tT]>",
        "<[iI][fF][rR][aA][mM][eE][^>]*>[%s%S]-</[iI][fF][rR][aA][mM][eE]>",
        "<[oO][bB][jJ][eE][cC][tT][^>]*>[%s%S]-</[oO][bB][jJ][eE][cC][tT]>",
        "<[sS][tT][yY][lL][eE][^>]*>[%s%S]-</[sS][tT][yY][lL][eE]>",
    }) do
        html = html:gsub(pattern, "")
    end
    html = html:gsub("%s+[oO][nN][%w_%-]+%s*=%s*\"[^\"]*\"", "")
    html = html:gsub("%s+[oO][nN][%w_%-]+%s*=%s*'[^']*'", "")
    html = html:gsub("([hH][rR][eE][fF]%s*=%s*[\"'])%s*[jJ][aA][vV][aA][sS][cC][rR][iI][pP][tT]:[^\"']*([\"'])", "%1%2")
    return html
end

--- 清理正文并绝对化 href/src。
---@param html string
---@param base_url string
---@return string
function Parser.prepareHtml(html, base_url)
    html = sanitize(html)
    html = html:gsub("([hH][rR][eE][fF])(%s*=%s*)([\"'])(.-)%3",
        function(attr, eq, quote, value)
            return attr .. eq .. quote .. Parser.absoluteUrl(base_url, value) .. quote
        end)
    return html:gsub("([sS][rR][cC])(%s*=%s*)([\"'])(.-)%3",
        function(attr, eq, quote, value)
            return attr .. eq .. quote .. Parser.absoluteUrl(base_url, value) .. quote
        end)
end

local function atomLink(entry)
    for _, link in ipairs(H.children(entry, "link")) do
        local rel = link.attr and link.attr.rel
        if not rel or rel == "" or rel == "alternate" then
            return (link.attr and link.attr.href) or H.text(link)
        end
    end
    return ""
end

local function itemImage(item, content)
    for _, name in ipairs({ "media:thumbnail", "media:content", "enclosure" }) do
        local node = H.child(item, name)
        local attrs = node and node.attr or {}
        if attrs.url and (name ~= "enclosure" or tostring(attrs.type):match("^image/")) then
            return attrs.url
        end
    end
    return content:match('<[iI][mM][gG][^>]-[sS][rR][cC]%s*=%s*["\']([^"\']+)')
end

--- 解析 feed。
---@param raw string
---@param feed_url string
---@return table|nil, string|nil
function Parser.parse(raw, feed_url)
    local doc, err = Xml.parse(raw)
    if not doc then return nil, err end
    local rss = H.child(doc, "rss")
    local atom = H.child(doc, "feed")
    local container
    local is_atom = atom ~= nil
    if rss then
        container = H.child(rss, "channel")
    else
        container = atom
    end
    if not container then return nil, "unrecognised feed format" end

    local title = childText(container, "title")
    local intro = childText(container, is_atom and "subtitle" or "description")
    local raw_items = H.children(container, is_atom and "entry" or "item")
    local items = {}
    for _, item in ipairs(raw_items) do
        local link = is_atom and atomLink(item) or childText(item, "link")
        link = Parser.absoluteUrl(feed_url, link)
        local content
        if is_atom then
            content = contentOf(item, "content")
            if content == "" then content = contentOf(item, "summary") end
        else
            content = contentOf(item, "content:encoded")
            if content == "" then content = contentOf(item, "description") end
        end
        content = Parser.prepareHtml(content, link ~= "" and link or feed_url)
        local guid = childText(item, is_atom and "id" or "guid")
        if guid == "" then guid = link end
        local item_title = childText(item, "title")
        if item_title == "" then item_title = guid ~= "" and guid or "Untitled" end
        local image = itemImage(item, content)
        local date = childText(item, is_atom and "published" or "pubdate")
        if is_atom and date == "" then date = childText(item, "updated") end
        items[#items + 1] = {
            uid = guid,
            title = item_title,
            link = link,
            date = date,
            content = content,
            image_url = Parser.absoluteUrl(link ~= "" and link or feed_url, image),
        }
    end
    return {
        title = title ~= "" and title or feed_url,
        intro = intro,
        url = feed_url,
        items = items,
    }
end

return Parser
