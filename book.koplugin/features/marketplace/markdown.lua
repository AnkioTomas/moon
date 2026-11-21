--[[--
把 README 的 Markdown 转成可交给 HtmlBox 的保守 HTML。
先保护代码块与行内代码，再放行白名单块级/行内 HTML（p、table、对齐），
其余标签与属性一律转义；不输出 script / 样式表 / 事件 / 远程图片。
支持 GitHub 管道表格。图片只保留替代文字，不写出 src。
链接只保留 http(s) / mailto，以及相对路径在给定仓库基址下解析出的官方地址；
不会把相对路径交给公共镜像。

@module koplugin.book.features.marketplace.markdown
--]]

local Markdown = {}

--- 交给 HtmlBox 的业务样式（表格 / 对齐）。不进主题 Html.BASE，避免词典等无关调用方沾上。
Markdown.CSS = [[
table.md-table { border-collapse: collapse; margin: 0.6em 0; width: 100%; }
table.md-table th, table.md-table td { border: 1px solid #999; padding: 0.25em 0.45em; vertical-align: top; }
table.md-table th { font-weight: bold; }
.md-align-left { text-align: left; }
.md-align-center { text-align: center; }
.md-align-right { text-align: right; }
.md-align-justify { text-align: justify; }
]]

local ALLOW_TAGS = {
    p = true, br = true, hr = true, div = true,
    h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true,
    strong = true, b = true, em = true, i = true, u = true, s = true,
    del = true, ins = true, mark = true, code = true, pre = true,
    blockquote = true, ul = true, ol = true, li = true,
    table = true, thead = true, tbody = true, tfoot = true,
    tr = true, th = true, td = true, caption = true,
    a = true, span = true, sup = true, sub = true, img = true,
}

local VOID_TAGS = { br = true, hr = true, img = true }

local DROP_INNER = {
    script = true, style = true, iframe = true, object = true, embed = true,
    svg = true, form = true, input = true, textarea = true, button = true,
    link = true, meta = true, base = true, applet = true, frame = true,
    frameset = true, video = true, audio = true, source = true, canvas = true,
}

local ALIGN = { left = true, center = true, right = true, justify = true }

local NAMED_ENTITIES = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = "\194\160",
}

local function esc(text)
    return (tostring(text or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function utf8char(n)
    if type(n) ~= "number" or n < 0 or n > 0x10FFFF then return nil end
    if n >= 0xD800 and n <= 0xDFFF then return nil end
    if n < 0x20 and n ~= 9 and n ~= 10 and n ~= 13 then return nil end
    if n == 0x7F then return nil end
    if n < 0x80 then return string.char(n) end
    if n < 0x800 then
        return string.char(0xC0 + math.floor(n / 64), 0x80 + n % 64)
    end
    if n < 0x10000 then
        return string.char(
            0xE0 + math.floor(n / 4096),
            0x80 + math.floor(n / 64) % 64,
            0x80 + n % 64
        )
    end
    return string.char(
        0xF0 + math.floor(n / 262144),
        0x80 + math.floor(n / 4096) % 64,
        0x80 + math.floor(n / 64) % 64,
        0x80 + n % 64
    )
end

--- 解码常见命名实体与十/十六进制数字实体；只解一轮，避免 &amp;lt; 变成可执行标签。
---@param text string|nil
---@return string
function Markdown.decodeEntities(text)
    if type(text) ~= "string" or text == "" then return text or "" end
    text = text:gsub("&#[xX](%x+);", function(h)
        return utf8char(tonumber(h, 16)) or ("&#x" .. h .. ";")
    end)
    text = text:gsub("&#(%d+);", function(d)
        return utf8char(tonumber(d, 10)) or ("&#" .. d .. ";")
    end)
    text = text:gsub("&([A-Za-z][A-Za-z0-9]+);", function(name)
        return NAMED_ENTITIES[name:lower()] or ("&" .. name .. ";")
    end)
    return text
end

local function protect(list, html)
    list[#list + 1] = html
    return "\1MD" .. #list .. "\2"
end

local function restore(text, list)
    local prev
    -- 槽位可能嵌套替换，多轮直到稳定。
    while text ~= prev do
        prev = text
        text = text:gsub("\1MD(%d+)\2", function(i)
            return list[tonumber(i)] or ""
        end)
    end
    return text
end

--- 仓库内 README 的官方 blob 基址（不是镜像）。仅 GitHub 拼官方 github.com。
---@param plugin table|nil
---@return string|nil
function Markdown.linkBase(plugin)
    if type(plugin) ~= "table" then return nil end
    if plugin.type ~= "github" then return nil end
    local owner, repo = plugin.owner, plugin.repo
    if type(owner) ~= "string" or owner == "" or type(repo) ~= "string" or repo == "" then
        return nil
    end
    local ref = plugin.default_branch or plugin.ref or "HEAD"
    if type(ref) ~= "string" or ref == "" then ref = "HEAD" end
    return "https://github.com/" .. owner .. "/" .. repo .. "/blob/" .. ref .. "/"
end

--- 只允许明文网页、邮件，或在官方基址下解析出的 http(s) 相对路径。
---@param url string|nil
---@param opts { link_base?: string }|nil
---@return string|nil
function Markdown.safeHref(url, opts)
    if type(url) ~= "string" then return nil end
    url = url:match("^%s*(.-)%s*$") or ""
    if url == "" or url:find("%s") or url:find("[\r\n]") then return nil end
    local lower = url:lower()
    if lower:match("^javascript:") or lower:match("^data:") or lower:match("^vbscript:")
        or lower:match("^file:") or lower:match("^about:") then
        return nil
    end
    if lower:match("^https?://") or lower:match("^mailto:") then
        return url
    end
    local base = opts and opts.link_base
    if type(base) == "string" and base ~= "" and not lower:match("^%a[%w+.-]*:") then
        local abs = require("utils.text").absoluteUrl(base, url)
        if type(abs) == "string" and abs:lower():match("^https?://") then
            -- 相对路径只允许落到官方 github.com 仓库页，绝不改写到公共镜像。
            if abs:find("^https://github%.com/", 1) then
                return abs
            end
        end
    end
    return nil
end

local function attrValue(raw, kind, tag)
    if type(raw) ~= "string" then return nil end
    raw = Markdown.decodeEntities(raw):match("^%s*(.-)%s*$") or ""
    if raw == "" or raw:find("[\r\n]") then return nil end
    local lower = raw:lower()
    if kind == "align" then
        if ALIGN[lower] then return lower end
        return nil
    end
    if kind == "span" then
        local n = tonumber(raw)
        if n and n == math.floor(n) and n >= 1 and n <= 50 then
            return tostring(n)
        end
        return nil
    end
    if kind == "href" then
        if tag ~= "a" then return nil end
        return Markdown.safeHref(raw)
    end
    return nil
end

local function parseAttrs(raw, tag)
    local attrs, class = {}, nil
    if type(raw) ~= "string" then return attrs, class end
    for name, _q, val in raw:gmatch("([%w:-]+)%s*=%s*([\"'])(.-)%2") do
        local key = name:lower()
        if key:match("^on") or key == "style" or key == "src" or key == "srcset"
            or key == "poster" or key == "class" or key == "id" or key == "formaction" then
            -- drop
        elseif key == "align" then
            local align = attrValue(val, "align", tag)
            if align then
                attrs[#attrs + 1] = "align=\"" .. align .. "\""
                class = "md-align-" .. align
            end
        elseif key == "colspan" or key == "rowspan" then
            if tag == "td" or tag == "th" then
                local span = attrValue(val, "span", tag)
                if span then attrs[#attrs + 1] = key .. "=\"" .. span .. "\"" end
            end
        elseif key == "href" then
            local href = attrValue(val, "href", tag)
            if href then attrs[#attrs + 1] = "href=\"" .. esc(href) .. "\"" end
        end
    end
    return attrs, class
end

local function openTag(name, attr_raw, selfclose)
    if name == "img" then
        return nil, true
    end
    local attrs, class = parseAttrs(attr_raw, name)
    if class then
        attrs[#attrs + 1] = "class=\"" .. class .. "\""
    end
    if name == "table" then
        attrs[#attrs + 1] = "class=\"md-table" .. (class and (" " .. class) or "") .. "\""
        -- 上面可能重复 class，整理成一个。
        local cleaned, saw_class = {}, false
        for _idx, item in ipairs(attrs) do
            if item:find("^class=") then
                if not saw_class then
                    if class then
                        cleaned[#cleaned + 1] = "class=\"md-table " .. class .. "\""
                    else
                        cleaned[#cleaned + 1] = "class=\"md-table\""
                    end
                    saw_class = true
                end
            else
                cleaned[#cleaned + 1] = item
            end
        end
        attrs = cleaned
    end
    local extra = #attrs > 0 and (" " .. table.concat(attrs, " ")) or ""
    if selfclose or VOID_TAGS[name] then
        return "<" .. name .. extra .. "/>", true
    end
    return "<" .. name .. extra .. ">", false
end

local function skipToClose(source, start, name)
    local pattern = "</" .. name .. "%s*>"
    local s, e = source:find(pattern, start)
    if not s then return #source + 1 end
    return e + 1
end

--- 放行白名单 HTML，丢掉脚本与危险属性；img 变占位，不保留 src。
---@param source string
---@param slots table
---@return string
local function sanitizeHtml(source, slots)
    local i, n, out = 1, #source, {}
    while i <= n do
        local lt = source:find("<", i, true)
        if not lt then
            out[#out + 1] = source:sub(i)
            break
        end
        if lt > i then out[#out + 1] = source:sub(i, lt - 1) end
        if source:sub(lt, lt + 3) == "<!--" then
            local close = source:find("-->", lt + 4, true)
            i = close and (close + 3) or (n + 1)
        elseif source:sub(lt, lt + 1) == "<!" or source:sub(lt, lt + 1) == "<?" then
            local gt = source:find(">", lt + 2, true)
            i = gt and (gt + 1) or (n + 1)
        else
            local gt = source:find(">", lt + 1, true)
            if not gt then
                out[#out + 1] = esc(source:sub(lt))
                break
            end
            local raw = source:sub(lt + 1, gt - 1)
            local closing, name, rest = raw:match("^%s*(/?)%s*([%a][%w:]*)(.*)$")
            if not name then
                out[#out + 1] = esc(source:sub(lt, gt))
                i = gt + 1
            else
                name = name:lower()
                if DROP_INNER[name] then
                    if closing == "/" then
                        i = gt + 1
                    else
                        i = skipToClose(source, gt + 1, name)
                    end
                    -- 保留转义后的标签痕迹，便于对照，但不执行。
                    out[#out + 1] = esc("<" .. (closing == "/" and "/" or "") .. name .. ">")
                elseif not ALLOW_TAGS[name] then
                    out[#out + 1] = esc(source:sub(lt, gt))
                    i = gt + 1
                else
                    local selfclose = rest:match("/%s*$") ~= nil
                    rest = rest:gsub("/%s*$", "")
                    if closing == "/" then
                        if not VOID_TAGS[name] then
                            out[#out + 1] = protect(slots, "</" .. name .. ">")
                        end
                        i = gt + 1
                    elseif name == "img" then
                        local alt = rest:match("[Aa][Ll][Tt]%s*=%s*[\"'](.-)[\"']") or "image"
                        out[#out + 1] = protect(slots, "<span>［图片：" .. esc(Markdown.decodeEntities(alt)) .. "］</span>")
                        i = gt + 1
                    else
                        local html, voided = openTag(name, rest, selfclose)
                        if html then out[#out + 1] = protect(slots, html) end
                        i = gt + 1
                        if voided then -- already consumed
                        end
                    end
                end
            end
        end
    end
    return table.concat(out)
end

local function splitRow(line)
    local s = line:match("^%s*(.-)%s*$") or line
    if s:sub(1, 1) == "|" then s = s:sub(2) end
    if s:sub(-1) == "|" then s = s:sub(1, -2) end
    local cells, buf, i = {}, "", 1
    while i <= #s do
        local c = s:sub(i, i)
        if c == "\\" and s:sub(i + 1, i + 1) == "|" then
            buf = buf .. "|"
            i = i + 2
        elseif c == "|" then
            cells[#cells + 1] = buf
            buf = ""
            i = i + 1
        else
            buf = buf .. c
            i = i + 1
        end
    end
    cells[#cells + 1] = buf
    for idx, cell in ipairs(cells) do
        cells[idx] = cell:match("^%s*(.-)%s*$") or cell
    end
    return cells
end

local function isSepRow(line)
    if not line or not line:find("|", 1, true) then return false end
    local cells = splitRow(line)
    if #cells == 0 then return false end
    for _idx, cell in ipairs(cells) do
        if not cell:match("^:?%-+:?$") then return false end
    end
    return true
end

local function alignOf(cell)
    local left = cell:sub(1, 1) == ":"
    local right = cell:sub(-1) == ":"
    if left and right then return "center" end
    if right then return "right" end
    if left then return "left" end
    return nil
end

local function inline(text, slots, opts)
    text = Markdown.decodeEntities(text)
    -- 链接/图片按括号深度配对，避免 javascript:alert(1) 在第一个 ) 处被截断。
    local function takeLinks(s, image)
        local i, n, out = 1, #s, {}
        while i <= n do
            local start
            if image then
                start = s:find("![", i, true)
            else
                start = s:find("[", i, true)
                if start and s:sub(start - 1, start) == "![" then
                    -- 留给图片处理；这里把 ! 前面的文本留下，从 [ 再往后。
                    out[#out + 1] = s:sub(i, start - 1)
                    i = start + 1
                    start = nil
                end
            end
            if not start then
                out[#out + 1] = s:sub(i)
                break
            end
            local label_s = image and (start + 2) or (start + 1)
            local label_e = s:find("]", label_s, true)
            if not label_e or s:sub(label_e + 1, label_e + 1) ~= "(" then
                out[#out + 1] = s:sub(i, start)
                i = start + 1
            else
                local depth, j, url_s = 1, label_e + 2, label_e + 2
                while j <= n and depth > 0 do
                    local ch = s:sub(j, j)
                    if ch == "(" then
                        depth = depth + 1
                    elseif ch == ")" then
                        depth = depth - 1
                    end
                    j = j + 1
                end
                if depth ~= 0 then
                    out[#out + 1] = s:sub(i, start)
                    i = start + 1
                else
                    out[#out + 1] = s:sub(i, start - 1)
                    local label = s:sub(label_s, label_e - 1)
                    local url = s:sub(url_s, j - 2)
                    if image then
                        local alt = label ~= "" and label or "image"
                        out[#out + 1] = protect(slots, "<span>［图片：" .. esc(alt) .. "］</span>")
                    else
                        local href = Markdown.safeHref(url, opts)
                        if href then
                            out[#out + 1] = protect(slots, "<a href=\"" .. esc(href) .. "\">" .. esc(label) .. "</a>")
                        else
                            out[#out + 1] = esc(label)
                        end
                    end
                    i = j
                end
            end
        end
        return table.concat(out)
    end
    text = takeLinks(text, true)
    text = takeLinks(text, false)
    text = text:gsub("%*%*(.-)%*%*", function(body)
        return protect(slots, "<strong>" .. esc(body) .. "</strong>")
    end)
    text = text:gsub("__(.-)__", function(body)
        return protect(slots, "<strong>" .. esc(body) .. "</strong>")
    end)
    text = text:gsub("%*(.-)%*", function(body)
        return protect(slots, "<em>" .. esc(body) .. "</em>")
    end)
    text = text:gsub("_(.-)_", function(body)
        return protect(slots, "<em>" .. esc(body) .. "</em>")
    end)
    return esc(text)
end

---@param source string|nil
---@param opts { link_base?: string }|nil
---@return string
function Markdown.toHtml(source, opts)
    if type(source) ~= "string" or source == "" then
        return ""
    end
    opts = opts or {}
    source = source:gsub("\r\n", "\n"):gsub("\r", "\n")
    local slots = {}
    source = source:gsub("```[%w%-%_]*\n(.-)\n```", function(code)
        return protect(slots, "<pre><code>" .. esc(code) .. "</code></pre>")
    end)
    source = source:gsub("```[%w%-%_]*\n?(.-)```", function(code)
        return protect(slots, "<pre><code>" .. esc(code) .. "</code></pre>")
    end)
    source = source:gsub("`([^`]+)`", function(code)
        return protect(slots, "<code>" .. esc(code) .. "</code>")
    end)
    source = sanitizeHtml(source, slots)

    local lines, out, para, list, quote = {}, {}, {}, nil, false
    for line in (source .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end
    local function flush_para()
        if #para == 0 then return end
        local body = table.concat(para, " ")
        local raw_html = restore(body, slots)
        -- 已是块级 HTML（<p align>、<table> 等）不再外包一层 p。
        local tag = raw_html:match("^%s*<%s*([%a%d]+)")
        tag = tag and tag:lower() or ""
        local block = {
            p = true, div = true, table = true, thead = true, tbody = true, tr = true,
            pre = true, ul = true, ol = true, blockquote = true, hr = true,
            h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true,
        }
        if block[tag] then
            out[#out + 1] = restore(inline(body, slots, opts), slots)
        else
            out[#out + 1] = "<p>" .. restore(inline(body, slots, opts), slots) .. "</p>"
        end
        para = {}
    end
    local function flush_list()
        if not list then return end
        out[#out + 1] = list.close
        list = nil
    end
    local function flush_quote()
        if not quote then return end
        out[#out + 1] = "</blockquote>"
        quote = false
    end
    local function flush_all()
        flush_para()
        flush_list()
        flush_quote()
    end
    local function emitCell(tag, text, align)
        local cls = align and (' class="md-align-' .. align .. '" align="' .. align .. '"') or ""
        return "<" .. tag .. cls .. ">" .. restore(inline(text, slots, opts), slots) .. "</" .. tag .. ">"
    end
    local idx = 1
    while idx <= #lines do
        local raw = lines[idx]
        local line = raw:match("^(.-)%s*$") or raw
        local fence = line:match("^\1MD(%d+)\2$")
        local next_line = lines[idx + 1]
        if fence then
            flush_all()
            out[#out + 1] = slots[tonumber(fence)] or ""
            idx = idx + 1
        elseif line:find("|", 1, true) and isSepRow(next_line) then
            flush_all()
            local headers = splitRow(line)
            local aligns = {}
            for aidx, cell in ipairs(splitRow(next_line)) do
                aligns[aidx] = alignOf(cell)
            end
            local body = {}
            local row_i = idx + 2
            while row_i <= #lines do
                local r = lines[row_i]:match("^(.-)%s*$") or lines[row_i]
                if r:match("^%s*$") or not r:find("|", 1, true) or isSepRow(r) then break end
                body[#body + 1] = splitRow(r)
                row_i = row_i + 1
            end
            local parts = { "<table class=\"md-table\"><thead><tr>" }
            for c, text in ipairs(headers) do
                parts[#parts + 1] = emitCell("th", text, aligns[c])
            end
            parts[#parts + 1] = "</tr></thead><tbody>"
            for _r, row in ipairs(body) do
                parts[#parts + 1] = "<tr>"
                for c, text in ipairs(row) do
                    parts[#parts + 1] = emitCell("td", text, aligns[c])
                end
                parts[#parts + 1] = "</tr>"
            end
            parts[#parts + 1] = "</tbody></table>"
            out[#out + 1] = table.concat(parts)
            idx = row_i
        elseif line:match("^%s*$") then
            flush_all()
            idx = idx + 1
        elseif line:match("^%s*([%-%*_])%1%1%s*$") then
            flush_all()
            out[#out + 1] = "<hr/>"
            idx = idx + 1
        elseif line:match("^#+%s+") then
            flush_all()
            local hashes, title = line:match("^(#+)%s+(.-)%s*$")
            local level = math.min(6, #hashes)
            if level < 1 then level = 1 end
            out[#out + 1] = "<h" .. level .. ">" .. restore(inline(title, slots, opts), slots) .. "</h" .. level .. ">"
            idx = idx + 1
        elseif line:match("^>%s?") then
            flush_para()
            flush_list()
            if not quote then
                out[#out + 1] = "<blockquote>"
                quote = true
            end
            local body = line:gsub("^>%s?", "")
            out[#out + 1] = "<p>" .. restore(inline(body, slots, opts), slots) .. "</p>"
            idx = idx + 1
        elseif line:match("^%s*[-*+]%s+") or line:match("^%s*%d+%.%s+") then
            flush_para()
            flush_quote()
            local ordered = line:match("^%s*%d+%.%s+") ~= nil
            local item = line:gsub("^%s*[-*+]%s+", ""):gsub("^%s*%d+%.%s+", "")
            local want = ordered and "ol" or "ul"
            if not list or list.tag ~= want then
                flush_list()
                out[#out + 1] = "<" .. want .. ">"
                list = { tag = want, close = "</" .. want .. ">" }
            end
            out[#out + 1] = "<li>" .. restore(inline(item, slots, opts), slots) .. "</li>"
            idx = idx + 1
        else
            flush_list()
            flush_quote()
            para[#para + 1] = line
            idx = idx + 1
        end
    end
    flush_all()
    return restore(table.concat(out), slots)
end

return Markdown
