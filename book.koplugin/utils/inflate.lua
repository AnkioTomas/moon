--[[--
原始 deflate（无 zlib 头）解压，经 FFI 调系统 libz。

@module koplugin.book.utils.inflate
--]]

local ffi = require("ffi")

local Inflate = {}

local CHUNK = 65536
local libz

--- 逐条 cdef：同名声明可能已被别的模块定义，重复声明报错不能连带丢掉其余声明。
---@return table
local function lib()
    if libz then return libz end
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
    libz = ffi.load("z")
    return libz
end

--- 解压一段原始 deflate 流。
---@param data string
---@return string|nil out
---@return string|nil err
function Inflate.raw(data)
    local z = lib()
    local strm = ffi.new("moon_z_stream") --[[@as MoonZStream]]
    local zs = ffi.cast("void *", strm)
    if z.inflateInit2_(zs, -15, "1.2.11", ffi.sizeof(strm)) ~= 0 then
        return nil, "inflateInit failed"
    end
    local input = ffi.new("unsigned char[?]", #data)
    ffi.copy(input, data, #data)
    strm.next_in = input
    strm.avail_in = #data
    local buf = ffi.new("unsigned char[?]", CHUNK)
    local parts, ret = {}, 0
    while ret == 0 do
        strm.next_out = buf
        strm.avail_out = CHUNK
        ret = z.inflate(zs, 0)
        if ret ~= 0 and ret ~= 1 then break end
        parts[#parts + 1] = ffi.string(buf, CHUNK - strm.avail_out)
    end
    z.inflateEnd(zs)
    if ret ~= 1 then return nil, "inflate failed: " .. ret end
    return table.concat(parts)
end

return Inflate
