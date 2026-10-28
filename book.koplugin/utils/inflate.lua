--[[--
deflate / zlib / gzip 解压，经 FFI 调系统 libz，分块输出。

不整表分配输出缓冲：大 CJK 字体的 glyf 表有几十 MB，一次性解压会在小内存设备上 OOM；
调用方要整串就在 sink 里 concat。

@module koplugin.book.utils.inflate
--]]

local ffi = require("ffi")

local Inflate = {}

local CHUNK = 65536
local libz

--- 逐条 cdef：同名声明可能已被别的模块定义，重复声明报错不能连带丢掉其余声明。
--- 参数用 void * 才能兼容他人以 z_stream * 声明的同名函数。
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
    local z = lib()
    local strm = ffi.new("moon_z_stream") --[[@as MoonZStream]]
    local zs = ffi.cast("void *", strm)
    if z.inflateInit2_(zs, window_bits, "1.2.11", ffi.sizeof(strm)) ~= 0 then
        return nil, "inflateInit failed"
    end
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

--- 整串解压。
---@param data string
---@param window_bits integer 见 `Inflate.stream`
---@param partial boolean|nil
---@return string|nil out
---@return string|nil err
function Inflate.all(data, window_bits, partial)
    local parts = {}
    local total, err = Inflate.stream(data, 0, #data, window_bits, function(chunk) parts[#parts + 1] = chunk end, partial)
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
