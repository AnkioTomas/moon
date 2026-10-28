--[[--
KF8（AZW3）→ 单文件 HTML + 资源，交给 CREngine 渲染。

移植自 azwreader-koreader 的 kf8extractor（按 Calibre mobi8 reader 核对过偏移）：
PalmDB 分节 → 文本记录解压（无压缩 / PalmDOC / HUFF·CDIC）→ FDST 切流 → SKEL/DIV 索引重建 XHTML
→ 改写 kindle:embed / kindle:flow / kindle:pos 引用。

只处理独立 KF8（MOBI 版本 8）。MOBI6 与 MOBI6+KF8 合并文件返回 nil：CREngine 能直接按 MOBI 读。
DRM、结构损坏直接 error。HUFF/CDIC 见 `features.azw3.huff`。

  local info = Kf8.extract(path, dir)
  -- info = { html = "book.html", cover = "res0003.jpg"|nil, metadata = {...}, toc = { { title, depth, anchor } } }

@module koplugin.book.features.azw3.kf8
--]]

local bit = require("bit")
local ffi = require("ffi")
require("ffi/posix_h")
local Image = require("utils.image")
local Text = require("utils.text")

local Kf8 = {}

local NULL_INDEX = 0xFFFFFFFF
local B32 = "0123456789ABCDEFGHIJKLMNOPQRSTUV"
-- kindle:embed/flow 引用尾巴（?mime=...）：遇引号、空白或 ")" 即止，行内 style 的 url(...) 后续声明不能被吞
local REF_TAIL = "[^%)%s\"']*"
local EMBED = "kindle:embed:([0-9A-Va-v]+)" .. REF_TAIL

---@class Kf8TocItem
---@field title string
---@field depth number
---@field anchor string CREngine 可解析的 "#id" 引用

---@class Kf8Info
---@field dir string|nil 缓存目录；probe 结果没有，重建后才有
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

--- 读 PalmDB 分节表与 MOBI 头，按需 seek 取节（不整本读入内存）。
--- section(sec0) 越界返回 nil，截断报错。非独立 KF8（MOBI 版本不是 8）时 header 为 nil。
---@return fun(sec0: number): string|nil section, number count, string|nil header
local function openBook(f)
    local pdb = f:read(78) or ""
    if #pdb < 78 or pdb:sub(61, 68) ~= "BOOKMOBI" then error("not a BOOKMOBI container") end
    local count = u16(pdb, 76)
    local table_raw = f:read(count * 8) or ""
    local offsets = {}
    for i = 0, count - 1 do
        offsets[i + 1] = u32(table_raw, i * 8)
    end
    offsets[count + 1] = f:seek("end")
    local function section(sec0)
        local from, to = offsets[sec0 + 1], offsets[sec0 + 2]
        if not to then return nil end
        if to < from then error("invalid PalmDB section " .. sec0) end
        f:seek("set", from)
        local data = f:read(to - from) or ""
        if #data ~= to - from then error("truncated PalmDB section " .. sec0) end
        return data
    end
    local header = section(0) or ""
    if header:sub(17, 20) ~= "MOBI" then error("missing MOBI header") end
    return section, count, u32(header, 36) == 8 and header or nil
end

--- 打开文件跑 fn(f, ...)，出错也关闭句柄后原样抛出；写文件时 close 失败（刷盘）同样报错。
local function withFile(path, mode, fn, ...)
    local f = assert(io.open(path, mode))
    local ok, result = pcall(fn, f, ...)
    local closed, err = f:close()
    if not ok then error(result, 0) end
    assert(closed, err)
    return result
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

--- PalmDOC 解压 data 的前 size 字节到 dst，返回输出字节数。
--- dst 至少 size * 5 字节：最坏是 2 字节反向引用展开成 10 字节。
local function palmdoc(data, size, dst)
    local src = ffi.cast("const uint8_t *", data)
    local n, i = 0, 0
    while i < size do
        local c = src[i]
        i = i + 1
        if c >= 1 and c <= 8 then
            local run = math.min(c, size - i)
            ffi.copy(dst + n, src + i, run)
            n, i = n + run, i + run
        elseif c < 0x80 then
            dst[n] = c
            n = n + 1
        elseif c >= 0xC0 then
            dst[n], dst[n + 1] = 0x20, bit.bxor(c, 0x80)
            n = n + 2
        else
            if i >= size then error("truncated PalmDOC backreference") end
            local pair = c * 256 + src[i]
            i = i + 1
            local dist = bit.rshift(bit.band(pair, 0x3FFF), 3)
            if dist == 0 or dist > n then error("invalid PalmDOC backreference") end
            for _i = 1, bit.band(pair, 7) + 3 do
                dst[n] = dst[n - dist]
                n = n + 1
            end
        end
    end
    return n
end

--- malloc 而非 ffi.new：几十 MB 的正文若算进 GC 堆，回收阈值（默认存活量 2 倍）跟着抬高，
--- 切片产生的垃圾要攒到同样大小才回收；放在堆外峰值约省一份正文大小。
local function alloc(size)
    local p = ffi.C.malloc(math.max(size, 1))
    if p == nil then error("out of memory for KF8 text (" .. size .. " bytes)") end
    return ffi.gc(ffi.cast("uint8_t *", p), ffi.C.free)
end

--- 全部文本记录解压进一块 ffi 缓冲：整本正文只此一份，后续按需切片，不在 Lua 堆里反复拷贝。
---@return ffi.cdata* buf, number n 字节数
local function readText(section, header)
    local compression = u16(header, 0)
    if compression ~= 1 and compression ~= 2 and compression ~= 0x4448 then
        error("unknown MOBI compression " .. compression)
    end
    local unpack_huff
    if compression == 0x4448 then
        local huff0, huff_n = u32(header, 0x70), u32(header, 0x74)
        if huff0 == NULL_INDEX or huff_n == 0 then error("missing HUFF/CDIC records") end
        local huffs = {}
        for i = 0, huff_n - 1 do
            huffs[#huffs + 1] = section(huff0 + i) or error("missing HUFF/CDIC record " .. (huff0 + i))
        end
        unpack_huff = require("features.azw3.huff").reader(huffs)
    end
    local extra_flags = #header >= 0xF4 and u16(header, 0xF2) or 0
    local records = u16(header, 8)
    -- 头里的文本长度通常正好够；按记录数封顶，防坏头一次申请巨块内存
    local cap = math.min(u32(header, 4), records * u16(header, 10))
    local buf, n = alloc(cap), 0
    local scratch, scratch_cap = nil, 0
    for sec0 = 1, records do
        local data = section(sec0) or error("missing text record " .. sec0)
        local size = #data - trailingSize(data, extra_flags)
        if size < 0 then error("corrupt MOBI trailing data") end
        local src, len = data, size
        if compression == 2 then
            if scratch_cap < size * 5 then
                scratch_cap = size * 5
                scratch = ffi.new("uint8_t[?]", scratch_cap)
            end
            src, len = scratch, palmdoc(data, size, scratch)
        elseif compression == 0x4448 then
            local plain = unpack_huff(data:sub(1, size))
            src, len = plain, #plain
        end
        if n + len > cap then
            cap = math.max(n + len, math.floor(cap * 1.5))
            local grown = alloc(cap)
            ffi.copy(grown, buf, n)
            buf = grown
        end
        ffi.copy(buf + n, src, len)
        n = n + len
    end
    return buf, n
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
    for _idx, x in ipairs(tags) do
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
    for _idx, x in ipairs(pending) do
        local vals = {}
        if x.count then
            for _i = 1, x.count * x.num_values do
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
local function readIndex(section, idx0)
    local master = section(idx0) or error("missing INDX record " .. idx0)
    local mh = indxHeader(master)
    local control_count, tags = tagx(master, mh.tagx)
    local entries = {}
    for sec0 = idx0 + 1, idx0 + mh.count do
        local data = section(sec0) or error("missing INDX record " .. sec0)
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
        local data = section(idx0 + mh.count + 1 + k) or ""
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

local function exth(header)
    local meta = {}
    local pos = 16 + u32(header, 20)
    if header:sub(pos + 1, pos + 4) ~= "EXTH" then return meta end
    local authors = {}
    local p = pos + 12
    for _i = 1, u32(header, pos + 8) do
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
    -- 往回找最近的 '<' / '>'，不复制前缀：每个 DIV 都要判一次，骨架可能很大
    for p = math.min(ip, #s), 1, -1 do
        local c = s:byte(p)
        if c == 60 then return true end
        if c == 62 then break end
    end
    local gt, lt = s:find(">", ip + 1, true), s:find("<", ip + 1, true)
    return gt ~= nil and (lt == nil or gt < lt)
end

--- 含 aid 属性的标签结束位置（1 起，指向 '>'）。
local function aidTagEnd(s, aid)
    local p = s:find('aid="' .. aid .. '"', 1, true) or s:find("aid='" .. aid .. "'", 1, true)
    return p and s:find(">", p, true)
end

--- 按 SKEL/DIV 索引把分片插回骨架，逐个部分交给 emit（不攒整本）。
---@param text fun(from: number, to: number): string 主流 [from, to) 切片
---@param emit fun(part: string)
local function buildParts(text, skels, divs, div_cncx, emit)
    local divptr = 1
    for _idx, sk in ipairs(skels) do
        local t1, t6 = sk.tags[1], sk.tags[6]
        if not t1 or not t6 then error("malformed SKEL index") end
        local skelpos = t6[1]
        local baseptr = skelpos + t6[2]
        local skeleton = text(skelpos, baseptr)
        local anchors = {}
        for _i = 1, t1[1] do
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
            skeleton = skeleton:sub(1, ip) .. text(baseptr, baseptr + length) .. skeleton:sub(ip + 1)
            anchors[#anchors + 1] = { fid = divptr - 1, pos = ip }
            baseptr = baseptr + length
            divptr = divptr + 1
        end
        -- 锚点必须在整段重建完后从右往左插：DIV 偏移指向未改动的骨架
        table.sort(anchors, function(a, b) return a.pos > b.pos end)
        for _idx, a in ipairs(anchors) do
            skeleton = skeleton:sub(1, a.pos) .. '<a id="azwfid' .. b32encode(a.fid) .. '"></a>' .. skeleton:sub(a.pos + 1)
        end
        emit(skeleton)
    end
end

local function probeFile(f)
    local section, _count, header = openBook(f)
    if not header then return nil end
    local metadata = exth(header)
    local first_image = u32(header, 0x6C)
    local cover = metadata.cover_offset and first_image ~= NULL_INDEX
        and section(first_image + metadata.cover_offset)
    metadata.cover_offset = nil
    return { metadata = metadata, cover_data = cover and Image.ext(cover) and cover or nil }
end

--- 只读 PalmDB 分节表、MOBI 头（EXTH）与封面记录，不解压正文：书名/作者/简介/封面够用。
--- DRM / 正文解压失败只影响 extract，这里不拦。
---@param path string
---@return { metadata: table, cover_data: string|nil }|nil 非独立 KF8 时为 nil
function Kf8.probe(path)
    return withFile(path, "rb", probeFile)
end

local function extractFile(f, dir)
    local section, count, header = openBook(f)
    if not header then return nil end
    if require("utils.mobi").encryption(header) ~= 0 then error("DRM-encrypted AZW3 is not supported") end
    local fdstidx = u32(header, 0xC0)
    local first_image = u32(header, 0x6C)
    local ncxidx = u32(header, 0xF4)
    local dividx, skelidx = u32(header, 0xF8), u32(header, 0xFC)
    if skelidx == NULL_INDEX or dividx == NULL_INDEX then error("KF8 has no SKEL/DIV indexes") end
    local metadata = exth(header)

    local buf, n = readText(section, header)
    -- [from, to) 切片，越界按 string.sub 截断
    local function slice(from, to)
        from, to = math.max(from, 0), math.min(to, n)
        return to > from and ffi.string(buf + from, to - from) or ""
    end

    -- 流按 [起, 止) 记；主流（flows[1]）很大，只记范围不切出来
    local flows = { { 0, n } }
    if fdstidx ~= NULL_INDEX and fdstidx ~= 0 then
        local fd = section(fdstidx)
        if not fd or fd:sub(1, 4) ~= "FDST" then error("invalid KF8 FDST record") end
        flows = {}
        for i = 0, u32(fd, 8) - 1 do
            flows[#flows + 1] = { u32(fd, 12 + i * 8), u32(fd, 16 + i * 8) }
        end
    end
    local main_from, main_to = flows[1][1], math.min(flows[1][2], n)
    local function mainText(from, to)
        return slice(main_from + math.max(from, 0), main_from + math.min(to, main_to - main_from))
    end

    local resources = {}
    if first_image ~= NULL_INDEX then
        for sec0 = first_image, count - 1 do
            local data = section(sec0)
            local ext = Image.ext(data)
            if ext then
                local name = string.format("res%04d%s", sec0 - first_image + 1, ext)
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
        local data = slice(flows[i][1], flows[i][2])
        local ext = data:find("<svg", 1, true) and "svg" or "css"
        local name = string.format("flow%04d.%s", i - 1, ext)
        flow_names[i - 1] = name
        writeFile(dir .. "/" .. name, (data:gsub(EMBED, embed)))
        if ext == "css" then
            css_links[#css_links + 1] = '<link rel="stylesheet" type="text/css" href="' .. name .. '"/>'
        end
    end

    local toc = {}
    if ncxidx ~= NULL_INDEX then
        local entries, cncx = readIndex(section, ncxidx)
        for _idx, e in ipairs(entries) do
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
        for _idx, item in ipairs(toc) do item.fid, item.seq = nil, nil end
    end

    local function flowName(id)
        local i = b32decode(id)
        return i and flow_names[i] or ""
    end
    local function posAnchor(fid)
        return "#azwfid" .. b32encode(b32decode(fid))
    end
    local skels = readIndex(section, skelidx)
    local divs, div_cncx = readIndex(section, dividx)
    -- 逐部分改写引用后直接落盘：整本 HTML 不进内存
    withFile(dir .. "/book.html", "wb", function(out)
        assert(out:write(table.concat({
            '<!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml"><head>',
            '<meta charset="utf-8"/>',
            metadata.title and ("<title>" .. Text.xmlEscape(metadata.title) .. "</title>") or "",
            metadata.author and ('<meta name="author" content="' .. Text.xmlEscape(metadata.author) .. '"/>') or "",
            table.concat(css_links, "\n"),
            "</head><body>",
        }, "\n")))
        local i = 0
        buildParts(mainText, skels, divs, div_cncx, function(part)
            i = i + 1
            local body = Text.htmlBodyFragment(part)
            if body:find("kindle:", 1, true) then
                body = body:gsub(EMBED, embed)
                    :gsub("kindle:flow:([0-9A-Va-v]+)" .. REF_TAIL, flowName)
                    :gsub("kindle:pos:fid:([0-9A-Va-v]+):off:[0-9A-Va-v]+", posAnchor)
            end
            assert(out:write('\n<div id="azw-part-', i, '" style="page-break-before:always">\n', body, "\n</div>"))
        end)
        assert(out:write("\n</body></html>"))
    end)

    local cover = metadata.cover_offset and resources[metadata.cover_offset + 1]
    metadata.cover_offset = nil
    return { html = "book.html", cover = cover, metadata = metadata, toc = toc }
end

--- 解析独立 KF8 并把 HTML / CSS / 图片写进 dir（目录须已存在）。
---@param path string
---@param dir string
---@return Kf8Info|nil info 非独立 KF8（MOBI6 / 合并文件）时为 nil
function Kf8.extract(path, dir)
    return withFile(path, "rb", extractFile, dir)
end

return Kf8
