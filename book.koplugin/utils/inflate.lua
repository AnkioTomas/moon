--[[--
deflate / zlib / gzip 解压，分块输出。

三层，只在进程里选一次，解失败不换层（换层会把坏流再解出另一份结果）：

1. 直接 dlopen 系统 libz（ffi.load，不经过 KOReader 的重定向）
2. KOReader 的 ffi.loadlib("z", 1)（模拟器和旧构建是完整 libz；设备上是 monolibtic）
3. 纯 Lua。monolibtic 的导出表只有 compress2 / compressBound / crc32 / uncompress，
   没有 inflateInit2_。uncompress 不解 raw / gzip，也不能分块，兜底不用它。

不整表分配输出缓冲：大 CJK 字体的 glyf 表有几十 MB，一次性解压会在小内存设备上 OOM；
调用方要整串就在 sink 里 concat。Lua 路径峰值是 32KB 滑窗加 64KB 输出块。

@module koplugin.book.utils.inflate
--]]

local ffi = require("ffi")
local bit = require("bit")
local band, bor, bxor, lshift, rshift = bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift

local Inflate = {}

local CHUNK = 65536
local WIN = 32768
local byte = string.byte

-- 长度码 257..285、距离码 0..29。下标从 1 起，距离码用 sym+1。
local LEN_BASE = {
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
}
local LEN_EXTRA = {
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
}
local DIST_BASE = {
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
}
local DIST_EXTRA = {
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
}
-- 动态块里码长字母表的存放顺序。
local CL_ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

local crc_table

local function crc_tables()
    if crc_table then return end
    crc_table = ffi.new("uint32_t[256]")
    for n = 0, 255 do
        local c = n
        for _bit = 1, 8 do
            if band(c, 1) == 1 then
                c = bxor(0xEDB88320, rshift(c, 1))
            else
                c = rshift(c, 1)
            end
        end
        crc_table[n] = c
    end
end

--- 比特反转后的查找表。lengths 下标从 0 起；空树（全是 0）可以，用到时再报错。
---@param lengths table
---@param nsym integer
---@return table|nil
local function build(lengths, nsym)
    local count = ffi.new("int[16]")
    local maxbits = 0
    for i = 0, nsym - 1 do
        local n = lengths[i] or 0
        if n > 15 then return nil end
        if n > 0 then
            count[n] = count[n] + 1
            if n > maxbits then maxbits = n end
        end
    end
    if maxbits == 0 then return { empty = true } end
    local left = 1
    for bits = 1, maxbits do
        left = left * 2 - count[bits]
        if left < 0 then return nil end
    end
    local next_code, code = {}, 0
    for bits = 1, maxbits do
        code = (code + count[bits - 1]) * 2
        next_code[bits] = code
    end
    local size = lshift(1, maxbits)
    local sym = ffi.new("int[?]", size)
    local len = ffi.new("uint8_t[?]", size)
    for i = 0, nsym - 1 do
        local n = lengths[i] or 0
        if n > 0 then
            local c = next_code[n]
            next_code[n] = c + 1
            local rev = 0
            for _bit = 1, n do
                rev = bor(lshift(rev, 1), band(c, 1))
                c = rshift(c, 1)
            end
            local step = lshift(1, n)
            for fill = rev, size - 1, step do
                sym[fill] = i
                len[fill] = n
            end
        end
    end
    return { sym = sym, len = len, maxbits = maxbits, mask = size - 1 }
end

local fixed_lit, fixed_dist

local function fixed_tables()
    if fixed_lit then return fixed_lit, fixed_dist end
    local lit = {}
    for i = 0, 143 do lit[i] = 8 end
    for i = 144, 255 do lit[i] = 9 end
    for i = 256, 279 do lit[i] = 7 end
    for i = 280, 287 do lit[i] = 8 end
    local dist = {}
    for i = 0, 31 do dist[i] = 5 end
    fixed_lit, fixed_dist = build(lit, 288), build(dist, 32)
    return fixed_lit, fixed_dist
end

local function format_of(window_bits)
    if window_bits < 0 then return "raw" end
    local extra = window_bits - 15
    if extra == 16 then return "gzip" end
    if extra == 32 then return "auto" end
    return "zlib"
end

local ZLIB_VERSION = "1.2.11"
-- inflateInit2_ 返回 -6 是 z_stream 尺寸和这份 so 对不上，这层不能用。
local VERSION_MISMATCH = {}
-- false：已经探过，没有带 inflate 的 so。nil：还没探。
local backend

local SO_NAMES = ffi.os == "OSX" and { "z" } or { "libz.so.1", "z" }

local function declare()
    for _idx, decl in ipairs({
        [[typedef struct {
            const unsigned char *next_in;
            unsigned int avail_in;
            unsigned long total_in;
            unsigned char *next_out;
            unsigned int avail_out;
            unsigned long total_out;
            const char *msg;
            void *state;
            void *(*zalloc)(void *, unsigned int, unsigned int);
            void (*zfree)(void *, void *);
            void *opaque;
            int data_type;
            unsigned long adler;
            unsigned long reserved;
        } moon_z_stream;]],
        "int inflateInit2_(void *, int, const char *, int);",
        "int inflate(void *, int);",
        "int inflateEnd(void *);",
    }) do
        pcall(ffi.cdef, decl)
    end
end

local function has_inflate(lib)
    return pcall(function() return lib.inflateInit2_ end)
end

--- 系统 so 优先，其次 KOReader 装进来的 libz。都没有 inflate 就返回 nil，走 Lua。
---@return any|nil
local function libz()
    if backend ~= nil then return backend or nil end
    declare()
    for _idx, name in ipairs(SO_NAMES) do
        local ok, lib = pcall(ffi.load, name)
        if ok and has_inflate(lib) then
            backend = lib
            return lib
        end
    end
    if ffi.loadlib then
        local ok, lib = pcall(ffi.loadlib, "z", 1)
        if ok and has_inflate(lib) then
            backend = lib
            return lib
        end
    end
    backend = false
    return nil
end

local function native_stream(z, data, offset, len, window_bits, sink, partial)
    local strm = ffi.new("moon_z_stream") --[[@as MoonZStream]]
    local zs = ffi.cast("void *", strm)
    local rc = z.inflateInit2_(zs, window_bits, ZLIB_VERSION, ffi.sizeof(strm))
    if rc == -6 then return nil, VERSION_MISMATCH end
    if rc ~= 0 then return nil, "inflateInit failed" end
    local buf = ffi.new("unsigned char[?]", CHUNK)
    strm.next_in = ffi.cast("const unsigned char *", data) + offset
    strm.avail_in = len
    local total, ret = 0, 0
    while ret == 0 do
        strm.next_out = buf
        strm.avail_out = CHUNK
        ret = z.inflate(zs, 0)
        if ret ~= 0 and ret ~= 1 then break end
        local n = CHUNK - strm.avail_out
        total = total + n
        if n > 0 then sink(ffi.string(buf, n)) end
        if ret == 0 and partial and strm.avail_in == 0 and strm.avail_out ~= 0 then ret = 1 end
    end
    z.inflateEnd(zs)
    if ret ~= 1 then return nil, "inflate failed: " .. ret end
    return total
end

--- 纯 Lua。空输入连 partial 也失败；有字节但头不完整才交给 partial。
---@param data string
---@param offset integer
---@param len integer
---@param window_bits integer
---@param sink fun(chunk: string)
---@param partial boolean|nil
---@return integer|nil total
---@return string|nil err
local function lua_stream(data, offset, len, window_bits, sink, partial)
    if len == 0 then return nil, "inflate failed: need" end

    local mode = format_of(window_bits)
    local pos, pend = offset + 1, offset + len
    local bitbuf, bitcnt = 0, 0
    local win = ffi.new("uint8_t[?]", WIN)
    local wpos, total = 0, 0
    local chunk = ffi.new("uint8_t[?]", CHUNK)
    local cpos = 0
    local s1, s2, crc = 1, 0, 0
    local want_adler, want_crc = false, false

    local function flush()
        if cpos == 0 then return end
        sink(ffi.string(chunk, cpos))
        cpos = 0
    end

    local function finish(kind)
        if kind == nil or (kind == "need" and partial) then
            flush()
            return total
        end
        return nil, "inflate failed: " .. kind
    end

    local function emit(b)
        win[wpos] = b
        wpos = band(wpos + 1, WIN - 1)
        chunk[cpos] = b
        cpos = cpos + 1
        total = total + 1
        if want_adler then
            s1 = s1 + b
            if s1 >= 65521 then s1 = s1 - 65521 end
            s2 = s2 + s1
            if s2 >= 65521 then s2 = s2 - 65521 end
        elseif want_crc then
            crc = bxor(crc_table[band(bxor(crc, b), 255)], rshift(crc, 8))
        end
        if cpos == CHUNK then flush() end
    end

    local function getbits(n)
        while bitcnt < n do
            if pos > pend then return nil end
            bitbuf = bor(bitbuf, lshift(byte(data, pos), bitcnt))
            bitcnt = bitcnt + 8
            pos = pos + 1
        end
        local v = band(bitbuf, lshift(1, n) - 1)
        bitbuf = rshift(bitbuf, n)
        bitcnt = bitcnt - n
        return v
    end

    -- 比特读取会为了凑满查找宽度多吃若干字节。对齐到下一字节时，整字节退回输入，
    -- 只丢掉当前字节里没用完的填充位。否则末块的预取会把 zlib/gzip 尾吃掉。
    local function align()
        while bitcnt >= 8 do
            bitcnt = bitcnt - 8
            pos = pos - 1
            bitbuf = band(bitbuf, lshift(1, bitcnt) - 1)
        end
        bitbuf, bitcnt = 0, 0
    end

    local function read_u16()
        if pend - pos + 1 < 2 then return nil end
        local v = byte(data, pos) + byte(data, pos + 1) * 256
        pos = pos + 2
        return v
    end

    local function read_u32(le)
        if pend - pos + 1 < 4 then return nil end
        local b1, b2, b3, b4 = byte(data, pos), byte(data, pos + 1), byte(data, pos + 2), byte(data, pos + 3)
        pos = pos + 4
        if le then return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216 end
        return ((b1 * 256 + b2) * 256 + b3) * 256 + b4
    end

    --- 返回符号；不够输入是 "need"，码非法是 "data"。符号 0 是合法值，不能当失败。
    local function decode(tree)
        if tree.empty then return nil, "data" end
        while bitcnt < tree.maxbits and pos <= pend do
            bitbuf = bor(bitbuf, lshift(byte(data, pos), bitcnt))
            bitcnt = bitcnt + 8
            pos = pos + 1
        end
        if bitcnt == 0 then return nil, "need" end
        local idx = band(bitbuf, tree.mask)
        local n = tree.len[idx]
        if n == 0 or n > bitcnt then
            if pos > pend and bitcnt < tree.maxbits then return nil, "need" end
            return nil, "data"
        end
        bitbuf = rshift(bitbuf, n)
        bitcnt = bitcnt - n
        return tree.sym[idx]
    end

    local function stored_block()
        align()
        local blen = read_u16()
        if blen == nil then return "need" end
        local nlen = read_u16()
        if nlen == nil then return "need" end
        if bxor(blen, 0xFFFF) ~= nlen then return "data" end
        local have = pend - pos + 1
        local take = have < blen and have or blen
        for i = 0, take - 1 do emit(byte(data, pos + i)) end
        pos = pos + take
        if take < blen then return "need" end
    end

    local function copy_match(distance, length)
        if distance == 0 or distance > WIN or distance > total then return "data" end
        for _i = 1, length do
            emit(win[band(wpos - distance, WIN - 1)])
        end
    end

    local function backref(dist, sym)
        local li = sym - 256
        if li > 29 then return "data" end
        local add = 0
        if LEN_EXTRA[li] > 0 then
            add = getbits(LEN_EXTRA[li])
            if add == nil then return "need" end
        end
        local ds, dkind = decode(dist)
        if ds == nil then return dkind end
        if ds > 29 then return "data" end
        local dadd = 0
        if DIST_EXTRA[ds + 1] > 0 then
            dadd = getbits(DIST_EXTRA[ds + 1])
            if dadd == nil then return "need" end
        end
        return copy_match(DIST_BASE[ds + 1] + dadd, LEN_BASE[li] + add)
    end

    local function codes(lit, dist)
        while true do
            local sym, kind = decode(lit)
            if sym == nil then return kind end
            if sym < 256 then
                emit(sym)
            elseif sym == 256 then
                return
            else
                local failed = backref(dist, sym)
                if failed then return failed end
            end
        end
    end

    local function dynamic_trees()
        local hlit = getbits(5)
        local hdist = getbits(5)
        local hclen = getbits(4)
        if hclen == nil then return nil, "need" end
        hlit, hdist, hclen = hlit + 257, hdist + 1, hclen + 4
        local cl = {}
        for i = 0, 18 do cl[i] = 0 end
        for i = 1, hclen do
            local n = getbits(3)
            if n == nil then return nil, "need" end
            cl[CL_ORDER[i]] = n
        end
        local cltree = build(cl, 19)
        if not cltree then return nil, "data" end
        local lens, n, idx = {}, hlit + hdist, 0
        while idx < n do
            local sym, kind = decode(cltree)
            if sym == nil then return nil, kind end
            if sym < 16 then
                lens[idx] = sym
                idx = idx + 1
            else
                local rep, val
                if sym == 16 then
                    if idx == 0 then return nil, "data" end
                    local extra = getbits(2)
                    if extra == nil then return nil, "need" end
                    rep, val = extra + 3, lens[idx - 1]
                elseif sym == 17 then
                    local extra = getbits(3)
                    if extra == nil then return nil, "need" end
                    rep, val = extra + 3, 0
                elseif sym == 18 then
                    local extra = getbits(7)
                    if extra == nil then return nil, "need" end
                    rep, val = extra + 11, 0
                else
                    return nil, "data"
                end
                if idx + rep > n then return nil, "data" end
                for _i = 1, rep do
                    lens[idx] = val
                    idx = idx + 1
                end
            end
        end
        local lit, dist = {}, {}
        for i = 0, hlit - 1 do lit[i] = lens[i] or 0 end
        for i = 0, hdist - 1 do dist[i] = lens[hlit + i] or 0 end
        lit, dist = build(lit, hlit), build(dist, hdist)
        if not lit or not dist then return nil, "data" end
        return lit, dist
    end

    local function zlib_header()
        if pend - pos + 1 < 2 then return "need" end
        local cmf, flg = byte(data, pos), byte(data, pos + 1)
        if (cmf * 256 + flg) % 31 ~= 0 then return "data" end
        if band(cmf, 15) ~= 8 or rshift(cmf, 4) > 7 then return "data" end
        if band(flg, 32) ~= 0 then return "data" end
        pos = pos + 2
    end

    local function skip_cstr()
        while true do
            if pos > pend then return "need" end
            local b = byte(data, pos)
            pos = pos + 1
            if b == 0 then return end
        end
    end

    local function gzip_header()
        if pend - pos + 1 < 10 then return "need" end
        if byte(data, pos) ~= 31 or byte(data, pos + 1) ~= 139 or byte(data, pos + 2) ~= 8 then
            return "data"
        end
        local flg = byte(data, pos + 3)
        if band(flg, 0xE0) ~= 0 then return "data" end
        pos = pos + 10
        if band(flg, 4) ~= 0 then
            local xlen = read_u16()
            if xlen == nil then return "need" end
            if pend - pos + 1 < xlen then return "need" end
            pos = pos + xlen
        end
        if band(flg, 8) ~= 0 then
            local kind = skip_cstr()
            if kind then return kind end
        end
        if band(flg, 16) ~= 0 then
            local kind = skip_cstr()
            if kind then return kind end
        end
        if band(flg, 2) ~= 0 then
            if pend - pos + 1 < 2 then return "need" end
            pos = pos + 2
        end
    end

    if mode == "auto" then
        if pend - pos + 1 < 2 then return finish("need") end
        if byte(data, pos) == 31 and byte(data, pos + 1) == 139 then
            mode = "gzip"
        else
            mode = "zlib"
        end
    end
    if mode == "gzip" then
        local kind = gzip_header()
        if kind then return finish(kind) end
        crc_tables()
        want_crc, crc = true, 0xFFFFFFFF
    elseif mode == "zlib" then
        local kind = zlib_header()
        if kind then return finish(kind) end
        want_adler = true
    end

    while true do
        local bfinal = getbits(1)
        local btype = getbits(2)
        if btype == nil then return finish("need") end
        local kind
        if btype == 0 then
            kind = stored_block()
        elseif btype == 1 then
            local lit, dist = fixed_tables()
            kind = codes(lit, dist)
        elseif btype == 2 then
            local lit, dist = dynamic_trees()
            if lit == nil then
                kind = dist
            else
                kind = codes(lit, dist)
            end
        else
            kind = "data"
        end
        if kind then return finish(kind) end
        if bfinal == 1 then break end
    end

    align()
    if mode == "zlib" then
        local sum = read_u32(false)
        if sum == nil then return finish("need") end
        if sum ~= s2 * 65536 + s1 then return finish("data") end
    elseif mode == "gzip" then
        local sum = read_u32(true)
        local isize = read_u32(true)
        if isize == nil then return finish("need") end
        -- bit 库给出的是有符号 32 位，尾部 crc 是无符号。
        local got = bxor(crc, 0xFFFFFFFF)
        if got < 0 then got = got + 4294967296 end
        if sum ~= got or isize ~= total % 4294967296 then return finish("data") end
    end
    return finish(nil)
end

--- 分块解压 data 里 [offset, offset+len) 的流，每块交给 sink，返回解出的总字节数。
---@param data string
---@param offset integer 0 起始
---@param len integer 压缩字节数
---@param window_bits integer -15 原始 deflate；15 zlib；15+16 gzip；15+32 自动识别 zlib / gzip
---@param sink fun(chunk: string)
---@param partial boolean|nil 为真时输入耗尽但流没走到结尾也算成功（容忍截断的载荷）
---@return integer|nil total
---@return string|nil err
function Inflate.stream(data, offset, len, window_bits, sink, partial)
    local z = libz()
    if z then
        local total, err = native_stream(z, data, offset, len, window_bits, sink, partial)
        if err ~= VERSION_MISMATCH then return total, err end
        backend = false
    end
    return lua_stream(data, offset, len, window_bits, sink, partial)
end

--- 整串解压。
---@param data string
---@param window_bits integer 见 `Inflate.stream`
---@param partial boolean|nil
---@return string|nil out
---@return string|nil err
function Inflate.all(data, window_bits, partial)
    local parts = {}
    local total, err = Inflate.stream(data, 0, #data, window_bits, function(chunk)
        parts[#parts + 1] = chunk
    end, partial)
    if not total then return nil, err end
    return table.concat(parts)
end

--- 解压一段原始 deflate 流（无 zlib 头）。
---@param data string
---@return string|nil out
---@return string|nil err
function Inflate.raw(data)
    return Inflate.all(data, -15)
end

return Inflate
