--[[--
京东读书协议：e.m.jd.com 请求签名与 cread.jd.com PC1 参数编解码。

@module koplugin.book.source.jdread.protocol
--]]

local bit = require("bit")
local md5 = require("ffi/sha2").md5
local JSON = require("json")

local Protocol = {}

local APP = "jdread-m"
local PC1_KEY = "0000000000000000"

---@param bytes string
---@param decrypt boolean
---@return string
local function pc1(bytes, decrypt)
    local x = {}
    for i = 1, 8 do
        x[i] = PC1_KEY:byte(i * 2 - 1) * 256 + PC1_KEY:byte(i * 2)
    end

    local si, x1a2 = 0, 0
    local out = {}
    for pos = 1, #bytes do
        local inter, result = 0, 0
        for j = 0, 7 do
            inter = bit.bxor(inter, x[j + 1])
            x1a2 = bit.band((x1a2 + j) * 20021 + si, 0xffff)
            si = bit.band(inter * 346, 0xffff)
            x1a2 = bit.band(x1a2 + si, 0xffff)
            inter = bit.band(inter * 20021 + 1, 0xffff)
            result = bit.bxor(result, inter, x1a2)
        end

        local value = bytes:byte(pos)
        local cfc = not decrypt and value * 257 or nil
        value = bit.band(bit.bxor(value, bit.rshift(result, 8), result), 0xff)
        if decrypt then cfc = value * 257 end
        for i = 1, 8 do
            x[i] = bit.bxor(x[i], cfc)
        end
        out[pos] = string.char(value)
    end
    return table.concat(out)
end

---@param raw string
---@return string
local function asciiToUtf16be(raw)
    return (raw:gsub(".", function(c) return "\0" .. c end))
end

---@param cp integer
---@return string
local function utf8Char(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xc0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(
            0xe0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40,
            0x80 + cp % 0x40
        )
    end
    return string.char(
        0xf0 + math.floor(cp / 0x40000),
        0x80 + math.floor(cp / 0x1000) % 0x40,
        0x80 + math.floor(cp / 0x40) % 0x40,
        0x80 + cp % 0x40
    )
end

---@param raw string
---@return string|nil, string|nil
local function utf16beToUtf8(raw)
    if #raw % 2 ~= 0 then return nil, "invalid UTF-16BE length" end
    local out, i = {}, 1
    while i <= #raw do
        local cp = raw:byte(i) * 256 + raw:byte(i + 1)
        i = i + 2
        if cp >= 0xd800 and cp <= 0xdbff then
            if i > #raw then return nil, "truncated UTF-16 surrogate" end
            local low = raw:byte(i) * 256 + raw:byte(i + 1)
            if low < 0xdc00 or low > 0xdfff then return nil, "invalid UTF-16 surrogate" end
            i = i + 2
            cp = 0x10000 + (cp - 0xd800) * 0x400 + low - 0xdc00
        elseif cp >= 0xdc00 and cp <= 0xdfff then
            return nil, "invalid UTF-16 surrogate"
        end
        if cp ~= 0xfeff then out[#out + 1] = utf8Char(cp) end
    end
    return table.concat(out)
end

---@param raw string
---@return string
local function hexEncode(raw)
    return (raw:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

---@param hex string
---@return string|nil, string|nil
local function hexDecode(hex)
    if #hex % 2 ~= 0 or hex:find("[^%x]") then return nil, "invalid PC1 payload" end
    return (hex:gsub("(%x%x)", function(pair)
        return string.char(tonumber(pair, 16))
    end))
end

---@param value any
---@return string
local function scalar(value)
    if value == nil then return "" end
    if type(value) == "boolean" then return value and "true" or "false" end
    return tostring(value)
end

--- 为 e.m.jd.com 接口生成公共参数和双 MD5 签名。
---@param path string
---@param uuid string
---@param extra table|nil
---@param tm integer|nil
---@return table
function Protocol.signedParams(path, uuid, extra, tm)
    tm = tm or (os.time() * 1000 + math.random(0, 999))
    local params = {
        app = APP,
        tm = tm,
        team_id = "",
        uuid = uuid,
        client = "pc",
        os = "web",
        ov = "1.0",
    }
    for key, value in pairs(extra or {}) do params[key] = value end

    local keys = {}
    for key in pairs(params) do keys[#keys + 1] = key end
    table.sort(keys)
    local canonical = {}
    for _, key in ipairs(keys) do
        canonical[#canonical + 1] = key .. "=" .. scalar(params[key])
    end
    local inner = md5(APP .. tostring(tm) .. uuid)
    params.sign = md5(inner .. path .. table.concat(canonical, "&"))
    return params
end

--- 构造 cread 目录/书籍信息接口的加密参数。
---@param book_id string|number
---@return string
function Protocol.bookKey(book_id)
    local raw = string.format('{"encrypt":1,"bookId":"%s"}', tostring(book_id))
    return hexEncode(pc1(asciiToUtf16be(raw), false))
end

--- 构造 cread 正文接口的加密参数。
---@param book_id string|number
---@param chapter_id string|number
---@return string
function Protocol.chapterKey(book_id, chapter_id)
    local raw = string.format(
        '{"encrypt":1,"bookId":"%s","chapterId":"%s"}',
        tostring(book_id),
        tostring(chapter_id)
    )
    return hexEncode(pc1(asciiToUtf16be(raw), false))
end

--- 解开 cread 外层响应及 PC1 content。
---@param raw string
---@return table|nil, string|nil, boolean|nil
function Protocol.decodeEnvelope(raw)
    local ok, envelope = pcall(JSON.decode, raw)
    if not ok or type(envelope) ~= "table" then return nil, "invalid JD response" end
    if tostring(envelope.code) ~= "0" then
        return nil, envelope.msg or envelope.message or ("JD error " .. tostring(envelope.code)), true
    end
    if type(envelope.content) ~= "string" or envelope.content == "" then
        return nil, "empty JD response"
    end
    local encrypted, hex_err = hexDecode(envelope.content)
    if not encrypted then return nil, hex_err end
    local text, utf_err = utf16beToUtf8(pc1(encrypted, true))
    if not text then return nil, utf_err end
    local decoded_ok, decoded = pcall(JSON.decode, text)
    if not decoded_ok or type(decoded) ~= "table" then return nil, "invalid JD payload" end
    return decoded
end

return Protocol
