--[[--
修复下载的 TrueType 字体缺失空格：CRE 注册字体要求 U+0020 存在。
只追加空白字形与 Unicode 映射，不改变已有字形；原子替换，glyf 大表流式复制。

@module koplugin.book.ui.fonts.sfnt
--]]

local Sfnt = {}
local MOD = 4294967296

local function uint(s, pos, len)
    assert(pos > 0 and pos + len - 1 <= #s, "truncated sfnt table")
    local n = 0
    for i = pos, pos + len - 1 do n = n * 256 + s:byte(i) end
    return n
end

local function be(n, len)
    local bytes = {}
    for i = len, 1, -1 do
        bytes[i] = n % 256
        n = math.floor(n / 256)
    end
    return string.char(unpack(bytes))
end

local function replace(s, pos, data)
    return s:sub(1, pos - 1) .. data .. s:sub(pos + #data)
end

local function checksum(s)
    s = s .. ("\0"):rep(-#s % 4)
    local sum = 0
    for p = 1, #s, 4 do sum = (sum + uint(s, p, 4)) % MOD end
    return sum
end

local function read(f, offset, len)
    assert(f:seek("set", offset))
    local s = assert(f:read(len), "cannot read sfnt")
    assert(#s == len, "truncated sfnt")
    return s
end

--- 返回优先 Unicode cmap 的连续映射区间，以及空格是否已存在。
local function mappings(cmap)
    local best, priority = nil, 0
    local count = uint(cmap, 3, 2)
    for i = 0, count - 1 do
        local p = 5 + i * 8
        local platform, encoding = uint(cmap, p, 2), uint(cmap, p + 2, 2)
        local offset = uint(cmap, p + 4, 4) + 1
        local format = uint(cmap, offset, 2)
        if (platform == 0 or platform == 3 and (encoding == 1 or encoding == 10))
            and (format == 4 or format == 12) then
            local rank = (format == 12 and 10 or 0) + (platform == 3 and 2 or 1)
            if rank > priority then best, priority = offset, rank end
        end
    end
    assert(best, "no supported Unicode cmap")
    local groups, space = {}, false
    local function add(first, last, glyph)
        if first <= 32 and last >= 32 and glyph + 32 - first > 0 then space = true end
        groups[#groups + 1] = { first, last, glyph }
    end
    if uint(cmap, best, 2) == 12 then
        local n = uint(cmap, best + 12, 4)
        assert(n <= (#cmap - best - 15) / 12, "truncated format 12 cmap")
        for i = 0, n - 1 do
            local p = best + 16 + i * 12
            add(uint(cmap, p, 4), uint(cmap, p + 4, 4), uint(cmap, p + 8, 4))
        end
    else
        local n = uint(cmap, best + 6, 2) / 2
        for i = 0, n - 1 do
            local last = uint(cmap, best + 14 + i * 2, 2)
            local first = uint(cmap, best + 16 + n * 2 + i * 2, 2)
            local delta = uint(cmap, best + 16 + n * 4 + i * 2, 2)
            local p = best + 16 + n * 6 + i * 2
            local offset = uint(cmap, p, 2)
            for cp = first, math.min(last, 65534) do
                local glyph = offset == 0 and (cp + delta) % 65536
                    or uint(cmap, p + offset + (cp - first) * 2, 2)
                if offset ~= 0 and glyph ~= 0 then glyph = (glyph + delta) % 65536 end
                if glyph > 0 then
                    local prev = groups[#groups]
                    if prev and prev[2] + 1 == cp and prev[3] + cp - prev[1] == glyph then
                        prev[2] = cp
                        if cp == 32 then space = true end
                    else
                        add(cp, cp, glyph)
                    end
                end
            end
        end
    end
    return groups, space
end

local function withSpace(cmap, groups, glyph)
    local added = { { 32, 32, glyph } }
    for _idx, g in ipairs(groups) do
        if g[1] <= 32 and g[2] >= 32 then
            if g[1] < 32 then added[#added + 1] = { g[1], 31, g[3] } end
            if g[2] > 32 then added[#added + 1] = { 33, g[2], g[3] + 33 - g[1] } end
        else
            added[#added + 1] = g
        end
    end
    table.sort(added, function(a, b) return a[1] < b[1] end)
    local data = { be(12, 2), be(0, 2), be(16 + #added * 12, 4), be(0, 4), be(#added, 4) }
    for _idx, g in ipairs(added) do
        data[#data + 1] = be(g[1], 4) .. be(g[2], 4) .. be(g[3], 4)
    end
    -- 保留其它 cmap（含变体选择符）；替换/补齐 Unicode 与 Windows 的 format 12 入口。
    local count, records = uint(cmap, 3, 2), {}
    for i = 0, count - 1 do
        local p = 5 + i * 8
        local platform, encoding = uint(cmap, p, 2), uint(cmap, p + 2, 2)
        if not (platform == 0 and encoding == 4 or platform == 3 and encoding == 10) then
            records[#records + 1] = { platform, encoding, uint(cmap, p + 4, 4) }
        end
    end
    local shift = (#records + 2 - count) * 8
    local offset = #cmap + shift
    records[#records + 1] = { 0, 4, offset - shift }
    records[#records + 1] = { 3, 10, offset - shift }
    table.sort(records, function(a, b) return a[1] < b[1] or a[1] == b[1] and a[2] < b[2] end)
    local out = { be(0, 2), be(#records, 2) }
    for _idx, r in ipairs(records) do
        out[#out + 1] = be(r[1], 2) .. be(r[2], 2) .. be(r[3] + shift, 4)
    end
    out[#out + 1] = cmap:sub(5 + count * 8)
    out[#out + 1] = table.concat(data)
    return table.concat(out)
end

local function repair(src, out)
    local size = assert(src:seek("end"))
    local header = read(src, 0, 12)
    if header:sub(1, 4) ~= "\0\1\0\0" then return false end
    local count = uint(header, 5, 2)
    local directory = read(src, 12, count * 16)
    local entries, tables = {}, {}
    for i = 0, count - 1 do
        local p = i * 16 + 1
        local e = { tag = directory:sub(p, p + 3), sum = uint(directory, p + 4, 4),
            offset = uint(directory, p + 8, 4), len = uint(directory, p + 12, 4) }
        assert(e.offset + e.len <= size, "sfnt table out of bounds")
        entries[#entries + 1], tables[e.tag] = e, e
    end
    local function tableData(tag)
        local e = assert(tables[tag], "missing sfnt table " .. tag)
        return read(src, e.offset, e.len)
    end
    local cmap = tableData("cmap")
    local groups, has_space = mappings(cmap)
    if has_space then return false end
    local head, maxp, hhea = tableData("head"), tableData("maxp"), tableData("hhea")
    local loca, hmtx = tableData("loca"), tableData("hmtx")
    local glyphs, metrics = uint(maxp, 5, 2), uint(hhea, 35, 2)
    assert(glyphs < 65535 and metrics > 0 and metrics <= glyphs, "invalid sfnt glyph metrics")
    assert(not tables.gvar, "cannot append a glyph to a variable TrueType font")
    assert(#hmtx >= metrics * 4 + (glyphs - metrics) * 2, "truncated horizontal metrics")
    local loc_size = uint(head, 51, 2) == 0 and 2 or 4
    assert(#loca >= (glyphs + 1) * loc_size and tables.glyf, "invalid TrueType outlines")
    -- 空字形的 loca 起止相同；无需复制/扩充几十 MB 的 glyf 表。
    tables.loca.data = loca:sub(1, (glyphs + 1) * loc_size)
        .. loca:sub(glyphs * loc_size + 1, (glyphs + 1) * loc_size)
    tables.maxp.data = replace(maxp, 5, be(glyphs + 1, 2))
    tables.head.data = replace(head, 9, be(0, 4))
    tables.hhea.data = replace(hhea, 35, be(glyphs + 1, 2))
    local widths = { hmtx:sub(1, metrics * 4) }
    for i = metrics, glyphs - 1 do
        widths[#widths + 1] = hmtx:sub(metrics * 4 - 3, metrics * 4 - 2)
            .. be(uint(hmtx, metrics * 4 + (i - metrics) * 2 + 1, 2), 2)
    end
    widths[#widths + 1] = be(math.floor(uint(head, 19, 2) / 4), 2) .. be(0, 2)
    tables.hmtx.data = table.concat(widths)
    tables.cmap.data = withSpace(cmap, groups, glyphs)
    local offset, records = 12 + count * 16, { header }
    for _idx, e in ipairs(entries) do
        if e.data then e.len, e.sum = #e.data, checksum(e.data) end
        records[#records + 1] = e.tag .. be(e.sum, 4) .. be(offset, 4) .. be(e.len, 4)
        offset = offset + e.len + -e.len % 4
    end
    local dir = table.concat(records)
    local sum = checksum(dir)
    for _idx, e in ipairs(entries) do sum = (sum + e.sum) % MOD end
    tables.head.data = replace(tables.head.data, 9, be((0xB1B0AFBA - sum) % MOD, 4))
    assert(out:write(dir))
    for _idx, e in ipairs(entries) do
        if e.data then
            assert(out:write(e.data))
        else
            assert(src:seek("set", e.offset))
            local left = e.len
            while left > 0 do
                local chunk = assert(src:read(math.min(left, 65536)), "truncated sfnt")
                assert(#chunk > 0, "truncated sfnt")
                assert(out:write(chunk))
                left = left - #chunk
            end
        end
        assert(out:write(("\0"):rep(-e.len % 4)))
    end
    assert(out:flush())
    return true
end

--- 仅修复缺少空格的 TrueType；其它格式/已有空格返回 false，IO/格式错误返回 nil, err。
---@param path string 插件拥有的字体文件
---@return boolean|nil changed
---@return string|nil err
function Sfnt.ensureSpace(path)
    local src, err = io.open(path, "rb")
    if not src then return nil, err end
    local part = path .. ".space.part"
    local out
    out, err = io.open(part, "wb")
    if not out then src:close(); return nil, err end
    local ok, changed = pcall(repair, src, out)
    src:close()
    local closed, close_err = out:close()
    if not ok or not closed then
        os.remove(part)
        return nil, tostring(not ok and changed or close_err)
    end
    if not changed then
        os.remove(part)
        return false
    end
    local renamed, rename_err = os.rename(part, path)
    if not renamed then
        os.remove(part)
        return nil, rename_err
    end
    return true
end

return Sfnt
