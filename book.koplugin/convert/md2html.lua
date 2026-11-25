--[[--
通用 Markdown → 安全 HTML 转换器（不渲染图片）。

两段式流水线：
1. 解析层：优先调用 KOReader 内置 C 库 md4c（libkoreader-cre.so 导出的 md_html，
   支持 CommonMark + GFM 表格/删除线/自动链接）；运行环境没有该符号时自动退回零依赖纯 Lua 解析器。
2. 净化层：单趟 O(N) HTML 白名单过滤（常见裸标签走 O(1) 查表快路径），两套引擎共享同一安全契约：
   - 不渲染图片：剥离全部 <img> 与 src/srcset，有 alt 时输出纯文本占位「［图片：…］」，无 alt 直接省略。
   - 丢弃 script/style/iframe 等危险标签及其内容，剥离 on*/style/formaction 等属性。
   - 链接仅放行 http(s) / mailto，或与给定 http(s) link_base 同源的相对路径；非法链接剥去 <a> 保留文字。

@module koplugin.book.convert.md2html
--]]

local Text = require("utils.text")

local Md2Html = {}

local xmlEscape = Text.xmlEscape
local xmlDecode = Text.xmlDecode

--- 交给 HtmlBox 的默认表格与对齐样式。
Md2Html.CSS = [[
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
    a = true, span = true, sup = true, sub = true,
}

local VOID_TAGS = { br = true, hr = true }

local DROP_INNER = {
    script = true, style = true, iframe = true, object = true, embed = true,
    svg = true, form = true, input = true, textarea = true, button = true,
    link = true, meta = true, base = true, applet = true, frame = true,
    frameset = true, video = true, audio = true, source = true, canvas = true,
}

local BLOCK_HTML_TAGS = {
    p = true, div = true, table = true, thead = true, tbody = true, tfoot = true,
    tr = true, pre = true, ul = true, ol = true, blockquote = true, hr = true,
    h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true,
    script = true, style = true,
}

local ALIGN = { left = true, center = true, right = true, justify = true }

-- 净化快路径：不涉及 a_stack / code_depth 的常见裸标签与表格对齐单元格，O(1) 查表零正则零分配。
local FAST_TAGS = {
    ["table"] = '<table class="md-table">',
    ["/table"] = "</table>",
    ["br"] = "<br/>", ["br/"] = "<br/>", ["br /"] = "<br/>",
    ["hr"] = "<hr/>", ["hr/"] = "<hr/>", ["hr /"] = "<hr/>",
}
for tag in pairs(ALLOW_TAGS) do
    if tag ~= "a" and tag ~= "code" and tag ~= "pre" and tag ~= "table" and not VOID_TAGS[tag] then
        FAST_TAGS[tag] = "<" .. tag .. ">"
        FAST_TAGS["/" .. tag] = "</" .. tag .. ">"
    end
end
for align in pairs(ALIGN) do
    FAST_TAGS['th align="' .. align .. '"'] = '<th align="' .. align .. '" class="md-align-' .. align .. '">'
    FAST_TAGS['td align="' .. align .. '"'] = '<td align="' .. align .. '" class="md-align-' .. align .. '">'
end

------------------------------------------------------------------------
-- 链接安全校验
------------------------------------------------------------------------

---@param url string
---@return string|nil
local function httpOrigin(url)
    local scheme, host = url:match("^([Hh][Tt][Tt][Pp][Ss]?)://([^/?#]+)")
    if not scheme or host == "" then return nil end
    return scheme:lower() .. "://" .. host:lower() .. "/"
end

--- 只放行明文 http(s) / mailto，或在给定 http(s) link_base 同源下解析出的相对路径。
---@param url string|nil
---@param opts { link_base?: string }|nil
---@return string|nil
function Md2Html.safeHref(url, opts)
    if type(url) ~= "string" then return nil end
    url = url:match("^%s*(.-)%s*$") or ""
    if url == "" or url:find("%s") or url:find("[\r\n]") then return nil end
    local lower = url:lower()
    if lower:match("^https?://") or lower:match("^mailto:") then
        return url
    end
    if lower:match("^%a[%w+.-]*:") or url:sub(1, 2) == "//" then
        return nil
    end
    local base = opts and opts.link_base
    local base_origin = type(base) == "string" and httpOrigin(base) or nil
    if not base_origin then return nil end
    local abs = Text.absoluteUrl(base, url)
    if type(abs) == "string" and httpOrigin(abs) == base_origin then
        return abs
    end
    return nil
end

------------------------------------------------------------------------
-- 引擎一：KOReader 内置 C 库 md4c（libkoreader-cre.so）
------------------------------------------------------------------------

-- md4c.h: PERMISSIVEAUTOLINKS(0x04|0x08|0x400) | TABLES(0x100) | STRIKETHROUGH(0x200)
-- 不开 TASKLISTS(0x800)，避免 <input type="checkbox"> 被安全策略拦截。
local MD4C_PARSER_FLAGS = 0x070C
-- md4c-html.h: SKIP_UTF8_BOM(0x04) | XHTML(0x08)
local MD4C_RENDER_FLAGS = 0x000C

local md4c_probed = false
local md4c_lib = nil
local md4c_cb = nil
local md4c_buf = nil

local function loadMd4c()
    if md4c_probed then return md4c_lib end
    md4c_probed = true
    local ffi_ok, ffi = pcall(require, "ffi")
    if not ffi_ok or not ffi then return nil end
    pcall(ffi.cdef, [[
        int md_html(const char* input, unsigned input_size,
            void (*process_output)(const char*, unsigned, void*),
            void* userdata, unsigned parser_flags, unsigned renderer_flags);
    ]])
    for _i, target in ipairs({ ffi.C, "libs/libkoreader-cre.so", "libkoreader-cre.so" }) do
        local lib = type(target) == "string" and select(2, pcall(ffi.load, target)) or target
        if type(lib) == "userdata" and pcall(function() return lib.md_html end) then
            md4c_lib = lib
            -- 复用单个模块级回调，避免每次转换消耗 LuaJIT 有限的 FFI callback 槽位。
            md4c_cb = ffi.cast("void (*)(const char*, unsigned, void*)", function(ptr, size)
                if md4c_buf and size > 0 then
                    md4c_buf[#md4c_buf + 1] = ffi.string(ptr, size)
                end
            end)
            return md4c_lib
        end
    end
    return nil
end

---@param source string
---@return string|nil
local function md4cToHtml(source)
    local lib = loadMd4c()
    if not lib then return nil end
    local buf = {}
    md4c_buf = buf
    local rc = lib.md_html(source, #source, md4c_cb, nil, MD4C_PARSER_FLAGS, MD4C_RENDER_FLAGS)
    md4c_buf = nil
    if rc ~= 0 then return nil end
    return table.concat(buf)
end

--- 当前默认使用的 Markdown 解析引擎："md4c" 或 "lua"。
---@return "md4c"|"lua"
function Md2Html.engine()
    return loadMd4c() and "md4c" or "lua"
end

------------------------------------------------------------------------
-- 引擎二：纯 Lua 兜底解析器（无 md4c 符号时使用）
------------------------------------------------------------------------

local function protect(slots, html)
    slots[#slots + 1] = html
    return "\1MD" .. #slots .. "\2"
end

local function restore(text, slots)
    if #slots == 0 or not text:find("\1MD", 1, true) then return text end
    local count
    repeat
        text, count = text:gsub("\1MD(%d+)\2", function(i) return slots[tonumber(i)] or "" end)
    until count == 0
    return text
end

--- 按括号深度扫描 Markdown 图片/链接（避免 javascript:alert(1) 在首个 ) 处截断）。
local function scanLinks(s, image, slots)
    local needle = image and "![" or "["
    if not s:find(needle, 1, true) then return s end
    local i, n, out = 1, #s, {}
    while i <= n do
        local start = s:find(needle, i, true)
        if not start then
            out[#out + 1] = s:sub(i)
            break
        end
        local label_s = start + #needle
        local label_e = (image or start == 1 or s:sub(start - 1, start - 1) ~= "!")
            and s:find("]", label_s, true) or nil
        if not label_e or s:sub(label_e + 1, label_e + 1) ~= "(" then
            out[#out + 1] = s:sub(i, start)
            i = start + 1
        else
            local depth, j = 1, label_e + 2
            while j <= n and depth > 0 do
                local ch = s:byte(j)
                if ch == 40 then depth = depth + 1 elseif ch == 41 then depth = depth - 1 end
                j = j + 1
            end
            if depth ~= 0 then
                out[#out + 1] = s:sub(i, start)
                i = start + 1
            else
                out[#out + 1] = s:sub(i, start - 1)
                local label = s:sub(label_s, label_e - 1)
                local url = s:sub(label_e + 2, j - 2)
                out[#out + 1] = protect(slots, image
                    and ('<img alt="' .. xmlEscape(label) .. '"/>')
                    or ('<a href="' .. xmlEscape(url) .. '">' .. label .. "</a>"))
                i = j
            end
        end
    end
    return table.concat(out)
end

local function renderInline(text)
    local slots = {}
    if text:find("`", 1, true) then
        text = text:gsub("`([^`\n]+)`", function(code)
            return protect(slots, "<code>" .. xmlEscape(code) .. "</code>")
        end)
    end
    text = scanLinks(scanLinks(text, true, slots), false, slots)
    if text:find("<", 1, true) then
        text = text:gsub("(<[%/?%!%a][^>\n]*>)", function(tag) return protect(slots, tag) end)
    end
    text = text:gsub("~~(.-)~~", "<del>%1</del>")
        :gsub("%*%*(.-)%*%*", "<strong>%1</strong>")
        :gsub("__(.-)__", "<strong>%1</strong>")
        :gsub("%*(.-)%*", "<em>%1</em>")
        :gsub("_(.-)_", "<em>%1</em>")
    return restore(text, slots)
end

local function splitTableRow(line)
    local s = (line:match("^%s*(.-)%s*$") or line):gsub("^|", ""):gsub("|$", "")
    local cells, buf, i, n = {}, {}, 1, #s
    while i <= n do
        local b = s:byte(i)
        if b == 92 and s:byte(i + 1) == 124 then
            buf[#buf + 1], i = "|", i + 2
        elseif b == 124 then
            cells[#cells + 1] = (table.concat(buf):match("^%s*(.-)%s*$"))
            buf, i = {}, i + 1
        else
            buf[#buf + 1], i = s:sub(i, i), i + 1
        end
    end
    cells[#cells + 1] = (table.concat(buf):match("^%s*(.-)%s*$"))
    return cells
end

local function tableAligns(line)
    if not line or not line:find("|", 1, true) then return nil end
    local cells = splitTableRow(line)
    if #cells == 0 then return nil end
    local aligns = {}
    for i, cell in ipairs(cells) do
        if not cell:match("^:?%-+:?$") then return nil end
        local l, r = cell:byte(1) == 58, cell:byte(#cell) == 58
        aligns[i] = (l and r and "center") or (r and "right") or (l and "left") or nil
    end
    return aligns
end

---@param source string
---@return string
local function luaToHtml(source)
    source = Text.normalizeNewlines(source)
    local lines, out, para, list, quote = {}, {}, {}, nil, false
    for line in (source .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    local function flush(keep_list, keep_quote)
        if #para > 0 then
            local body = table.concat(para, "\n")
            local lead = body:match("^%s*<%s*([%a%d]+)")
            out[#out + 1] = (lead and BLOCK_HTML_TAGS[lead:lower()])
                and renderInline(body)
                or ("<p>" .. renderInline(table.concat(para, " ")) .. "</p>")
            para = {}
        end
        if not keep_list and list then
            out[#out + 1] = "</" .. list .. ">"
            list = nil
        end
        if not keep_quote and quote then
            out[#out + 1] = "</blockquote>"
            quote = false
        end
    end
    local idx = 1
    while idx <= #lines do
        local line = lines[idx]:match("^(.-)%s*$") or lines[idx]
        local fence = line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
        local aligns = not fence and line:find("|", 1, true) and tableAligns(lines[idx + 1]) or nil
        if fence then
            flush()
            local code = {}
            idx = idx + 1
            while idx <= #lines do
                if lines[idx]:match("^%s*" .. fence .. "%s*$") then
                    idx = idx + 1
                    break
                end
                code[#code + 1] = lines[idx]
                idx = idx + 1
            end
            out[#out + 1] = "<pre><code>" .. xmlEscape(table.concat(code, "\n")) .. "</code></pre>"
        elseif aligns then
            flush()
            local parts = { "<table><thead><tr>" }
            for c, cell in ipairs(splitTableRow(line)) do
                local attr = aligns[c] and (' align="' .. aligns[c] .. '"') or ""
                parts[#parts + 1] = "<th" .. attr .. ">" .. renderInline(cell) .. "</th>"
            end
            parts[#parts + 1] = "</tr></thead><tbody>"
            local row_i = idx + 2
            while row_i <= #lines do
                local r = lines[row_i]:match("^(.-)%s*$") or lines[row_i]
                if r:match("^%s*$") or not r:find("|", 1, true) or tableAligns(r) then break end
                parts[#parts + 1] = "<tr>"
                for c, cell in ipairs(splitTableRow(r)) do
                    local attr = aligns[c] and (' align="' .. aligns[c] .. '"') or ""
                    parts[#parts + 1] = "<td" .. attr .. ">" .. renderInline(cell) .. "</td>"
                end
                parts[#parts + 1] = "</tr>"
                row_i = row_i + 1
            end
            parts[#parts + 1] = "</tbody></table>"
            out[#out + 1] = table.concat(parts)
            idx = row_i
        elseif line:match("^%s*$") then
            flush()
            idx = idx + 1
        elseif line:match("^%s*([%-%*_])%1%1+%s*$") then
            flush()
            out[#out + 1] = "<hr/>"
            idx = idx + 1
        elseif line:match("^#+%s+") then
            flush()
            local hashes, title = line:match("^(#+)%s+(.-)%s*$")
            local lv = math.min(6, math.max(1, #hashes))
            out[#out + 1] = "<h" .. lv .. ">" .. renderInline(title) .. "</h" .. lv .. ">"
            idx = idx + 1
        elseif line:match("^>%s?") then
            flush(false, true)
            if not quote then
                out[#out + 1] = "<blockquote>"
                quote = true
            end
            out[#out + 1] = "<p>" .. renderInline((line:gsub("^>%s?", ""))) .. "</p>"
            idx = idx + 1
        elseif line:match("^%s*[-*+]%s+") or line:match("^%s*%d+%.%s+") then
            flush(true, false)
            local want = line:match("^%s*%d+%.%s+") and "ol" or "ul"
            if list ~= want then
                if list then out[#out + 1] = "</" .. list .. ">" end
                out[#out + 1] = "<" .. want .. ">"
                list = want
            end
            local item = line:gsub("^%s*[-*+]%s+", ""):gsub("^%s*%d+%.%s+", "")
            out[#out + 1] = "<li>" .. renderInline(item) .. "</li>"
            idx = idx + 1
        else
            if list then out[#out + 1] = "</" .. list .. ">"; list = nil end
            if quote then out[#out + 1] = "</blockquote>"; quote = false end
            para[#para + 1] = line
            idx = idx + 1
        end
    end
    flush()
    return table.concat(out, "\n")
end

------------------------------------------------------------------------
-- 共享单趟 O(N) HTML 安全净化与图片剥离
------------------------------------------------------------------------

local function decodeNonAsciiNumeric(chunk)
    return (chunk:gsub("&#([xX]?)(%x+);", function(hex, digits)
        local cp = tonumber(digits, hex ~= "" and 16 or 10)
        -- 仅解码非 ASCII 码点（如 &#x4e2d; → 中），不解 ASCII 以防 &#60; 变成原生标签。
        if not cp or cp < 0x80 or cp > 0x10FFFF then return nil end
        local ch = Text.utf8char(cp)
        return ch ~= "" and ch or nil
    end))
end

local function decodeIfEntity(s)
    return s:find("&", 1, true) and xmlDecode(s) or s
end

local function extractAlt(raw)
    for name, _q, val in raw:gmatch("([%w:-]+)%s*=%s*([\"'])(.-)%2") do
        if name:lower() == "alt" then
            return (decodeIfEntity(val):match("^%s*(.-)%s*$")) or ""
        end
    end
    return ""
end

local function buildOpenTag(name, attr_raw, selfclose, opts)
    local attrs, align_cls, has_href = {}, nil, false
    if attr_raw ~= "" then
        for k, _q, val in attr_raw:gmatch("([%w:-]+)%s*=%s*([\"'])(.-)%2") do
            local key = k:lower()
            if key == "align" then
                local a = (decodeIfEntity(val):match("^%s*(.-)%s*$") or ""):lower()
                if ALIGN[a] then
                    attrs[#attrs + 1] = 'align="' .. a .. '"'
                    align_cls = "md-align-" .. a
                end
            elseif (key == "colspan" or key == "rowspan") and (name == "td" or name == "th") then
                local n = tonumber((decodeIfEntity(val):match("^%s*(.-)%s*$")))
                if n and n == math.floor(n) and n >= 1 and n <= 50 then
                    attrs[#attrs + 1] = key .. '="' .. tostring(n) .. '"'
                end
            elseif key == "href" and name == "a" then
                local href = Md2Html.safeHref(decodeIfEntity(val), opts)
                if href then
                    attrs[#attrs + 1] = 'href="' .. xmlEscape(href) .. '"'
                    has_href = true
                end
            end
        end
    end
    if name == "a" and not has_href then return nil end
    local cls = name == "table"
        and (align_cls and ("md-table " .. align_cls) or "md-table")
        or align_cls
    if cls then attrs[#attrs + 1] = 'class="' .. cls .. '"' end
    local extra = #attrs > 0 and (" " .. table.concat(attrs, " ")) or ""
    return "<" .. name .. extra .. ((selfclose or VOID_TAGS[name]) and "/>" or ">")
end

---@param html string
---@param opts { link_base?: string }|nil
---@return string
local function sanitizeHtml(html, opts)
    local i, n, out = 1, #html, {}
    local lower_html, code_depth, a_stack = nil, 0, {}
    while i <= n do
        local lt = html:find("<", i, true)
        if not lt then
            local tail = html:sub(i)
            out[#out + 1] = (code_depth == 0 and tail:find("&#", 1, true)) and decodeNonAsciiNumeric(tail) or tail
            break
        end
        if lt > i then
            local chunk = html:sub(i, lt - 1)
            out[#out + 1] = (code_depth == 0 and chunk:find("&#", 1, true)) and decodeNonAsciiNumeric(chunk) or chunk
        end
        local b2 = html:byte(lt + 1)
        if b2 == 33 and html:sub(lt, lt + 3) == "<!--" then
            local close = html:find("-->", lt + 4, true)
            i = close and (close + 3) or (n + 1)
        elseif b2 == 33 or b2 == 63 then
            local gt = html:find(">", lt + 2, true)
            i = gt and (gt + 1) or (n + 1)
        else
            local gt = html:find(">", lt + 1, true)
            if not gt then
                out[#out + 1] = xmlEscape(html:sub(lt))
                break
            end
            local raw = html:sub(lt + 1, gt - 1)
            local fast = FAST_TAGS[raw]
            if fast then
                out[#out + 1] = fast
                i = gt + 1
            elseif raw == "code" or raw == "pre" then
                code_depth = code_depth + 1
                out[#out + 1] = "<" .. raw .. ">"
                i = gt + 1
            elseif raw == "/code" or raw == "/pre" then
                if code_depth > 0 then code_depth = code_depth - 1 end
                out[#out + 1] = "<" .. raw .. ">"
                i = gt + 1
            elseif raw == "/a" then
                local kept = a_stack[#a_stack]
                a_stack[#a_stack] = nil
                if kept then out[#out + 1] = "</a>" end
                i = gt + 1
            else
                local closing, name, rest = raw:match("^%s*(/?)%s*([%a][%w:]*)(.*)$")
                if not name then
                    out[#out + 1] = xmlEscape(html:sub(lt, gt))
                    i = gt + 1
                else
                    name = name:lower()
                    if DROP_INNER[name] then
                        if closing == "/" then
                            i = gt + 1
                        else
                            lower_html = lower_html or html:lower()
                            local _s, e = lower_html:find("</" .. name .. "%s*>", gt + 1)
                            i = e and (e + 1) or (n + 1)
                        end
                        out[#out + 1] = xmlEscape("<" .. (closing == "/" and "/" or "") .. name .. ">")
                    elseif name == "img" then
                        if closing ~= "/" then
                            local alt = extractAlt(rest)
                            if alt ~= "" then
                                out[#out + 1] = "<span>［图片：" .. xmlEscape(alt) .. "］</span>"
                            end
                        end
                        i = gt + 1
                    elseif not ALLOW_TAGS[name] then
                        out[#out + 1] = xmlEscape(html:sub(lt, gt))
                        i = gt + 1
                    elseif closing == "/" then
                        if name == "a" then
                            local kept = a_stack[#a_stack]
                            a_stack[#a_stack] = nil
                            if kept then out[#out + 1] = "</a>" end
                        elseif not VOID_TAGS[name] then
                            if (name == "code" or name == "pre") and code_depth > 0 then
                                code_depth = code_depth - 1
                            end
                            out[#out + 1] = "</" .. name .. ">"
                        end
                        i = gt + 1
                    else
                        local selfclose = rest:match("/%s*$") ~= nil
                        if selfclose then rest = rest:gsub("/%s*$", "") end
                        local tag = buildOpenTag(name, rest, selfclose, opts)
                        if name == "a" then
                            a_stack[#a_stack + 1] = tag ~= nil
                        elseif not selfclose and (name == "code" or name == "pre") then
                            code_depth = code_depth + 1
                        end
                        if tag then out[#out + 1] = tag end
                        i = gt + 1
                    end
                end
            end
        end
    end
    return table.concat(out)
end

--- Markdown 源码 → 安全 HTML（不渲染图片）。
---@param source string|nil
---@param opts { link_base?: string, engine?: "md4c"|"lua" }|nil
---@return string
function Md2Html.toHtml(source, opts)
    if type(source) ~= "string" or source == "" then
        return ""
    end
    opts = opts or {}
    local raw = opts.engine ~= "lua" and md4cToHtml(source) or nil
    if not raw then
        raw = luaToHtml(source)
    end
    return sanitizeHtml(raw, opts)
end

return Md2Html
