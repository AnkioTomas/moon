--[[--
gzip 片的 raw-inflate 解压（子进程/主进程均可用）。

ffi/zlib.lua 只封装了 compress/uncompress（raw deflate 一次性），没有 gzip 流式
接口（libz 的 gzopen/gzread 未声明）。词库切片是「每片独立 gzip」，设备端需要
按片解压拼接，所以这里直接 ffi 声明 inflate 系列：

  gzip 片 = 10+ 字节头（magic 1f 8b, method 08, flags 可变长）+ raw deflate 流
           + 8 字节尾（crc32 + isize）
  inflateInit2(windowBits = -15) → 纯 raw deflate，正好跳过 gzip 头/尾

只依赖 libz（设备必有，ffi/zlib.lua 同款加载路径）。

@module koplugin.book.pinyin.gzinflate
--]]

local ffi = require("ffi")
local bit = require("bit")
require("ffi/loadlib") -- 注入 ffi.loadlib（设备上解析 KOReader 自带 libz；离线也能跑）

ffi.cdef[[
typedef struct z_stream_s {
    const unsigned char *next_in;
    unsigned int avail_in;
    unsigned long total_in;
    unsigned char *next_out;
    unsigned int avail_out;
    unsigned long total_out;
    char *msg;
    void *state;
    void *zalloc;
    void *zfree;
    void *opaque;
    int data_type;
    unsigned long adler;
    unsigned long reserved;
} z_stream;
typedef z_stream *z_streamp;
int inflateInit2_(z_streamp strm, int windowBits, const char *version, int stream_size);
int inflate(z_streamp strm, int flush);
int inflateEnd(z_streamp strm);
const char *zlibVersion();
]]

local libz = ffi.loadlib("z", 1)

local Z_NO_FLUSH = 0
local Z_OK = 0
local Z_STREAM_END = 1
local OUT_CHUNK = 4 * 1024 * 1024

--- 跳过 gzip 头，返回 deflate 流起始偏移（1-based）。
---@param data string
---@return number
local function deflateOffset(data)
    if #data < 10 or data:byte(1) ~= 0x1f or data:byte(2) ~= 0x8b or data:byte(3) ~= 8 then
        error("gzinflate: not a gzip stream")
    end
    local flg = data:byte(4)
    local pos = 11 -- 头固定 10 字节，pos 是 1-based 下一字节
    -- FEXTRA(2) / FNAME(8) / FCOMMENT(16) / FHCRC(4) 依次跳过
    if bit.band(flg, 2) ~= 0 then
        local xlen = data:byte(pos) + data:byte(pos + 1) * 256
        pos = pos + 2 + xlen
    end
    if bit.band(flg, 8) ~= 0 then
        local s = data:find("\0", pos, true)
        pos = s + 1
    end
    if bit.band(flg, 16) ~= 0 then
        local s = data:find("\0", pos, true)
        pos = s + 1
    end
    if bit.band(flg, 4) ~= 0 then
        pos = pos + 2
    end
    return pos
end

--- 解压一个独立 gzip 片，返回原始字节串。
---@param gz string 完整 gzip 片内容
---@return string
local function inflateGzip(gz)
    local offset = deflateOffset(gz)
    local stream = ffi.new("z_stream")
    local version = libz.zlibVersion()
    if libz.inflateInit2_(stream, -15, version, ffi.sizeof(stream)) ~= Z_OK then
        error("gzinflate: inflateInit2 failed")
    end
    ffi.gc(stream, libz.inflateEnd)

    local in_buf = ffi.new("const unsigned char[?]", #gz - offset + 1, gz:sub(offset))
    stream.next_in = in_buf
    stream.avail_in = #gz - offset + 1

    local parts = {}
    local out_buf = ffi.new("unsigned char[?]", OUT_CHUNK)
    while true do
        stream.next_out = out_buf
        stream.avail_out = OUT_CHUNK
        local ret = libz.inflate(stream, Z_NO_FLUSH)
        local produced = OUT_CHUNK - stream.avail_out
        if produced > 0 then
            parts[#parts + 1] = ffi.string(out_buf, produced)
        end
        if ret == Z_STREAM_END then
            break
        end
        if ret ~= Z_OK then
            error("gzinflate: inflate failed (" .. tostring(ret) .. ")")
        end
        if produced == 0 and stream.avail_in == 0 then
            error("gzinflate: truncated stream")
        end
    end
    return table.concat(parts)
end

return {
    inflateGzip = inflateGzip,
}
