--[[--
微信读书 ``range`` ↔ 章节正文文本互转。

微信 ``range`` 是原始章节 HTML（含标签）上的 0-based 半开区间 rune 索引，
与 KOReader 章节壳注入的 ``<h1>`` 标题无关。定位划线一律用已解码的 ``markText``
在可见正文里匹配，``range`` 只用于重复文本消歧；不能按可见文本去切片 ``range``。

@module koplugin.book.source.wechat.annotations
--]]

local Annotations = {}
local Text = require("utils.text")

---@param str string
---@return string[]
local function toRunes(str)
    local runes, i, len = {}, 1, #str
    while i <= len do
        local byte = str:byte(i)
        local width = byte < 0x80 and 1 or byte < 0xe0 and 2 or byte < 0xf0 and 3 or 4
        runes[#runes + 1] = str:sub(i, i + width - 1)
        i = i + width
    end
    return runes
end

---@param range_str string
---@return integer|nil start 1-based inclusive
---@return integer|nil stop 1-based inclusive
local function parseRange(range_str)
    if type(range_str) ~= "string" then
        return nil
    end
    local a, b = range_str:match("^(%d+)%-(%d+)$")
    if not a then
        return nil
    end
    local start_pos = tonumber(a) + 1
    local end_exclusive = tonumber(b) + 1
    if not start_pos or not end_exclusive or end_exclusive <= start_pos then
        return nil
    end
    return start_pos, end_exclusive - 1
end

--- 跳过标签或取一个 UTF-8 rune。
---@param html string
---@param i integer
---@return string|nil kind '"tag"'|'"rune"'
---@return string chunk
---@return integer next_i
local function nextToken(html, i)
    local len = #html
    if i > len then
        return nil, "", i
    end
    if html:sub(i, i) == "<" then
        local close = html:find(">", i, true)
        if not close then
            return "rune", html:sub(i), i + 1
        end
        return "tag", html:sub(i, close), close + 1
    end
    local byte = html:byte(i)
    local width = byte < 0x80 and 1 or byte < 0xe0 and 2 or byte < 0xf0 and 3 or 4
    return "rune", html:sub(i, i + width - 1), i + width
end

-- 双引号/单引号两种 class 写法；不带属性的窄形式已被这两条覆盖，无需另列。
local UNDERLINE_PATTERNS = {
    '<span[^>]-class="[^"]-wr%-underline[^"]-"[^>]*>(.-)</span>',
    "<span[^>]-class='[^']-wr%-underline[^']-'[^>]*>(.-)</span>",
}

--- 移除 ``wr-underline`` 社区热度虚线（远端正文自带或旧版误注入）。
--- 绝大多数章节不含虚线，先用定长子串探一次，避免整章跑正则。
---@param html string
---@return string
function Annotations.stripInjected(html)
    if type(html) ~= "string" or not html:find("wr-underline", 1, true) then
        return html
    end
    html = html:gsub("<style>%s*%.wr%-underline[^<]*</style>", "")
    -- 嵌套虚线需要多轮：每轮剥掉一层，直到不再变化。
    local prev
    repeat
        prev = html
        for _, pat in ipairs(UNDERLINE_PATTERNS) do
            html = html:gsub(pat, "%1")
        end
    until html == prev
    return html
end

--- 清理微信章节正文：社区虚线、正文内重复的 ``<title>``（外层 ``write`` 已写 h1/title）。
---@param html string
---@return string
function Annotations.cleanChapterHtml(html)
    html = Annotations.stripInjected(html)
    if type(html) ~= "string" or html == "" then
        return html
    end
    html = html:gsub("<title[^>]*>.-</title>", "")
    return Text.trim(html)
end

--- 去掉 KOReader 章节壳里的 ``<h1>`` 标题，取可见正文的搜索范围。
---@param html string
---@return string
function Annotations.rangeHtml(html)
    if type(html) ~= "string" or html == "" then
        return html or ""
    end
    local body = html:match("<body[^>]*>(.*)</body>") or html
    return body:gsub("^%s*<h1[^>]*>.-</h1>%s*", "", 1)
end

--- 提取 HTML 可见文本 rune 序列（不含标签，非 ``range`` 的 HTML 坐标系）。
---@param html string
---@return string[]
function Annotations.plainRunes(html)
    local runes, i = {}, 1
    if type(html) ~= "string" or html == "" then
        return runes
    end
    while true do
        local kind, chunk, next_i = nextToken(html, i)
        if not kind then
            break
        end
        if kind == "rune" then
            runes[#runes + 1] = chunk
        end
        i = next_i
    end
    return runes
end

--- 可见正文 rune 序列（不含章节 ``<h1>``；用于本地文本匹配，不用于切片 ``range``）。
---@param html string
---@return string[]
function Annotations.plainBodyRunes(html)
    return Annotations.plainRunes(Annotations.rangeHtml(html))
end

--- 章节壳里的顶层段落文本，索引即 crengine xpointer 里的 ``p[N]``。
---
--- 文本按 crengine 规则折叠连续空白为单个空格且**不 trim**：微信正文段首带缩进空格，
--- 折叠后仍占 1 个字符，这正是本地划线 ``pos0`` 从 1 而不是 0 开始的原因。
---@param html string
---@return { index: integer, runes: string[] }[]
function Annotations.paragraphs(html)
    local out = {}
    if type(html) ~= "string" or html == "" then
        return out
    end
    local body = html:match("<body[^>]*>(.*)</body>") or html
    local index = 0
    for inner in body:gmatch("<p[^>]*>(.-)</p>") do
        index = index + 1
        local text = inner:gsub("<[^>]*>", "")
        text = Text.xmlDecode(text)
        text = text:gsub("[ \t\r\n]+", " ")
        out[#out + 1] = { index = index, runes = toRunes(text) }
    end
    return out
end

--- 统计 UTF-8 rune 数（不建中间数组）。
---@param str string
---@return integer
local function countRunes(str)
    local count, i, len = 0, 1, #str
    while i <= len do
        local byte = str:byte(i)
        i = i + (byte < 0x80 and 1 or byte < 0xe0 and 2 or byte < 0xf0 and 3 or 4)
        count = count + 1
    end
    return count
end

--- 跨段可匹配的 rune 流：逐段剥掉首尾空白后首尾相接，拼成一条可直接 ``find`` 的文本，
--- 并为每个 rune 记住来源段与段内偏移。
---
--- 段间不插分隔符：微信 ``markText`` 跨段时两段正文是直接相连的（本地正文里的段首缩进
--- 与段间换行都不在 markText 内），剥掉首尾空白后才能对齐。段内偏移仍按**未剥离**的
--- 折叠文本计，这样算出的 xpointer 才和 crengine 一致。
---
--- 用平行数组而非「每个 rune 一个 table」：一章上万 rune，逐条划线重建对象会打爆 GC。
---@param paragraphs { index: integer, runes: string[] }[]
---@return WechatRuneFlow
local function buildFlow(paragraphs)
    local runes, para, offset, rune_at_byte, para_first_byte = {}, {}, {}, {}, {}
    local count, byte_pos = 0, 1
    for _, item in ipairs(paragraphs) do
        local first, last = 1, #item.runes
        while first <= last and item.runes[first]:match("^%s$") do
            first = first + 1
        end
        while last >= first and item.runes[last]:match("^%s$") do
            last = last - 1
        end
        for i = first, last do
            local rune = item.runes[i]
            count = count + 1
            runes[count] = rune
            para[count] = item.index
            offset[count] = i - 1
            rune_at_byte[byte_pos] = count
            if para_first_byte[item.index] == nil then
                para_first_byte[item.index] = byte_pos
            end
            byte_pos = byte_pos + #rune
        end
    end
    ---@class WechatRuneFlow
    return {
        text = table.concat(runes),
        para = para,
        offset = offset,
        rune_at_byte = rune_at_byte,
        para_first_byte = para_first_byte,
        count = count,
        paragraphs = paragraphs,
    }
end

--- 建一次章节 rune 流，供同章多条划线复用。
---@param html string
---@return WechatRuneFlow
function Annotations.flow(html)
    return buildFlow(Annotations.paragraphs(html))
end

--- ``range`` 起点落在哪一段：按段落累计 rune 数逼近（用未剥离的折叠文本长度）。
---@param flow WechatRuneFlow
---@param range_str string|nil
---@return integer from_byte
local function preferredStart(flow, range_str)
    local start_pos = parseRange(tostring(range_str or ""))
    if not start_pos then
        return 1
    end
    local consumed = 0
    for _, item in ipairs(flow.paragraphs) do
        consumed = consumed + #item.runes
        if start_pos <= consumed then
            return flow.para_first_byte[item.index] or 1
        end
    end
    return 1
end

--- 在章节壳内定位划线原文，返回 crengine xpointer（支持跨段划线）。
---
--- 不用 ``document:findText``：那是跨页模糊搜索，命中与否取决于渲染状态，而段落偏移是
--- 确定的。``wr_range`` 只用来在同一文本重复出现时消歧。
---@param source string|WechatRuneFlow 章节壳 HTML（含 ``<h1>``）或已建好的 rune 流
---@param needle string 划线原文
---@param range_str string|nil 微信 ``range``，用于多处重复时择近
---@return string|nil pos0
---@return string|nil pos1
function Annotations.locate(source, needle, range_str)
    needle = tostring(needle or ""):gsub("[ \t\r\n]+", " ")
    needle = Text.trim(needle)
    if needle == "" then
        return nil, nil
    end
    local flow = type(source) == "table" and source or Annotations.flow(source)
    local want = countRunes(needle)
    if want == 0 or want > flow.count then
        return nil, nil
    end

    --- UTF-8 是自同步的，命中必然落在 rune 边界；对不上就当没命中，继续往后找。
    ---@param from integer
    ---@return integer|nil head_rune
    local function findRuneAt(from)
        local at = from
        while true do
            local hit = flow.text:find(needle, at, true)
            if not hit then
                return nil
            end
            local head = flow.rune_at_byte[hit]
            if head and head + want - 1 <= flow.count then
                return head
            end
            at = hit + 1
        end
    end

    local from_byte = preferredStart(flow, range_str)
    -- prefer 段之后没命中：回头从全文开头再搜一遍。
    local head = findRuneAt(from_byte) or (from_byte > 1 and findRuneAt(1)) or nil
    if not head then
        return nil, nil
    end
    local tail = head + want - 1
    -- pos1 是半开区间上界（实测对齐 KOReader 自己写出的 xpointer）。
    return string.format("/html/body/p[%d]/text().%d", flow.para[head], flow.offset[head]),
        string.format("/html/body/p[%d]/text().%d", flow.para[tail], flow.offset[tail] + 1)
end

--- 在章节可见正文中定位高亮原文，返回可见文本 0-based 半开区间偏移。
-- 仅用于上传统计时给本地划线补一个近似 ``range``；与微信原始 HTML 索引不同。
---@param html string
---@param needle string
---@return string|nil
function Annotations.findRange(html, needle)
    needle = tostring(needle or "")
    if needle == "" then
        return nil
    end
    local haystack = Annotations.plainBodyRunes(html)
    local want = countRunes(needle)
    if want == 0 or want > #haystack then
        return nil
    end
    -- 可见文本里按 rune 计偏移：拼成整串交给 find，命中后换算 rune 序号。
    local rune_at_byte = {}
    local byte_pos = 1
    for i = 1, #haystack do
        rune_at_byte[byte_pos] = i
        byte_pos = byte_pos + #haystack[i]
    end
    local text = table.concat(haystack)
    local at = 1
    while true do
        local hit = text:find(needle, at, true)
        if not hit then
            return nil
        end
        local head = rune_at_byte[hit]
        if head and head + want - 1 <= #haystack then
            return string.format("%d-%d", head - 1, head - 1 + want)
        end
        at = hit + 1
    end
end

return Annotations
