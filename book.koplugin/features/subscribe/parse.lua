--[[--
订阅解析（纯函数）：RSS / Atom → 条目，任意网页 → 文章链接，文章页 → 正文片段。

不用 XML 解析器：订阅源千奇百怪，按标签模式匹配反而更宽容；只取标题、链接、guid、时间、正文。

@module koplugin.book.features.subscribe.parse
--]]

local Text = require("utils.text")
local bit = require("bit")

local Parse = {}

--- 单篇正文摘要上限：content:encoded 有时整篇几百 KB，超过就丢掉、打开时再抓原文。
local MAX_SUMMARY = 200 * 1024

local MONTHS = { jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6, jul = 7, aug = 8, sep = 9, oct = 10, nov = 11, dec = 12 }

--- 公历日期 → UTC 秒（不经本地时区）。
local function epoch(y, m, d, hh, mm, ss)
    y = m <= 2 and y - 1 or y
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return (era * 146097 + doe - 719468) * 86400 + hh * 3600 + mm * 60 + ss
end

--- "+0800" / "+08:00" / "Z" / "GMT" → 秒。
local function offset(zone)
    local sign, h, m = tostring(zone or ""):match("([%+%-])(%d%d):?(%d%d)")
    if not sign then return 0 end
    local v = tonumber(h) * 3600 + tonumber(m) * 60
    return sign == "-" and -v or v
end

--- RFC 822（RSS）或 ISO 8601（Atom）→ UTC 秒；认不出返回 nil。
---@param s string|nil
---@return integer|nil
function Parse.time(s)
    s = Text.trim(tostring(s or ""))
    local y, m, d, hh, mm, ss, zone = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):?(%d*)[%.%d]*(.*)$")
    if y then
        return epoch(tonumber(y), tonumber(m), tonumber(d), tonumber(hh), tonumber(mm), tonumber(ss) or 0) - offset(zone)
    end
    y, m, d = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if y then return epoch(tonumber(y), tonumber(m), tonumber(d), 0, 0, 0) end
    local dd, mon, yy, rest = s:match("(%d%d?)%s+(%a%a%a)%a*%s+(%d%d%d?%d?)%s*(.*)$")
    local month = mon and MONTHS[mon:lower()]
    if not month then return nil end
    yy = tonumber(yy)
    if yy < 100 then yy = yy + 2000 end
    hh, mm, ss, zone = rest:match("^(%d%d?):(%d%d):?(%d*)%s*(.*)$")
    return epoch(yy, month, tonumber(dd), tonumber(hh) or 0, tonumber(mm) or 0, tonumber(ss) or 0) - offset(zone)
end

--- 标签里的正文，`<tag attr>` 形式也认。
local function field(block, tag)
    local open_end = select(2, block:find("<" .. tag .. "%f[%s>/][^>]*>"))
    if not open_end then return nil end
    local close = block:find("</" .. tag .. ">", open_end + 1, true)
    if not close then return nil end
    local body = block:sub(open_end + 1, close - 1)
    -- 可能有多段 CDATA（阮一峰的 Atom 每段一个）：段内原样，段外按 XML 解码。
    local out, pos = {}, 1
    while true do
        local s, e = body:find("<![CDATA[", pos, true)
        if not s then
            local tail = body:sub(pos)
            if pos == 1 or tail:match("%S") then out[#out + 1] = Text.xmlDecode(tail) end
            break
        end
        local gap = body:sub(pos, s - 1)
        if gap:match("%S") then out[#out + 1] = Text.xmlDecode(gap) end
        local c = body:find("]]>", e + 1, true)
        out[#out + 1] = body:sub(e + 1, (c or #body + 1) - 1)
        if not c then break end
        pos = c + 3
    end
    return table.concat(out)
end

--- Cloudflare 邮箱保护的十六进制串 → 明文：首字节是异或密钥。
local function cfDecode(hex)
    local key = tonumber(hex:sub(1, 2), 16)
    if not key or #hex % 2 ~= 0 then return nil end
    local out = {}
    for i = 3, #hex - 1, 2 do
        local b = tonumber(hex:sub(i, i + 1), 16)
        if not b then return nil end
        out[#out + 1] = string.char(bit.bxor(b, key))
    end
    return table.concat(out)
end

--- 还原 Cloudflare 邮箱保护：data-cfemail 元素换成明文，/cdn-cgi/l/email-protection#hex 链接换成 mailto:。
---@param html string
---@return string
function Parse.cfEmail(html)
    html = tostring(html or "")
    if not html:find("cfemail", 1, true) and not html:find("email-protection", 1, true) then return html end
    html = html:gsub("<(%a+)(%s[^>]-)data%-cfemail=[\"']?(%x+)[\"']?[^>]*>.-</%1>", function(_tag, _attrs, hex)
        return cfDecode(hex) or nil
    end)
    html = html:gsub("([\"'])[^\"']-/cdn%-cgi/l/email%-protection#(%x+)%1", function(q, hex)
        local mail = cfDecode(hex)
        return mail and q .. "mailto:" .. mail .. q or nil
    end)
    return html
end

--- 纯文本标题：剥标签、压空白。
local function plain(s)
    return Text.trim((Text.stripHtml(tostring(s or "")):gsub("%s+", " ")))
end

--- RSS 2.0 / RSS 1.0 / Atom → { title, items }；一个条目都没有返回 nil（多半不是订阅源）。
---@param xml string
---@return { title: string, items: { guid: string, title: string, link: string, time: integer, summary: string|nil }[] }|nil
function Parse.feed(xml)
    xml = tostring(xml or "")
    local items = {}
    local function add(block, atom)
        local link
        if atom then
            for tag in block:gmatch("<link%f[%s][^>]*>") do
                local rel = tag:match('rel=["\']([^"\']+)')
                local href = tag:match('href=["\']([^"\']+)')
                if href and (not rel or rel == "alternate") then link = Text.xmlDecode(href) break end
            end
        else
            link = field(block, "link")
        end
        link = Text.trim(link or "")
        local guid = Text.trim(field(block, atom and "id" or "guid") or "")
        if guid == "" then guid = link end
        local title = plain(field(block, "title"))
        if guid == "" and title == "" then return end
        if guid == "" then guid = title end
        local summary = field(block, "content:encoded") or field(block, "content")
            or field(block, "description") or field(block, "summary")
        if summary and (#summary > MAX_SUMMARY or summary:match("^%s*$")) then summary = nil end
        local time = Parse.time(field(block, "pubDate") or field(block, "published") or field(block, "updated")
            or field(block, "dc:date")) or 0
        items[#items + 1] = { guid = guid, title = title ~= "" and title or link, link = link, time = time, summary = summary }
    end
    for block in xml:gmatch("<item%f[%s>].-</item>") do add(block, false) end
    if #items == 0 then
        for block in xml:gmatch("<entry%f[%s>].-</entry>") do add(block, true) end
    end
    if #items == 0 then return nil end
    local head = xml:match("^(.-)<item%f[%s>]") or xml:match("^(.-)<entry%f[%s>]") or ""
    return { title = plain(field(head, "title")), items = items }
end

--- 网页 <title>。
---@param html string
---@return string
function Parse.title(html)
    return plain(Text.xmlDecode(tostring(html or ""):match("<title[^>]*>(.-)</title>") or ""))
end

--- 任意网页 → 文章链接（页面顺序，当作新到旧）。
--- 只留同站、链接文字够长（像标题）的链接；filter 非空时只留 href 含该子串的（纯文本匹配，不是 CSS）。
---@param html string
---@param base string 页面 URL
---@param filter string|nil
---@return { guid: string, title: string, link: string }[]
function Parse.links(html, base, filter)
    local host = tostring(base or ""):match("^https?://([^/]+)")
    filter = filter and Text.trim(filter) ~= "" and Text.trim(filter) or nil
    html = tostring(html or ""):gsub("<script.-</script>", ""):gsub("<style.-</style>", "")
    local out, seen = {}, {}
    for attrs, text in html:gmatch("<a%s([^>]*)>(.-)</a>") do
        local _q, href = attrs:match('href=(["\'])(.-)%1')
        if href and not href:match("^#") and not href:match("^javascript:") and not href:match("^mailto:") then
            local url = (Text.absoluteUrl(base, Text.xmlDecode(href)) or ""):gsub("#.*$", "")
            local title = plain(Text.xmlDecode(text))
            if title == "" then title = plain(attrs:match('title=["\']([^"\']+)') or "") end
            local same = url:match("^https?://([^/]+)") == host
            local wanted = filter and url:find(filter, 1, true) or (not filter and same and #title >= 12)
            if wanted and url ~= "" and url ~= base and title ~= "" and not seen[url] then
                seen[url] = true
                out[#out + 1] = { guid = url, title = title, link = url }
            end
        end
    end
    return out
end

--- 文章页 → 正文片段（简化版 readability）：去掉脚本 / 导航 / 页眉页脚 / 表单，
--- 取 <article>，没有取 <main>，再没有取 <body>。
---@param html string
---@return string|nil
function Parse.article(html)
    html = tostring(html or "")
    for _idx, tag in ipairs({ "script", "style", "noscript", "nav", "header", "footer", "aside", "form", "svg", "iframe" }) do
        html = html:gsub("<" .. tag .. "%f[%s>].-</" .. tag .. ">", "")
    end
    html = html:gsub("<!%-%-.-%-%->", "")
    local body = html:match("<article%f[%s>][^>]*>(.*)</article>")
        or html:match("<main%f[%s>][^>]*>(.*)</main>")
        or html:match("<body[^>]*>(.*)</body>") or html
    -- 懒加载图：data-src 换成 src，内联尺寸去掉。
    body = body:gsub("<img%s[^>]*>", function(tag)
        local _q, src = tag:match('data%-src=(["\'])(.-)%1')
        if not src then _q, src = tag:match('%ssrc=(["\'])(.-)%1') end
        if not src or src:match("^data:") then return "" end
        return '<img src="' .. src .. '"/>'
    end)
    if plain(body) == "" then return nil end
    return body
end

return Parse
