--[[--
章节正文文本 ↔ xpointer 定位，以及微信读书 ``range`` 互转（番茄段评也用 ``locateBatch`` 定位）。

微信 ``range`` 是原始章节 HTML（含标签）上的 0-based 半开区间 rune 索引，
与本地章节 HTML 无关。定位划线一律用已解码的 ``markText``
在可见正文里匹配，``range`` 只用于重复文本消歧；不能按可见文本去切片 ``range``。

@module koplugin.book.book.annotations
--]]

local Annotations = {}
local Text = require("utils.text")

--- 微信原始 HTML 上的 wire 映射：可见 rune ↔ 0-based wire 坐标。
---@class WechatWireMapping
---@field text string 规范化可见正文
---@field runes string[] 可见 rune 序列
---@field starts integer[] 每个 rune 在 wire HTML 上的 0-based 起始
---@field ends integer[] 每个 rune 在 wire HTML 上的 0-based 半开上界
---@field rune_at_byte table<integer, integer> 字节偏移 → rune 下标
---@field count integer rune 数

--- 本地章节 HTML 的可见 rune 流（定位划线用），见 ``Annotations.flow``。
---@class WechatRuneFlow: WechatWireMapping
---@field paths string[] 文本节点序号 → crengine xpointer（``starts[i]`` 即该序号，``ends[i]`` 为节点内偏移 + 1）

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

--- 可见 rune 累加器：连续空白折叠成一个空格；块边界不制造字符，并吞掉两侧空白
--- （与本地 rune 流逐段剥首尾空白后首尾相接的规则一致）。
---@class WechatVisibleBuilder
---@field runes string[]
---@field starts integer[]
---@field ends integer[]
---@field boundary boolean 位于块边界之后、尚未遇到非空白 rune

---@return WechatVisibleBuilder
local function newBuilder()
    return { runes = {}, starts = {}, ends = {}, boundary = true }
end

---@param b WechatVisibleBuilder
---@param rune string
---@param start_pos integer 0-based inclusive
---@param end_pos integer 0-based exclusive
local function appendVisible(b, rune, start_pos, end_pos)
    if IGNORED_RUNES[rune] then
        return
    end
    if rune == "　" or rune:match("^%s$") then
        if b.boundary then return end
        rune = " "
    end
    local n = #b.runes
    if rune == " " and b.runes[n] == " " then
        b.ends[n] = end_pos
        return
    end
    b.boundary = false
    b.runes[n + 1] = rune
    b.starts[n + 1] = start_pos
    b.ends[n + 1] = end_pos
end

---@param b WechatVisibleBuilder
local function blockBoundary(b)
    local n = #b.runes
    if b.runes[n] == " " then
        b.runes[n], b.starts[n], b.ends[n] = nil, nil, nil
    end
    b.boundary = true
end

---@param b WechatVisibleBuilder
---@return WechatWireMapping
local function finishMapping(b)
    blockBoundary(b)
    local rune_at_byte, byte_pos = {}, 1
    for index, rune in ipairs(b.runes) do
        rune_at_byte[byte_pos] = index
        byte_pos = byte_pos + #rune
    end
    ---@type WechatWireMapping
    return {
        text = table.concat(b.runes),
        runes = b.runes,
        starts = b.starts,
        ends = b.ends,
        rune_at_byte = rune_at_byte,
        count = #b.runes,
    }
end

--- 纯文本（TXT 章节原文、划线文本）→ 规范化可见文本及每个 rune 的 0-based 原文坐标。
--- 换行即段落边界：不制造字符，并吞掉两侧空白。
---@param text string
---@return WechatWireMapping
function Annotations.plainMapping(text)
    local b = newBuilder()
    for i, rune in ipairs(toRunes(Text.stripBom(text))) do
        if rune == "\n" then
            blockBoundary(b)
        else
            appendVisible(b, rune, i - 1, i)
        end
    end
    return finishMapping(b)
end

--- 标签内文字不属于正文：脚本、样式与 head（含 title，微信正文 body 内也可能出现）。
local SKIPPED_TAGS = { script = true, style = true, head = true, title = true }

--- 将微信章节 HTML 转成规范化可见文本，并保存每个文本 rune 对应的 wire 坐标。
--- 块标签边界不制造字符；只清掉边界空白，因此跨段 markText 仍能直接匹配。
---@param html string
---@return WechatWireMapping
function Annotations.wireMapping(html)
    html = Text.stripBom(html)
    local source = toRunes(html)
    local b = newBuilder()
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
                appendVisible(b, rune, i - 1, i)
                i = i + 1
            else
                local tag = table.concat(source, "", i + 1, close_pos - 1)
                local closing, name = tag:match("^%s*(/?)%s*([%w]+)")
                name = name and name:lower() or nil
                if skip_tag then
                    if closing == "/" and name == skip_tag then
                        skip_tag = nil
                    end
                elseif name and SKIPPED_TAGS[name] and closing ~= "/" and not tag:match("/%s*$") then
                    skip_tag = name
                elseif name and BLOCK_TAGS[name] then
                    blockBoundary(b)
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
                for _idx, value in ipairs(toRunes(decoded)) do
                    appendVisible(b, value, i - 1, entity_end)
                end
                i = entity_end + 1
            else
                appendVisible(b, rune, i - 1, i)
                i = i + 1
            end
        else
            appendVisible(b, rune, i - 1, i)
            i = i + 1
        end
    end
    return finishMapping(b)
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

local VOID_TAGS = {
    area = true, base = true, br = true, col = true, embed = true, hr = true, img = true,
    input = true, link = true, meta = true, param = true, source = true, track = true, wbr = true,
}

--- crengine 不为这些元素保留纯空白文本节点（不计入 ``text()[k]`` 序号）。
local NO_SPACE_TEXT = {
    html = true, head = true, body = true, div = true, section = true, article = true,
    blockquote = true, table = true, tbody = true, thead = true, tr = true,
    ul = true, ol = true, dl = true, figure = true, aside = true, nav = true,
    header = true, footer = true, main = true,
}

---@class WechatDomNode
---@field parent WechatDomNode|nil 根为 nil
---@field name string
---@field ord integer 在父节点同名兄弟里的 1-based 序号（文本节点为同级文本序号）
---@field counts table<string, integer> 子元素按名计数
---@field texts integer 文本子节点数
---@field skip boolean 子树不算正文

---@param node WechatDomNode
---@return string
local function elementPath(node)
    if not node.parent then return "" end
    local step = node.name
    if node.parent.counts[node.name] > 1 then
        step = step .. "[" .. node.ord .. "]"
    end
    return elementPath(node.parent) .. "/" .. step
end

--- 本地章节 HTML → 可见 rune 流，每个 rune 记住所在文本节点的 crengine xpointer 与节点内偏移。
---
--- 按真实 DOM 遍历（嵌套、行内元素拆开的多个文本节点、多份拼接文档的 ``html[k]`` 都照算），
--- 路径规则同 crengine ``ldomXPointer::toStringV2``：同名兄弟多于一个才带 ``[k]``。
--- 节点内偏移按 crengine 规则折叠连续空白为单个空格且**不 trim**（段首缩进占 1 个字符）。
--- 可见文本规则与 ``wireMapping`` 相同（块边界吞空白、不制造字符），同一份正文两边 text 一致。
--- 宿主追加的脚注 aside（``epub:type="footnote"``）不算正文。
---
--- 结构与 WechatWireMapping 相同：``starts[i]`` 是文本节点序号，``ends[i]`` 是节点内偏移 + 1。
---@param html string
---@return WechatRuneFlow
function Annotations.flow(html)
    html = Text.stripBom(tostring(html or ""))
    local b = newBuilder()
    ---@type WechatDomNode
    local root = { name = "", ord = 1, counts = {}, texts = 0, skip = false }
    local top = root
    local text_nodes = {}

    local function onText(raw)
        if top.skip then return end
        local text = Text.xmlDecode(raw)
        if NO_SPACE_TEXT[top.name] or top == root then
            if not text:find("[^%s]") then return end
        end
        top.texts = top.texts + 1
        local id = #text_nodes + 1
        text_nodes[id] = { parent = top, ord = top.texts }
        local offset, prev_space = 0, false
        for _idx, rune in ipairs(toRunes(text)) do
            local space = rune:match("^%s$") ~= nil
            if not (space and prev_space) then
                appendVisible(b, rune, id, offset + 1)
                offset = offset + 1
            end
            prev_space = space
        end
    end

    local pos, len = 1, #html
    while pos <= len do
        local lt = html:find("<", pos, true)
        if not lt then
            onText(html:sub(pos))
            break
        end
        if lt > pos then onText(html:sub(pos, lt - 1)) end
        if html:sub(lt, lt + 3) == "<!--" then
            local close = html:find("-->", lt + 4, true)
            pos = close and close + 3 or len + 1
        else
            local gt = html:find(">", lt + 1, true) or len
            local tag = html:sub(lt + 1, gt - 1)
            pos = gt + 1
            local closing, name = tag:match("^%s*(/?)%s*([%w:]+)")
            name = name and name:lower()
            if name and closing == "/" then
                local node = top
                while node ~= root and node.name ~= name do node = node.parent end
                if node ~= root then
                    top = node.parent
                    if BLOCK_TAGS[name] then blockBoundary(b) end
                end
            elseif name and tag:sub(1, 1) ~= "!" and tag:sub(1, 1) ~= "?" then
                top.counts[name] = (top.counts[name] or 0) + 1
                ---@type WechatDomNode
                local node = {
                    parent = top, name = name, ord = top.counts[name], counts = {}, texts = 0,
                    skip = top.skip or SKIPPED_TAGS[name] or tag:find('epub:type="footnote"', 1, true) ~= nil,
                }
                if BLOCK_TAGS[name] then blockBoundary(b) end
                if not VOID_TAGS[name] and not tag:match("/%s*$") then top = node end
            end
        end
    end

    local mapping = finishMapping(b) --[[@as WechatRuneFlow]]
    local paths = {}
    for id, node in ipairs(text_nodes) do
        local step = node.parent.texts > 1 and ("/text()[" .. node.ord .. "]") or "/text()"
        paths[id] = elementPath(node.parent) .. step
    end
    mapping.paths = paths
    return mapping
end

--- 第 i 个 rune 起点 / 终点（半开）的 xpointer。
---@param flow WechatRuneFlow
---@param i integer
---@param after boolean|nil true 取该 rune 之后的位置
---@return string
local function xpointerAt(flow, i, after)
    local offset = flow.ends[i] - (after and 0 or 1)
    return flow.paths[flow.starts[i]] .. "." .. offset
end

---@param flow WechatRuneFlow|WechatWireMapping
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

---@param flow WechatRuneFlow
---@param pos string|nil
---@return integer|nil
local function headAtXPointer(flow, pos)
    if type(pos) ~= "string" then
        return nil
    end
    -- 先拆出路径与偏移再逐个比对，避免对整章每个字都拼一次 xpointer 字符串。
    local path, offset = pos:match("^(.*)%.(%d+)$")
    offset = tonumber(offset)
    if not path then return nil end
    for i = 1, flow.count do
        if flow.ends[i] - 1 == offset and flow.paths[flow.starts[i]] == path then
            return i
        end
    end
    return nil
end

--- 同章批量定位：先确定唯一文本，再利用远端 range 顺序约束重复短句。
--- HTML 改写会改变绝对 range，但不会改变正文顺序；只有约束后剩唯一候选才返回。
---
--- 不用 ``document:findText``：那是跨页模糊搜索，命中与否取决于渲染状态，而段落偏移是
--- 确定的。仍然歧义的重复文本拒绝定位，避免把高亮画到错误位置。
---@param source string|WechatRuneFlow
---@param items table[]
---@return table<table, { pos0: string, pos1: string }>
function Annotations.locateBatch(source, items)
    local flow
    if type(source) == "string" then
        flow = Annotations.flow(source)
    else
        flow = source
    end
    local entries = {}
    for ordinal, item in ipairs(items or {}) do
        local needle = Annotations.plainMapping(item.text or "").text
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
    for _idx, entry in ipairs(entries) do
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
                for _idx, head in ipairs(entry.heads) do
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
    for _idx, entry in ipairs(entries) do
        local head = entry.chosen
        if head then
            local tail = head + countRunes(entry.needle) - 1
            -- pos1 是半开区间上界（实测对齐 KOReader 自己写出的 xpointer）。
            out[entry.item] = { pos0 = xpointerAt(flow, head), pos1 = xpointerAt(flow, tail, true) }
        end
    end
    return out
end

--- 章节 range 坐标原文 → wire 映射：EPUB 按 HTML 解析，TXT 按纯文本逐 rune 计。
---@param source string
---@param format '"html"'|'"txt"'|nil 缺省按 html
---@return WechatWireMapping
function Annotations.rangeMapping(source, format)
    if format == "txt" then
        return Annotations.plainMapping(source)
    end
    return Annotations.wireMapping(source)
end

--- 把本地原生 xpointer 映射为当前微信章节的 wire range。
--- 两份正文规范化文本完全一致时直接按全局 rune 位置映射；否则只接受两边候选数一致的
--- occurrence 映射。任何歧义或反向校验失败都返回 nil。
---@param wire WechatWireMapping Annotations.rangeMapping 的结果；同章多条划线复用
---@param local_flow WechatRuneFlow Annotations.flow(本地章节 HTML)
---@param needle string
---@param pos0 string|nil
---@param pos1 string|nil
---@return string|nil range
---@return string|nil err
function Annotations.toWireRange(wire, local_flow, needle, pos0, pos1)
    -- KOReader 跨段选区在段间带换行，按段落边界规范化后才能与 rune 流对齐。
    needle = Annotations.plainMapping(needle or "").text
    if needle == "" then
        return nil, "empty highlight"
    end
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
    local want = countRunes(needle)
    if ordinal then
        -- 起点由 xpointer 命中时，终点必须落在同一坐标系里。
        if pos1 and xpointerAt(local_flow, local_head + want - 1, true) ~= pos1 then
            return nil, "local highlight range mismatch"
        end
    else
        if #local_heads ~= 1 then
            return nil, "ambiguous local highlight"
        end
        ordinal = 1
        local_head = local_heads[1]
    end

    local wire_head
    if local_flow.text == wire.text then
        wire_head = local_head
    elseif #local_heads == #wire_heads then
        wire_head = wire_heads[ordinal]
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

--- 远端原文偏移 → 本地正文坐标；正文改写后按相同出现次数的上下文对齐。
---@param wire WechatWireMapping
---@param local_flow WechatRuneFlow
---@param offset integer
---@return string|nil locator
---@return number|nil fraction 正文字符比例，不是排版页比例
function Annotations.fromWireOffset(wire, local_flow, offset)
    if wire.count == 0 then return nil end
    local head = wire.count
    for i = 1, wire.count do
        if wire.ends[i] > offset then head = i; break end
    end
    if wire.text == local_flow.text then
        return xpointerAt(local_flow, head), (head - 1) / wire.count
    end
    local needle = table.concat(wire.runes, "", head, math.min(head + 29, wire.count))
    local wire_heads, local_heads = matchingHeads(wire, needle), matchingHeads(local_flow, needle)
    if #wire_heads == #local_heads then
        for ordinal, wire_head in ipairs(wire_heads) do
            if wire_head == head then
                return xpointerAt(local_flow, local_heads[ordinal]), (head - 1) / wire.count
            end
        end
    end
    return nil
end

--- 本地正文坐标 → 远端原文偏移及正文摘要。
---@param wire WechatWireMapping
---@param local_flow WechatRuneFlow
---@param locator string
---@return integer|nil offset
---@return string|nil summary
---@return number|nil fraction
---@return string|nil err
function Annotations.toWirePosition(wire, local_flow, locator)
    local head = headAtXPointer(local_flow, locator)
    if not head then return nil, nil, nil, "reading position not found in chapter" end
    local summary = table.concat(local_flow.runes, "", head, math.min(head + 29, local_flow.count))
    local range, err = Annotations.toWireRange(wire, local_flow, summary, locator)
    if not range then return nil, nil, nil, err end
    local offset = tonumber(range:match("^(%d+)"))
    local wire_head = 1
    for i = 1, wire.count do
        if wire.starts[i] == offset then wire_head = i; break end
    end
    return offset, summary, (wire_head - 1) / wire.count
end

return Annotations
