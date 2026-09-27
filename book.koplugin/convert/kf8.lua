--[[--
KF8（AZW3）→ 单文件 HTML + 资源，交给 CREngine 渲染。

移植自 azwreader-koreader 的 kf8extractor（按 Calibre mobi8 reader 核对过偏移）：
PalmDB 分节 → 文本记录解压（无压缩 / PalmDOC）→ FDST 切流 → SKEL/DIV 索引重建 XHTML
→ 改写 kindle:embed / kindle:flow / kindle:pos 引用。

只处理独立 KF8（MOBI 版本 8）。MOBI6 与 MOBI6+KF8 合并文件返回 nil：CREngine 能直接按 MOBI 读。
DRM、HUFF/CDIC 压缩、结构损坏直接 error。

  local info = Kf8.extract(path, dir)
  -- info = { html = "book.html", cover = "res0003.jpg"|nil, metadata = {...}, toc = { { title, depth, anchor } } }

@module koplugin.book.convert.kf8
--]]

local bit = require("bit")
local Text = require("utils.text")

local Kf8 = {}

local NULL_INDEX = 0xFFFFFFFF
local B32 = "0123456789ABCDEFGHIJKLMNOPQRSTUV"

---@class Kf8TocItem
---@field title string
---@field depth number
---@field anchor string CREngine 可解析的 "#id" 引用

---@class Kf8Info
---@field html string 相对 dir 的 HTML 文件名
---@field cover string|nil 相对 dir 的封面文件名
---@field metadata table title/author/publisher/description/language
---@field toc Kf8TocItem[]

local function u16(s, o)
    local a, b = s:byte(o + 1, o + 2)
    if not b then error("truncated u16") end
    return a * 256 + b
end

local function u32(s, o)
    local a, b, c, d = s:byte(o + 1, o + 4)
    if not d then error("truncated u32") end
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local function writeFile(path, data)
    local f = assert(io.open(path, "wb"))
    assert(f:write(data))
    assert(f:close())
end

local function sections(raw)
    local count = u16(raw, 76)
    local offsets = {}
    for i = 0, count - 1 do
        offsets[i + 1] = u32(raw, 78 + i * 8)
    end
    offsets[count + 1] = #raw
    local out = {}
    for i = 1, count do
        out[i] = raw:sub(offsets[i] + 1, offsets[i + 1])
    end
    return out
end

--- 文本记录尾部附加数据的字节数（MOBI extra_flags）。
local function trailingSize(data, flags)
    local size = 0
    local f = bit.rshift(flags, 1)
    while f > 0 do
        if bit.band(f, 1) == 1 then
            local p, shift, value = #data - size, 0, 0
            while p > 0 do
                local b = data:byte(p)
                value = value + bit.band(b, 0x7F) * 2 ^ shift
                shift = shift + 7
                p = p - 1
                if b >= 0x80 or shift >= 28 then break end
            end
            size = size + value
        end
        f = bit.rshift(f, 1)
    end
    if bit.band(flags, 1) == 1 then
        local b = data:byte(#data - size)
        if not b then error("corrupt MOBI trailing data") end
        size = size + bit.band(b, 3) + 1
    end
    return size
end

local function palmdoc(data)
    local out, n, i, len = {}, 0, 1, #data
    while i <= len do
        local c = data:byte(i)
        i = i + 1
        if c >= 1 and c <= 8 then
            local run = math.min(c, len - i + 1)
            for k = 0, run - 1 do out[n + 1 + k] = data:byte(i + k) end
            n, i = n + run, i + run
        elseif c < 0x80 then
            n = n + 1
            out[n] = c
        elseif c >= 0xC0 then
            out[n + 1], out[n + 2] = 0x20, bit.bxor(c, 0x80)
            n = n + 2
        else
            local c2 = data:byte(i)
            if not c2 then error("truncated PalmDOC backreference") end
            i = i + 1
            local pair = c * 256 + c2
            local dist = bit.rshift(bit.band(pair, 0x3FFF), 3)
            if dist == 0 or dist > n then error("invalid PalmDOC backreference") end
            for _ = 1, bit.band(pair, 7) + 3 do
                n = n + 1
                out[n] = out[n - dist]
            end
        end
    end
    -- unpack 受 C 栈限制，分片转字符串
    local parts = {}
    for p = 1, n, 4096 do
        parts[#parts + 1] = string.char(unpack(out, p, math.min(p + 4095, n)))
    end
    return table.concat(parts)
end

--- 正向变长整数：高位为 1 的字节结束。
local function decint(data, pos)
    local value, used = 0, 0
    while pos + used <= #data do
        local b = data:byte(pos + used)
        used = used + 1
        value = value * 128 + bit.band(b, 0x7F)
        if b >= 0x80 then break end
    end
    return value, used
end

local function countBits(v)
    local n = 0
    while v > 0 do
        n = n + bit.band(v, 1)
        v = bit.rshift(v, 1)
    end
    return n
end

local function tagx(data, base)
    if data:sub(base + 1, base + 4) ~= "TAGX" then error("invalid TAGX") end
    local first_entry = u32(data, base + 4)
    local control_count = u32(data, base + 8)
    local tags = {}
    for p = base + 12, base + first_entry - 1, 4 do
        tags[#tags + 1] = {
            tag = data:byte(p + 1),
            num_values = data:byte(p + 2),
            bitmask = data:byte(p + 3),
            eof = data:byte(p + 4),
        }
    end
    return control_count, tags
end

local function indxHeader(data)
    if data:sub(1, 4) ~= "INDX" then error("invalid INDX record") end
    return { start = u32(data, 20), count = u32(data, 24), ncncx = u32(data, 52), tagx = u32(data, 180) }
end

--- INDX 条目的 tag → 值列表（Calibre get_tag_map）。
local function tagMap(control_count, tags, data)
    local ci, pos = 1, control_count + 1
    local pending = {}
    for _, x in ipairs(tags) do
        if x.eof == 1 then
            ci = ci + 1
        else
            local value = bit.band(data:byte(ci) or 0, x.bitmask)
            if value ~= 0 then
                local count, bytes
                if value == x.bitmask and countBits(x.bitmask) > 1 then
                    local used
                    bytes, used = decint(data, pos)
                    pos = pos + used
                elseif value == x.bitmask then
                    count = 1
                else
                    local mask = x.bitmask
                    while bit.band(mask, 1) == 0 do
                        mask, value = bit.rshift(mask, 1), bit.rshift(value, 1)
                    end
                    count = value
                end
                pending[#pending + 1] = { tag = x.tag, count = count, bytes = bytes, num_values = x.num_values }
            end
        end
    end
    local out = {}
    for _, x in ipairs(pending) do
        local vals = {}
        if x.count then
            for _ = 1, x.count * x.num_values do
                local v, used = decint(data, pos)
                pos = pos + used
                vals[#vals + 1] = v
            end
        else
            local consumed = 0
            while consumed < x.bytes do
                local v, used = decint(data, pos)
                pos, consumed = pos + used, consumed + used
                vals[#vals + 1] = v
            end
        end
        out[x.tag] = vals
    end
    return out
end

--- 读一张 INDX 表：条目列表 + CNCX 字符串池（键为池内偏移）。
local function readIndex(secs, idx0)
    local master = secs[idx0 + 1]
    local mh = indxHeader(master)
    local control_count, tags = tagx(master, mh.tagx)
    local entries = {}
    for sec0 = idx0 + 1, idx0 + mh.count do
        local data = secs[sec0 + 1]
        local h = indxHeader(data)
        if data:sub(h.start + 1, h.start + 4) ~= "IDXT" then error("invalid IDXT") end
        local positions = {}
        for j = 0, h.count - 1 do
            positions[j + 1] = u16(data, h.start + 4 + j * 2)
        end
        positions[h.count + 1] = h.start
        for j = 1, h.count do
            local rec = data:sub(positions[j] + 1, positions[j + 1])
            local len = rec:byte(1) or 0
            entries[#entries + 1] = {
                ident = rec:sub(2, 1 + len),
                tags = tagMap(control_count, tags, rec:sub(2 + len)),
            }
        end
    end
    local cncx = {}
    for k = 0, mh.ncncx - 1 do
        local data = secs[idx0 + mh.count + 2 + k] or ""
        local pos = 1
        while pos <= #data do
            local len, used = decint(data, pos)
            if len <= 0 then break end
            cncx[k * 0x10000 + pos - 1] = data:sub(pos + used, pos + used + len - 1)
            pos = pos + used + len
        end
    end
    return entries, cncx
end

local function b32decode(s)
    local n = 0
    for i = 1, #s do
        local p = B32:find(s:sub(i, i):upper(), 1, true)
        if not p then return nil end
        n = n * 32 + p - 1
    end
    return n
end

local function b32encode(n)
    local out = ""
    repeat
        local d = n % 32
        out = B32:sub(d + 1, d + 1) .. out
        n = math.floor(n / 32)
    until n == 0
    return string.rep("0", 4 - #out) .. out
end

local function imageExt(data)
    if data:sub(1, 3) == "\255\216\255" then return "jpg" end
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then return "png" end
    if data:sub(1, 4) == "GIF8" then return "gif" end
    if data:sub(1, 2) == "BM" then return "bmp" end
end

local function exth(header)
    local meta = {}
    local pos = 16 + u32(header, 20)
    if header:sub(pos + 1, pos + 4) ~= "EXTH" then return meta end
    local authors = {}
    local p = pos + 12
    for _ = 1, u32(header, pos + 8) do
        if p + 8 > #header then break end
        local typ, len = u32(header, p), u32(header, p + 4)
        if len < 8 or p + len > #header then break end
        local value = header:sub(p + 9, p + len)
        if typ == 100 then authors[#authors + 1] = value
        elseif typ == 101 then meta.publisher = value
        elseif typ == 103 then meta.description = value
        elseif typ == 201 and #value >= 4 then meta.cover_offset = u32(value, 0)
        elseif typ == 503 then meta.title = value
        elseif typ == 524 then meta.language = value
        end
        p = p + len
    end
    if #authors > 0 then meta.author = table.concat(authors, ", ") end
    return meta
end

--- 插入点是否落在标签内部（坏 DIV 偏移，Calibre 同款判断）。
local function insideTag(s, ip)
    local head = s:sub(1, ip)
    if (head:match(".*()<") or 0) > (head:match(".*()>") or 0) then return true end
    local gt, lt = s:find(">", ip + 1, true), s:find("<", ip + 1, true)
    return gt ~= nil and (lt == nil or gt < lt)
end

--- 含 aid 属性的标签结束位置（1 起，指向 '>'）。
local function aidTagEnd(s, aid)
    local p = s:find('aid="' .. aid .. '"', 1, true) or s:find("aid='" .. aid .. "'", 1, true)
    return p and s:find(">", p, true)
end

--- 按 SKEL/DIV 索引把分片插回骨架，得到各 XHTML 部分。
local function buildParts(text, skels, divs, div_cncx)
    local parts = {}
    local divptr = 1
    for _, sk in ipairs(skels) do
        local t1, t6 = sk.tags[1], sk.tags[6]
        if not t1 or not t6 then error("malformed SKEL index") end
        local skelpos = t6[1]
        local baseptr = skelpos + t6[2]
        local skeleton = text:sub(skelpos + 1, baseptr)
        local anchors = {}
        for _ = 1, t1[1] do
            local d = divs[divptr]
            if not d or not d.tags[6] then error("malformed DIV index") end
            local startpos, length = d.tags[6][1], d.tags[6][2]
            local ip = tonumber(d.ident) - skelpos
            if insideTag(skeleton, ip) then
                local idtext = d.tags[2] and div_cncx[d.tags[2][1]]
                local aid = idtext and idtext:match("aid=['\"]([^'\"]+)['\"]")
                local tag_end = aid and aidTagEnd(skeleton, aid)
                if tag_end then ip = tag_end + startpos end
            end
            if ip < 0 or ip > #skeleton then error("invalid KF8 DIV insert position " .. ip) end
            skeleton = skeleton:sub(1, ip) .. text:sub(baseptr + 1, baseptr + length) .. skeleton:sub(ip + 1)
            anchors[#anchors + 1] = { fid = divptr - 1, pos = ip }
            baseptr = baseptr + length
            divptr = divptr + 1
        end
        -- 锚点必须在整段重建完后从右往左插：DIV 偏移指向未改动的骨架
        table.sort(anchors, function(a, b) return a.pos > b.pos end)
        for _, a in ipairs(anchors) do
            skeleton = skeleton:sub(1, a.pos) .. '<a id="azwfid' .. b32encode(a.fid) .. '"></a>' .. skeleton:sub(a.pos + 1)
        end
        parts[#parts + 1] = skeleton
    end
    return parts
end

--- 解析独立 KF8 并把 HTML / CSS / 图片写进 dir（目录须已存在）。
---@param path string
---@param dir string
---@return Kf8Info|nil info 非独立 KF8（MOBI6 / 合并文件）时为 nil
function Kf8.extract(path, dir)
    local f = assert(io.open(path, "rb"))
    local raw = f:read("*a")
    f:close()
    if #raw < 78 or raw:sub(61, 68) ~= "BOOKMOBI" then error("not a BOOKMOBI container") end
    local secs = sections(raw)
    raw = nil
    local header = secs[1]
    if header:sub(17, 20) ~= "MOBI" then error("missing MOBI header") end
    if u32(header, 36) ~= 8 then return nil end
    if u16(header, 12) ~= 0 then error("DRM-encrypted AZW3 is not supported") end

    local compression = u16(header, 0)
    if compression == 0x4448 then error("HUFF/CDIC-compressed KF8 is not supported") end
    if compression ~= 1 and compression ~= 2 then error("unknown MOBI compression " .. compression) end
    local extra_flags = #header >= 0xF4 and u16(header, 0xF2) or 0
    local fdstidx = u32(header, 0xC0)
    local first_image = u32(header, 0x6C)
    local ncxidx = u32(header, 0xF4)
    local dividx, skelidx = u32(header, 0xF8), u32(header, 0xFC)
    if skelidx == NULL_INDEX or dividx == NULL_INDEX then error("KF8 has no SKEL/DIV indexes") end
    local metadata = exth(header)

    local chunks = {}
    for sec0 = 1, u16(header, 8) do
        local data = secs[sec0 + 1] or error("missing text record " .. sec0)
        data = data:sub(1, #data - trailingSize(data, extra_flags))
        chunks[#chunks + 1] = compression == 2 and palmdoc(data) or data
    end
    local raw_ml = table.concat(chunks)
    chunks = nil

    local flows = { raw_ml }
    if fdstidx ~= NULL_INDEX and fdstidx ~= 0 then
        local fd = secs[fdstidx + 1]
        if not fd or fd:sub(1, 4) ~= "FDST" then error("invalid KF8 FDST record") end
        flows = {}
        for i = 0, u32(fd, 8) - 1 do
            flows[#flows + 1] = raw_ml:sub(u32(fd, 12 + i * 8) + 1, u32(fd, 16 + i * 8))
        end
    end

    local skels = readIndex(secs, skelidx)
    local divs, div_cncx = readIndex(secs, dividx)
    local parts = buildParts(flows[1], skels, divs, div_cncx)

    local resources = {}
    if first_image ~= NULL_INDEX then
        for sec0 = first_image, #secs - 1 do
            local data = secs[sec0 + 1]
            local ext = imageExt(data)
            if ext then
                local name = string.format("res%04d.%s", sec0 - first_image + 1, ext)
                writeFile(dir .. "/" .. name, data)
                resources[sec0 - first_image + 1] = name
            end
        end
    end
    local function embed(id)
        local n = b32decode(id)
        return n and resources[n] or ""
    end

    local flow_names, css_links = {}, {}
    for i = 2, #flows do
        local data = flows[i]
        local ext = data:find("<svg", 1, true) and "svg" or "css"
        local name = string.format("flow%04d.%s", i - 1, ext)
        flow_names[i - 1] = name
        local pattern = ext == "css" and "kindle:embed:([0-9A-Va-v]+)[^%)%s\"']*" or "kindle:embed:([0-9A-Va-v]+)[^\"']*"
        writeFile(dir .. "/" .. name, (data:gsub(pattern, embed)))
        if ext == "css" then
            css_links[#css_links + 1] = '<link rel="stylesheet" type="text/css" href="' .. name .. '"/>'
        end
    end

    local toc = {}
    if ncxidx ~= NULL_INDEX then
        local entries, cncx = readIndex(secs, ncxidx)
        for _, e in ipairs(entries) do
            local title = e.tags[3] and cncx[e.tags[3][1]]
            local fid = e.tags[6] and e.tags[6][1]
            if title and fid then
                toc[#toc + 1] = {
                    title = Text.xmlDecode(title),
                    depth = (e.tags[4] and e.tags[4][1] or 0) + 1,
                    anchor = "#azwfid" .. b32encode(fid),
                    fid = fid,
                    seq = #toc + 1,
                }
            end
        end
        -- NCX 按层级存（先全部一级，再二级）；KOReader 要正文顺序，同位置父级在前
        table.sort(toc, function(a, b)
            if a.fid ~= b.fid then return a.fid < b.fid end
            if a.depth ~= b.depth then return a.depth < b.depth end
            return a.seq < b.seq
        end)
        for _, item in ipairs(toc) do item.fid, item.seq = nil, nil end
    end

    local bodies = {}
    for i, part in ipairs(parts) do
        bodies[i] = '<div id="azw-part-' .. i .. '" style="page-break-before:always">\n'
            .. Text.htmlBodyFragment(part) .. "\n</div>"
    end
    local body = table.concat(bodies, "\n")
        :gsub("kindle:embed:([0-9A-Va-v]+)[^\"']*", embed)
        :gsub("kindle:flow:([0-9A-Va-v]+)[^\"']*", function(id)
            local n = b32decode(id)
            return n and flow_names[n] or ""
        end)
        :gsub("kindle:pos:fid:([0-9A-Va-v]+):off:[0-9A-Va-v]+", function(fid)
            return "#azwfid" .. b32encode(b32decode(fid))
        end)

    writeFile(dir .. "/book.html", table.concat({
        '<!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml"><head>',
        '<meta charset="utf-8"/>',
        metadata.title and ("<title>" .. Text.xmlEscape(metadata.title) .. "</title>") or "",
        metadata.author and ('<meta name="author" content="' .. Text.xmlEscape(metadata.author) .. '"/>') or "",
        table.concat(css_links, "\n"),
        "</head><body>", body, "</body></html>",
    }, "\n"))

    local cover = metadata.cover_offset and resources[metadata.cover_offset + 1]
    metadata.cover_offset = nil
    return { html = "book.html", cover = cover, metadata = metadata, toc = toc }
end

return Kf8
