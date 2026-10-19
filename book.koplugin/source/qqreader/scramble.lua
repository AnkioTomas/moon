--[[--
QQ阅读正文乱序还原：Fock 解出的是带反爬样式的 HTML，真正的字序和字形要靠随章下发的 CSS 才能还原。

- 有 `pN` 类的段落，子元素 `<yXX>` 按 `yXX{order:n}` 重排（网页是 flex 容器），每个元素再按
  `.pN yXX::first-letter{font-size:0}`（藏掉原字）与 `::before` / `::after` 的 `content`（字面量或 `attr(x)`）还原；
- `<y class="sy-0">` 是 `font-size:0` 的占位，丢弃；`sy-1` 只是镜像显示，文字照留；
- 其余码位落在 CJK 扩展 A 的字，是 randomFont 画出来的真字，由 `glyph.lua` 认出，这里只负责替换。

@module source.qqreader.scramble
--]]--

local Glyph = require("source.qqreader.glyph")

local Scramble = {}

local CHAR = "[%z\1-\127\194-\244][\128-\191]*"

local UNKNOWN = "□"
local LOW, HIGH = 0x3400, 0x4DBF

local function expand(css)
    return (css:gsub("TS%-1", "transform:scaleX(-1)"):gsub("::B", "::before"):gsub("::A", "::after")
        :gsub("{O:", "{order:"):gsub("{C:", "{content:"):gsub("'''", "'\\''"))
end

--- content 值：'x' / "x" 字面量或 attr(name)。
local function contentOf(body, attrs)
    local value = body:match("content:%s*(.-)%s*;?%s*$")
    if not value then return nil end
    local name = value:match("^attr%(([%w_-]+)%)$")
    if name then return attrs[name] or "" end
    return value:match("^'(.*)'$") or value:match('^"(.*)"$') or ""
end

--- 解析 CSS：order[tag] 与 rules[class .. " " .. tag][self|first-letter|before|after] = body。
local function parse(css)
    local order, rules = {}, {}
    for sel, body in expand(css):gmatch("([^{}]+){([^}]*)}") do
        sel = sel:match("^%s*(.-)%s*$")
        local tag, n = sel:match("^(y[%w_-]*)$"), body:match("^order:(%d+)")
        if tag and n then
            order[tag] = tonumber(n)
        else
            local key, pseudo = sel:match("^%.(p%d+ y[%w_-]*)::([%a-]+)$")
            if not key then key, pseudo = sel:match("^%.(p%d+ y[%w_-]*)$"), "self" end
            if key then
                rules[key] = rules[key] or {}
                rules[key][pseudo] = body
            end
        end
    end
    return order, rules
end

local function attributes(raw)
    local attrs = {}
    for name, value in raw:gmatch('([%w_-]+)="([^"]*)"') do attrs[name] = value end
    return attrs
end

local function dropFirst(text)
    return (text:gsub("^" .. CHAR, "", 1))
end

local function unescape(text)
    return (text:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&amp;", "&"))
end

local function scrambled(cls, children, order, rules)
    for idx, child in ipairs(children) do child.idx = idx end
    table.sort(children, function(a, b)
        local oa, ob = order[a.tag] or math.huge, order[b.tag] or math.huge
        if oa ~= ob then return oa < ob end
        return a.idx < b.idx
    end)
    local out = {}
    for _idx, child in ipairs(children) do
        local rule = rules[cls .. " " .. child.tag] or {}
        local attrs = attributes(child.attrs)
        local text = child.text
        if rule["first-letter"] and rule["first-letter"]:find("font%-size:%s*0") then text = dropFirst(text) end
        out[#out + 1] = (rule.before and contentOf(rule.before, attrs) or "") .. text
            .. (rule.after and contentOf(rule.after, attrs) or "")
    end
    return table.concat(out)
end

--- 还原一章的段落文本（字形码位还没替换）。
---@param html string Fock 明文
---@param css string 章节下发的 CSS
---@return string[] paragraphs
function Scramble.paragraphs(html, css)
    local order, rules = parse(css)
    local paragraphs = {}
    for open, body in html:gmatch("<p([^>]*)>(.-)</p>") do
        local cls = open:match('class="(p%d+)"')
        local text
        if cls then
            local children = {}
            for tag, attrs, inner in body:gmatch("<(y[%w_-]*)([^>]*)>(.-)</%1>") do
                children[#children + 1] = { tag = tag, attrs = attrs, text = unescape(inner) }
            end
            text = scrambled(cls, children, order, rules)
        else
            text = body:gsub('<y class="sy%-0">.-</y>', ""):gsub("<[^>]+>", "")
            text = unescape(text)
        end
        if text ~= "" then paragraphs[#paragraphs + 1] = text end
    end
    return paragraphs
end

local function isRare(code)
    return (code >= LOW and code <= HIGH) or code == 0xF900
end

local function isHan(code)
    return code >= 0x4E00 and code <= 0x9FA5
end

--- 文本里要查字体的码位（去重）：rare 走 randomFont，han 走 fixedFont（该字体没有的码位原样保留）。
---@param paragraphs string[]
---@return integer[] rare
---@return integer[] han
function Scramble.codes(paragraphs)
    local seen, rare, han = {}, {}, {}
    for _idx, text in ipairs(paragraphs) do
        for ch in text:gmatch(CHAR) do
            local code = Glyph.codepoint(ch)
            if not seen[code] then
                seen[code] = true
                if isRare(code) then rare[#rare + 1] = code elseif isHan(code) then han[#han + 1] = code end
            end
        end
    end
    table.sort(rare)
    table.sort(han)
    return rare, han
end

--- 把码位换成真字，认不出的写 □；返回全文（段落以换行连接）。
---@param paragraphs string[]
---@param rare_map table<integer, string|false> randomFont 的识别结果
---@param han_map table<integer, string|false> fixedFont 的识别结果
---@return string
function Scramble.text(paragraphs, rare_map, han_map)
    local out = {}
    for idx, text in ipairs(paragraphs) do
        out[idx] = (text:gsub(CHAR, function(ch)
            local code = Glyph.codepoint(ch)
            local real
            if isRare(code) then real = rare_map[code] or false
            elseif isHan(code) then real = han_map[code]
            else return nil end
            if real == nil then return nil end
            return real or UNKNOWN
        end))
    end
    return table.concat(out, "\n")
end

return Scramble
