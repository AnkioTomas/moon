--[[--
WOFF 1.0 → sfnt（TTF/OTF）解包。

FreeType 打开 WOFF 时会把整份字体解压到堆上，而 crengine 每个字号/字重实例各开一个 FT_Face：
30MB 级的 CJK 字体开十几个实例就能把 512MB 的设备撑爆。sfnt 文件由 FreeType mmap，实例间共享页缓存。

@module koplugin.book.ui.fonts.woff
--]]

local Woff = {}

local CHUNK = 65536
local libz_cache

--- 逐条 cdef：同名声明可能已被别的模块（番茄 crypto）定义，重复声明报错不能连带丢掉其余声明。
---@return table
local function libz()
    if libz_cache then return libz_cache end
    local ffi = require("ffi")
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
    libz_cache = ffi.load("z")
    return libz_cache
end

--- 把 data 里 [offset, offset+comp_len) 的 zlib 流分块解压写进 out，返回解出的字节数。
--- 不整表分配缓冲区：大 CJK 字体的 glyf 表有几十 MB，一次性解压会在小内存设备上 OOM。
---@param data string
---@param offset integer 0 起始
---@param comp_len integer
---@param out file*
---@return integer
local function inflateTo(data, offset, comp_len, out)
    local ffi, z = require("ffi"), libz()
    local strm = ffi.new("moon_z_stream") --[[@as MoonZStream]]
    local zs = ffi.cast("void *", strm)
    assert(z.inflateInit2_(zs, 15, "1.2.11", ffi.sizeof(strm)) == 0, "inflateInit failed")
    local buf = ffi.new("unsigned char[?]", CHUNK)
    strm.next_in = ffi.cast("const unsigned char *", data) + offset
    strm.avail_in = comp_len
    local total, ret = 0, 0
    while ret == 0 do
        strm.next_out = buf
        strm.avail_out = CHUNK
        ret = z.inflate(zs, 0)
        if ret ~= 0 and ret ~= 1 then break end
        local n = CHUNK - strm.avail_out
        total = total + n
        assert(out:write(ffi.string(buf, n)))
    end
    z.inflateEnd(zs)
    assert(ret == 1, "inflate failed: " .. ret)
    return total
end

---@param s string
---@param pos integer 1 起始
---@param len integer 字节数
---@return integer
local function uint(s, pos, len)
    local n = 0
    for i = pos, pos + len - 1 do n = n * 256 + s:byte(i) end
    return n
end

---@param n integer
---@param len integer 字节数
---@return string
local function be(n, len)
    local bytes = {}
    for i = len, 1, -1 do
        bytes[i] = n % 256
        n = math.floor(n / 256)
    end
    return string.char(unpack(bytes))
end

--- 把 WOFF 内容解包成 sfnt 写进 out；格式错误、解压失败、写盘失败一律抛错。
--- WOFF 目录按 tag 升序（规范要求），原样沿用为 sfnt 表记录顺序。
--- 逐表分块解压写盘，峰值内存 ≈ 源文件 + 64KB。
---@param data string
---@param out file*
local function writeSfnt(data, out)
    assert(#data >= 44 and data:sub(1, 4) == "wOFF", "not a WOFF 1.0 file")
    local num, total = uint(data, 13, 2), uint(data, 17, 4)
    assert(num > 0 and #data >= 44 + num * 20, "truncated WOFF directory")
    local selector = 0
    while 2 ^ (selector + 1) <= num do selector = selector + 1 end
    local range = 2 ^ selector * 16
    local header = { data:sub(5, 8), be(num, 2), be(range, 2), be(selector, 2), be(num * 16 - range, 2) }
    local entries = {}
    local offset = 12 + 16 * num
    for p = 45, 44 + num * 20, 20 do
        local e = { tag = data:sub(p, p + 3), offset = uint(data, p + 4, 4),
            comp_len = uint(data, p + 8, 4), orig_len = uint(data, p + 12, 4) }
        -- orig_len 决定解压缓冲区大小；用头部 totalSfntSize 封顶，防畸形文件一次分配 4GB。
        assert(e.comp_len <= e.orig_len and e.orig_len <= total and e.offset + e.comp_len <= #data,
            "invalid WOFF table " .. e.tag)
        header[#header + 1] = e.tag .. data:sub(p + 16, p + 19) .. be(offset, 4) .. data:sub(p + 12, p + 15)
        offset = offset + e.orig_len + -e.orig_len % 4
        entries[#entries + 1] = e
    end
    assert(out:write(table.concat(header)))
    for _idx, e in ipairs(entries) do
        if e.comp_len < e.orig_len then
            assert(inflateTo(data, e.offset, e.comp_len, out) == e.orig_len, "corrupt WOFF table " .. e.tag)
        else
            assert(out:write(data:sub(e.offset + 1, e.offset + e.comp_len)))
        end
        assert(out:write(("\0"):rep(-e.orig_len % 4)))
    end
    assert(out:flush())
end

--- 把 WOFF 1.0 文件转成 sfnt 写到 dest（先写 .part 再改名，失败不留半截文件）。
---@param src string WOFF 路径
---@param dest string 输出路径
---@return boolean|nil ok
---@return string|nil err
function Woff.toSfnt(src, dest)
    local f, err = io.open(src, "rb")
    if not f then return nil, err end
    local data = f:read("*a")
    f:close()
    local part = dest .. ".part"
    local out
    out, err = io.open(part, "wb")
    if not out then return nil, err end
    -- 损坏 / 非 WOFF 1.0 / 磁盘满都转成错误返回，调用方退回原 WOFF。
    local ok
    ok, err = pcall(writeSfnt, data, out)
    out:close()
    if ok then ok, err = os.rename(part, dest) end
    if not ok then
        os.remove(part)
        return nil, err
    end
    return true
end

return Woff
