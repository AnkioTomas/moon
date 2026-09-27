--[[--
最小 KF8（AZW3）样本生成器：两部分正文 + 一张图 + NCX 目录。

  local Fixture = require("support.kf8_fixture")
  Fixture.write(path, { version = 8, compression = 2, extra_flags = 1, encryption = 0 })

- 第二部分的 DIV 插入点故意落在 <body> 标签内部，走 aid 修复路径。
- compression = 2 时用 PalmDOC 压缩（含字面串、空格+字符、回溯引用三种编码）。
- extra_flags = 1 时每条文本记录末尾追加 1 字节多字节尾巴。

@module tests.support.kf8_fixture
--]]

local bit = require("bit")

local Fixture = {}

local SKEL1 = '<html><head><link href="kindle:flow:0001?mime=text/css" rel="stylesheet"/></head><body aid="0"></body></html>'
local FRAG1 = '<p>第一章 开头 Hello Hello Hello</p><img src="kindle:embed:0001?mime=image/jpeg"/>'
local SKEL2 = '<html><head></head><body aid="1"></body></html>'
local FRAG2 = '<p>第二章 <a href="kindle:pos:fid:0000:off:0000000000">回到开头</a></p>'
local CSS = 'p { text-indent: 2em; } .bg { background: url(kindle:embed:0001?mime=image/jpeg); }'
local IMAGE = "\255\216\255\224fake-jpeg"

Fixture.TITLE = "测试书"
Fixture.AUTHOR = "作者甲"

local function be16(n) return string.char(bit.band(bit.rshift(n, 8), 255), bit.band(n, 255)) end
local function be32(n)
    return string.char(bit.band(bit.rshift(n, 24), 255), bit.band(bit.rshift(n, 16), 255),
        bit.band(bit.rshift(n, 8), 255), bit.band(n, 255))
end

--- 正向变长整数（末字节高位置 1）。
local function varint(n)
    local bytes = { bit.bor(bit.band(n, 0x7F), 0x80) }
    n = bit.rshift(n, 7)
    while n > 0 do
        table.insert(bytes, 1, bit.band(n, 0x7F))
        n = bit.rshift(n, 7)
    end
    return string.char(unpack(bytes))
end

--- 在 s 的指定偏移写入 data（s 长度不足时补零）。
local function put(s, offset, data)
    if #s < offset then s = s .. string.rep("\0", offset - #s) end
    return s:sub(1, offset) .. data .. s:sub(offset + #data + 1)
end

--- PalmDOC 压缩：回溯引用（≥3 字节）> 空格+字符 > 字面串。
local function palmdoc(src)
    local out, i, n = {}, 1, #src
    while i <= n do
        local best_len, best_dist = 0, 0
        for dist = 1, math.min(i - 1, 2047) do
            local len = 0
            while len < 10 and i + len <= n and src:byte(i + len) == src:byte(i - dist + len) do
                len = len + 1
            end
            if len > best_len then best_len, best_dist = len, dist end
        end
        local c, nx = src:byte(i), src:byte(i + 1)
        if best_len >= 3 then
            local pair = bit.bor(0x8000, bit.lshift(best_dist, 3), best_len - 3)
            out[#out + 1] = be16(pair)
            i = i + best_len
        elseif c == 0x20 and nx and nx >= 0x40 and nx <= 0x7F then
            out[#out + 1] = string.char(bit.bxor(nx, 0x80))
            i = i + 2
        elseif c >= 0x09 and c <= 0x7F then
            out[#out + 1] = string.char(c)
            i = i + 1
        else
            local run = math.min(8, n - i + 1)
            out[#out + 1] = string.char(run) .. src:sub(i, i + run - 1)
            i = i + run
        end
    end
    return table.concat(out)
end

--- INDX 主记录 + 数据记录。entries = { { ident, control, values = {...} } }
local function indx(tags, entries, ncncx)
    local tagx = "TAGX" .. be32(12 + 4 * (#tags + 1)) .. be32(1)
    for _, t in ipairs(tags) do tagx = tagx .. string.char(t[1], t[2], t[3], 0) end
    tagx = tagx .. string.char(0, 0, 0, 1)
    local master = put(put(put(put("INDX", 24, be32(1)), 52, be32(ncncx or 0)), 180, be32(192)), 192, tagx)

    local body, offsets = "", {}
    for _, e in ipairs(entries) do
        offsets[#offsets + 1] = 192 + #body
        local rec = string.char(#e.ident) .. e.ident .. string.char(e.control)
        for _, v in ipairs(e.values) do rec = rec .. varint(v) end
        body = body .. rec
    end
    local idxt_at = 192 + #body
    local idxt = "IDXT"
    for _, o in ipairs(offsets) do idxt = idxt .. be16(o) end
    local data = put(put(put("INDX", 20, be32(idxt_at)), 24, be32(#entries)), 192, body .. idxt)
    return master, data
end

local function cncx(strings)
    local out, offsets = "", {}
    for i, s in ipairs(strings) do
        offsets[i] = #out
        out = out .. varint(#s) .. s
    end
    return out, offsets
end

local function exth(records)
    local body = ""
    for _, r in ipairs(records) do body = body .. be32(r[1]) .. be32(8 + #r[2]) .. r[2] end
    return "EXTH" .. be32(12 + #body) .. be32(#records) .. body
end

---@param path string
---@param opts table|nil version/compression/extra_flags/encryption
function Fixture.write(path, opts)
    opts = opts or {}
    local version = opts.version or 8
    local compression = opts.compression or 1
    local extra_flags = opts.extra_flags or 0

    local flow0 = SKEL1 .. FRAG1 .. SKEL2 .. FRAG2
    local text = flow0 .. CSS
    local record = compression == 2 and palmdoc(text) or text
    if bit.band(extra_flags, 1) == 1 then record = record .. "\0" end

    local skel2_pos = #SKEL1 + #FRAG1
    local ins1 = #SKEL1 - #"</body></html>"
    local ins2_bad = skel2_pos + #SKEL2 - #"</body></html>" - 3 -- 落在 <body aid="1"> 里

    local div_cncx, div_off = cncx({ "P-//*[@aid='0']", "P-//*[@aid='1']" })
    local ncx_cncx, ncx_off = cncx({ "第一章", "第二章", "第一节" })

    local skel_m, skel_d = indx({ { 1, 1, 0x01 }, { 6, 2, 0x02 } }, {
        { ident = "SKEL0000", control = 0x03, values = { 1, 0, #SKEL1 } },
        { ident = "SKEL0001", control = 0x03, values = { 1, skel2_pos, #SKEL2 } },
    })
    local div_m, div_d = indx({ { 2, 1, 0x01 }, { 6, 2, 0x02 } }, {
        { ident = tostring(ins1), control = 0x03, values = { div_off[1], 0, #FRAG1 } },
        { ident = tostring(ins2_bad), control = 0x03, values = { div_off[2], 0, #FRAG2 } },
    }, 1)
    -- NCX 按层级存：一级在前，二级「第一节」排最后但指向第一部分
    local ncx_m, ncx_d = indx({ { 3, 1, 0x01 }, { 4, 1, 0x02 }, { 6, 2, 0x04 } }, {
        { ident = "0", control = 0x07, values = { ncx_off[1], 0, 0, 0 } },
        { ident = "1", control = 0x07, values = { ncx_off[2], 0, 1, 0 } },
        { ident = "2", control = 0x07, values = { ncx_off[3], 1, 0, 0 } },
    }, 1)
    local fdst = "FDST" .. be32(12) .. be32(2) .. be32(0) .. be32(#flow0) .. be32(#flow0) .. be32(#text)

    -- 记录序号：0 头 1 正文 2-3 SKEL 4-6 DIV 7-9 NCX 10 FDST 11 图片 12 非图片
    local header = be16(compression) .. be16(0) .. be32(#text) .. be16(1) .. be16(4096)
        .. be16(opts.encryption or 0) .. be16(0)
    header = put(header, 16, "MOBI" .. be32(0x108 - 16))
    header = put(header, 36, be32(version))
    header = put(header, 0x6C, be32(11))
    header = put(header, 0xC0, be32(10))
    header = put(header, 0xF2, be16(extra_flags))
    header = put(header, 0xF4, be32(7))
    header = put(header, 0xF8, be32(4))
    header = put(header, 0xFC, be32(2))
    header = put(header, 0x104, be32(0xFFFFFFFF))
    header = header .. exth({ { 100, Fixture.AUTHOR }, { 503, Fixture.TITLE }, { 201, be32(0) } })

    local records = { header, record, skel_m, skel_d, div_m, div_d, div_cncx, ncx_m, ncx_d, ncx_cncx, fdst, IMAGE, "FLIS0000" }
    local pdb = put(string.rep("\0", 60) .. "BOOKMOBI", 76, be16(#records))
    local offset = 78 + 8 * #records + 2
    local table_part, data_part = "", ""
    for i, r in ipairs(records) do
        table_part = table_part .. be32(offset + #data_part) .. be32(i - 1)
        data_part = data_part .. r
    end
    local f = assert(io.open(path, "wb"))
    f:write(pdb .. table_part .. "\0\0" .. data_part)
    f:close()
end

return Fixture
