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

local BLOCK_TAGS = {
    address = true, article = true, aside = true, blockquote = true,
    div = true, dl = true, fieldset = true, figcaption = true, figure = true,
    footer = true, form = true, h1 = true, h2 = true, h3 = true, h4 = true,
    h5 = true, h6 = true, header = true, hr = true, li = true, main = true,
    nav = true, ol = true, p = true, pre = true, section = true, table = true,
    tr = true, ul = true,
}

local IGNORED_RUNES = {
    ["\226\128\139"] = true, -- U+200B
    ["\226\128\140"] = true, -- U+200C
    ["\226\128\141"] = true, -- U+200D
    ["\226\129\160"] = true, -- U+2060
    ["\239\187\191"] = true, -- U+FEFF
}

---@param runes string[]
---@param starts integer[]
---@param ends integer[]
---@param rune string
---@param start_pos integer 0-based inclusive
---@param end_pos integer 0-based exclusive
local function appendVisible(runes, starts, ends, rune, start_pos, end_pos)
    if IGNORED_RUNES[rune] then
        return
    end
    if rune == "　" or rune:match("^%s$") then
        rune = " "
    end
    if rune == " " and runes[#runes] == " " then
        ends[#ends] = end_pos
        return
    end
    runes[#runes + 1] = rune
    starts[#starts + 1] = start_pos
    ends[#ends + 1] = end_pos
end

local function trimVisible(runes, starts, ends)
    while runes[1] == " " do
        table.remove(runes, 1)
        table.remove(starts, 1)
        table.remove(ends, 1)
    end
    while runes[#runes] == " " do
        table.remove(runes)
        table.remove(starts)
        table.remove(ends)
    end
end

--- 将微信章节 HTML 转成规范化可见文本，并保存每个文本 rune 对应的 wire 坐标。
--- 块标签边界不制造字符；只清掉边界空白，因此跨段 markText 仍能直接匹配。
---@param html string
---@return WechatWireMapping
function Annotations.wireMapping(html)
    html = Text.stripBom(html)
    local source = toRunes(html)
    local runes, starts, ends = {}, {}, {}
    local i, skip_tag = 1, nil
    while i <= #source do
        local rune = source[i]
        if rune == "<" then
            local close_pos
            for j = i + 1, #source do
                if source[j] == ">" then
                    close_pos = j
                    break
                end
            end
            if not close_pos then
                appendVisible(runes, starts, ends, rune, i - 1, i)
                i = i + 1
            else
                local tag = table.concat(source, "", i + 1, close_pos - 1)
                local closing, name = tag:match("^%s*(/?)%s*([%w]+)")
                name = name and name:lower() or nil
                if skip_tag then
                    if closing == "/" and name == skip_tag then
                        skip_tag = nil
                    end
                elseif (name == "script" or name == "style") and closing ~= "/" then
                    skip_tag = name
                elseif name and BLOCK_TAGS[name] then
                    trimVisible(runes, starts, ends)
                end
                i = close_pos + 1
            end
        elseif skip_tag then
            i = i + 1
        elseif rune == "&" then
            local entity_end
            for j = i + 1, math.min(i + 16, #source) do
                if source[j] == ";" then
                    entity_end = j
                    break
                elseif source[j] == "<" or source[j] == ">" or source[j] == " " then
                    break
                end
            end
            local encoded = entity_end and table.concat(source, "", i, entity_end) or nil
            local decoded = encoded and Text.xmlDecode(encoded) or nil
            if decoded and decoded ~= encoded then
                for _, value in ipairs(toRunes(decoded)) do
                    appendVisible(runes, starts, ends, value, i - 1, entity_end)
                end
                i = entity_end + 1
            else
                appendVisible(runes, starts, ends, rune, i - 1, i)
                i = i + 1
            end
        else
            appendVisible(runes, starts, ends, rune, i - 1, i)
            i = i + 1
        end
    end
    trimVisible(runes, starts, ends)
    local rune_at_byte, byte_pos = {}, 1
    for index, rune in ipairs(runes) do
        rune_at_byte[byte_pos] = index
        byte_pos = byte_pos + #rune
    end
    ---@class WechatWireMapping
    return {
        text = table.concat(runes),
        runes = runes,
        starts = starts,
        ends = ends,
        rune_at_byte = rune_at_byte,
        count = #runes,
    }
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

---@param text string
---@return string
local function normalizeText(text)
    local mapping = Annotations.wireMapping(Text.xmlEscape(Text.stripBom(text)))
    return mapping.text
end

---@param flow table
---@param needle string
---@return integer[]
local function matchingHeads(flow, needle)
    local heads, want, at = {}, countRunes(needle), 1
    while at <= #flow.text do
        local hit = flow.text:find(needle, at, true)
        if not hit then
            break
        end
        local head = flow.rune_at_byte[hit]
        if head and head + want - 1 <= flow.count then
            heads[#heads + 1] = head
        end
        at = hit + 1
    end
    return heads
end

---@param pos string|nil
---@return integer|nil
---@return integer|nil
local function parseXPointer(pos)
    if type(pos) ~= "string" then
        return nil
    end
    local paragraph, offset = pos:match("/p%[(%d+)%]/text%(%)%.(%d+)$")
    return tonumber(paragraph), tonumber(offset)
end

---@param flow WechatRuneFlow
---@param pos string|nil
---@return integer|nil
local function headAtXPointer(flow, pos)
    local paragraph, offset = parseXPointer(pos)
    if not paragraph then
        return nil
    end
    for i = 1, flow.count do
        if flow.para[i] == paragraph and flow.offset[i] == offset then
            return i
        end
    end
    return nil
end

--- 在章节壳内定位划线原文，返回 crengine xpointer（支持跨段划线）。
---
--- 不用 ``document:findText``：那是跨页模糊搜索，命中与否取决于渲染状态，而段落偏移是
--- 确定的。wire ``range`` 与本地壳不是同一坐标系，不能拿它猜本地段落；重复文本若
--- 没有已保存的 xpointer 就拒绝定位，避免把高亮画到错误位置。
---@param source string|WechatRuneFlow 章节壳 HTML（含 ``<h1>``）或已建好的 rune 流
---@param needle string 划线原文
---@param range_str string|nil 兼容旧调用；不参与本地坐标计算
---@return string|nil pos0
---@return string|nil pos1
---@return string|nil err
function Annotations.locate(source, needle, range_str)
    needle = normalizeText(tostring(needle or ""))
    if needle == "" then
        return nil, nil
    end
    local flow = type(source) == "table" and source or Annotations.flow(source)
    local want = countRunes(needle)
    if want == 0 or want > flow.count then
        return nil, nil
    end

    local heads = matchingHeads(flow, needle)
    if #heads == 0 then
        return nil, nil
    end
    if #heads > 1 then
        return nil, nil, "ambiguous"
    end
    local head = heads[1]
    local tail = head + want - 1
    -- pos1 是半开区间上界（实测对齐 KOReader 自己写出的 xpointer）。
    return string.format("/html/body/p[%d]/text().%d", flow.para[head], flow.offset[head]),
        string.format("/html/body/p[%d]/text().%d", flow.para[tail], flow.offset[tail] + 1)
end

--- 同章批量定位：先确定唯一文本，再利用远端 range 顺序约束重复短句。
--- HTML 改写会改变绝对 range，但不会改变正文顺序；只有约束后剩唯一候选才返回。
---@param source string|WechatRuneFlow
---@param items table[]
---@return table<table, { pos0: string, pos1: string }>
function Annotations.locateBatch(source, items)
    local flow = type(source) == "table" and source or Annotations.flow(source)
    local entries = {}
    for ordinal, item in ipairs(items or {}) do
        local needle = type(item) == "table" and normalizeText(item.text or "") or ""
        if needle ~= "" then
            local range_start = tonumber(tostring(item.wr_range or ""):match("^(%d+)"))
            entries[#entries + 1] = {
                item = item,
                needle = needle,
                heads = matchingHeads(flow, needle),
                range_start = range_start or math.huge,
                ordinal = ordinal,
            }
        end
    end
    table.sort(entries, function(a, b)
        if a.range_start == b.range_start then return a.ordinal < b.ordinal end
        return a.range_start < b.range_start
    end)
    for _, entry in ipairs(entries) do
        if #entry.heads == 1 then entry.chosen = entry.heads[1] end
    end
    local changed = true
    while changed do
        changed = false
        for index, entry in ipairs(entries) do
            if not entry.chosen and #entry.heads > 1 then
                local lower, upper
                for i = index - 1, 1, -1 do
                    if entries[i].chosen then lower = entries[i].chosen; break end
                end
                for i = index + 1, #entries do
                    if entries[i].chosen then upper = entries[i].chosen; break end
                end
                local candidate
                for _, head in ipairs(entry.heads) do
                    if (not lower or head >= lower) and (not upper or head <= upper) then
                        if candidate then
                            candidate = nil
                            break
                        end
                        candidate = head
                    end
                end
                if candidate then
                    entry.chosen = candidate
                    changed = true
                end
            end
        end
    end
    local out = {}
    for _, entry in ipairs(entries) do
        local head = entry.chosen
        if head then
            local tail = head + countRunes(entry.needle) - 1
            out[entry.item] = {
                pos0 = string.format("/html/body/p[%d]/text().%d", flow.para[head], flow.offset[head]),
                pos1 = string.format("/html/body/p[%d]/text().%d", flow.para[tail], flow.offset[tail] + 1),
            }
        end
    end
    return out
end

--- 把本地原生 xpointer 映射为当前微信章节 HTML 的 wire range。
--- 两份正文规范化文本完全一致时直接按全局 rune 位置映射；否则只接受两边候选数一致的
--- occurrence 映射。任何歧义或反向校验失败都返回 nil。
---@param wire_html string
---@param local_html string
---@param needle string
---@param pos0 string|nil
---@param pos1 string|nil
---@return string|nil range
---@return string|nil err
function Annotations.toWireRange(wire_html, local_html, needle, pos0, pos1)
    needle = normalizeText(tostring(needle or ""))
    if needle == "" then
        return nil, "empty highlight"
    end
    local local_flow = Annotations.flow(local_html)
    local wire = Annotations.wireMapping(wire_html)
    local local_heads = matchingHeads(local_flow, needle)
    local wire_heads = matchingHeads(wire, needle)
    if #local_heads == 0 or #wire_heads == 0 then
        return nil, "highlight text not found"
    end

    local local_head = headAtXPointer(local_flow, pos0)
    local ordinal
    for i, head in ipairs(local_heads) do
        if head == local_head then
            ordinal = i
            break
        end
    end
    if not ordinal then
        if #local_heads ~= 1 then
            return nil, "ambiguous local highlight"
        end
        ordinal = 1
        local_head = local_heads[1]
    end
    local want = countRunes(needle)
    local local_tail = local_head + want - 1
    local end_paragraph, end_offset = parseXPointer(pos1)
    if end_paragraph and (local_flow.para[local_tail] ~= end_paragraph
            or local_flow.offset[local_tail] + 1 ~= end_offset) then
        return nil, "local highlight range mismatch"
    end

    local wire_head
    if local_flow.text == wire.text then
        wire_head = local_head
    elseif #local_heads == #wire_heads then
        wire_head = wire_heads[ordinal]
    elseif #wire_heads == 1 and #local_heads == 1 then
        wire_head = wire_heads[1]
    else
        return nil, "ambiguous wire highlight"
    end
    local wire_tail = wire_head and wire_head + want - 1 or nil
    if not wire_tail or not wire.starts[wire_head] or not wire.ends[wire_tail] then
        return nil, "invalid wire highlight"
    end
    local selected = table.concat(wire.runes, "", wire_head, wire_tail)
    if selected ~= needle then
        return nil, "wire highlight verification failed"
    end
    return string.format("%d-%d", wire.starts[wire_head], wire.ends[wire_tail])
end

--- 取 wire range 覆盖的规范化可见文本，供请求发送前后验证。
---@param html string
---@param range_str string
---@return string|nil
function Annotations.textAtWireRange(html, range_str)
    local start_pos, stop_pos = parseRange(range_str)
    if not start_pos then
        return nil
    end
    local mapping = Annotations.wireMapping(html)
    local out = {}
    local start_zero, end_exclusive = start_pos - 1, stop_pos
    for i = 1, mapping.count do
        if mapping.starts[i] >= start_zero and mapping.ends[i] <= end_exclusive then
            out[#out + 1] = mapping.runes[i]
        end
    end
    return #out > 0 and table.concat(out) or nil
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
