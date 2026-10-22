--[[--
微信读书 App 章节下载包（GET /book/chapterdownload）解包。

响应头 encryptKey 是 base64 的 AES-128-CBC(PKCS7) 密文，明文即 zip 的 ZipCrypto 口令。
解密用的 key/iv 来自 vid：十进制字符串循环铺满 32 字节，逐字节过 REMAP 表，前 16 字节为 key、后 16 字节为 iv
（移植自官方 App libencrypt.so 的 nativeDecryptHeaderKey，抓包样本验证）。

@module koplugin.book.source.wechat.package
--]]

local bit = require("bit")
local JSON = require("json")
local Aes = require("crypto.aes")
local Inflate = require("utils.inflate")

local Package = {}

local REMAP = Aes.from_hex(
    "34ca55401db693c63130293532a7b811c2b516fa8bb124a4109004e908f83b8a"
    .. "9c8c44f9bc5c69e2a1dad2d37589f71e2d5056d77253bf22fb200f012e45876e"
    .. "6648f2e0cdfe67a943f49451cea54aee13268eccaa33145d0e39bbcf912b814d"
    .. "ea99ec1a2c85c5d936744b18e1f13d9d419fb4170dd64cbedcaf972877f062ff"
    .. "71c1c8278f6c68a89be6591c1b1209984e3f063700ba1f0a192fc9d5d057496f"
    .. "fd25e4610c42cb96645fdbad60238d9a6dc3c45e3eb9926abd5b077f7695ed4f"
    .. "ab847a80e778c7e5eb73836bfc38467d4765b352633a05d1efa3a6de9e3c02ae"
    .. "b27ba0f6f32ac0ac86035a540bf582d47ee3dfb0d8dd21e87c88a2795870b715")

local function b64decode(s)
    local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local val = {}
    for i = 1, #alphabet do val[alphabet:byte(i)] = i - 1 end
    local out, acc, bits = {}, 0, 0
    for i = 1, #s do
        local v = val[s:byte(i)]
        if v then
            acc, bits = acc * 64 + v, bits + 6
            if bits >= 8 then
                bits = bits - 8
                out[#out + 1] = string.char(math.floor(acc / 2 ^ bits) % 256)
                acc = acc % 2 ^ bits
            end
        end
    end
    return table.concat(out)
end

--- 由 vid 与响应头 encryptKey 算出 zip 口令。
---@param vid string
---@param encrypt_key string base64
---@return string|nil password
---@return string|nil err
function Package.password(vid, encrypt_key)
    if not vid:match("^%d+$") then return nil, "bad vid" end
    local raw = vid:rep(math.ceil(32 / #vid)):sub(1, 32)
    local kiv = raw:gsub(".", function(c) return string.char(REMAP:byte(c:byte() + 1)) end)
    local ok, plain = pcall(Aes.cbc_decrypt, b64decode(encrypt_key), kiv:sub(1, 16), kiv:sub(17, 32))
    if not ok then return nil, "encryptKey decrypt failed" end
    return plain
end

local CRC = {}
for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
        c = bit.band(c, 1) == 1 and bit.bxor(0xEDB88320, bit.rshift(c, 1)) or bit.rshift(c, 1)
    end
    CRC[i] = c
end

local function crcUpdate(crc, byte)
    return bit.bxor(CRC[bit.band(bit.bxor(crc, byte), 0xff)], bit.rshift(crc, 8))
end

--- 32 位乘法取低 32 位（LuaJIT 的 double 装不下 32×27 位乘积）。
local function mul32(a, b)
    local lo, hi = b % 65536, math.floor(b / 65536)
    return (a * lo + (a * hi % 65536) * 65536) % 4294967296
end

--- 传统 ZipCrypto 解密：data 含开头 12 字节随机头。
---@param data string
---@param password string
---@return string
local function zipDecrypt(data, password)
    local k0, k1, k2 = 0x12345678, 0x23456789, 0x34567890
    local function update(c)
        k0 = crcUpdate(k0, c) % 4294967296
        k1 = (mul32((k1 + bit.band(k0, 0xff)) % 4294967296, 134775813) + 1) % 4294967296
        k2 = crcUpdate(k2, bit.rshift(k1, 24)) % 4294967296
    end
    for i = 1, #password do update(password:byte(i)) end
    local out = {}
    for i = 1, #data do
        local t = bit.bor(k2, 2) % 65536
        local c = bit.bxor(data:byte(i), bit.band(bit.rshift(t * bit.bxor(t, 1), 8), 0xff))
        update(c)
        out[i] = c
    end
    local chunks = {}
    for i = 13, #out, 4096 do
        chunks[#chunks + 1] = string.char(unpack(out, i, math.min(i + 4095, #out)))
    end
    return table.concat(chunks)
end

local function u16(s, p) local a, b = s:byte(p, p + 1) return a + b * 256 end
local function u32(s, p) local a, b, c, d = s:byte(p, p + 3) return a + b * 256 + c * 65536 + d * 16777216 end

--- 解开整个 zip（走中央目录，数据描述符模式也能用）。
---@param data string
---@param password string|nil
---@return table<string, string>|nil files 文件名 → 内容
---@return string|nil err
function Package.unzip(data, password)
    local eocd
    for p = #data - 21, math.max(1, #data - 65557), -1 do
        if u32(data, p) == 0x06054b50 then eocd = p break end
    end
    if not eocd then return nil, "zip: no end record" end
    local files, p = {}, u32(data, eocd + 16) + 1
    for _ = 1, u16(data, eocd + 10) do
        if u32(data, p) ~= 0x02014b50 then return nil, "zip: bad central directory" end
        local flags, method, csize = u16(data, p + 8), u16(data, p + 10), u32(data, p + 20)
        local nlen, elen, clen, lho = u16(data, p + 28), u16(data, p + 30), u16(data, p + 32), u32(data, p + 42) + 1
        local name = data:sub(p + 46, p + 45 + nlen)
        p = p + 46 + nlen + elen + clen
        if u32(data, lho) ~= 0x04034b50 then return nil, "zip: bad local header" end
        local start = lho + 30 + u16(data, lho + 26) + u16(data, lho + 28)
        local body = data:sub(start, start + csize - 1)
        if bit.band(flags, 1) == 1 then
            if not password then return nil, "zip: password required" end
            body = zipDecrypt(body, password)
        end
        if method == 8 then
            local out, err = Inflate.raw(body)
            if not out then return nil, "zip: " .. name .. " " .. tostring(err) end
            body = out
        elseif method ~= 0 then
            return nil, "zip: unsupported method " .. method
        end
        files[name] = body
    end
    return files
end

--- 取某章的 xhtml：章节由主文件（标题 / 插图）加若干 _000N 续篇组成，续篇 body 依次并入主文件 body 末尾。
---@param files table<string, string> Package.unzip 的结果
---@param uid string|number
---@return string|nil xhtml
---@return string|nil err
function Package.chapterHtml(files, uid)
    local info = files["info.txt"] and JSON.decode(files["info.txt"])
    for _idx, chapter in ipairs(info and info.chapters or {}) do
        if tostring(chapter.chapterUid) == tostring(uid) then
            local html = files[chapter.files[1]]
            if not html then return nil, "package: missing " .. tostring(chapter.files[1]) end
            for i = 2, #chapter.files do
                local part = files[chapter.files[i]]
                local inner = part and part:match("<body[^>]*>(.*)</body>")
                if not inner then return nil, "package: bad part " .. tostring(chapter.files[i]) end
                local last = html:match(".*()</body>")
                if not last then return nil, "package: no body" end
                html = html:sub(1, last - 1) .. inner .. html:sub(last)
            end
            return html
        end
    end
    return nil, "package: chapter " .. tostring(uid) .. " not in package"
end

return Package
