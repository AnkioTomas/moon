--[[--
安全随机字节：系统随机设备不可用时使用 KOReader 随附 libcrypto 的 CSPRNG。
认证票据、密钥和设备标识不得退回 math.random。

@module koplugin.book.utils.random
--]]

local Random = {}
local crypto

---@param n integer 字节数
---@return string
function Random.bytes(n)
    assert(n >= 0 and n == math.floor(n) and n <= 2147483647, "random: invalid byte count")
    if n == 0 then return "" end
    local file = io.open("/dev/urandom", "rb")
    if file then
        local bytes = file:read(n)
        file:close()
        if bytes and #bytes == n then return bytes end
    end
    local ffi = require("ffi")
    if not crypto then
        ffi.cdef[[int RAND_bytes(unsigned char *buf, int num);]]
        crypto = ffi.loadlib("crypto", "57")
    end
    local buffer = ffi.new("unsigned char[?]", n)
    assert(crypto.RAND_bytes(buffer, n) == 1, "random: secure generator failed")
    return ffi.string(buffer, n)
end

---@param n integer 随机字节数，输出为 2n 个十六进制字符
---@return string
function Random.hex(n)
    return (Random.bytes(n):gsub(".", function(ch) return ("%02x"):format(ch:byte()) end))
end

return Random
