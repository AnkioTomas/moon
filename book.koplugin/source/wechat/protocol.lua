--[[--
微信读书 Web Reader 协议（编码 / 签名 / 正文分片解码）。

算法来自微信读书网页端公开逆向（与 cookie 会话配套），
独立实现，不依赖第三方插件源码。

@module koplugin.book.source.wechat.protocol
--]]

local bit = require("bit")
local md5 = require("ffi/sha2").md5

local Protocol = {}

--- 判断字符串是否全为数字。
---@param s any
---@return boolean
local function isDigitString(s)
    return tostring(s):match("^%d+$") ~= nil
end

--- 对参数值做 URL 编码。
---@param value any
---@return string
local function urlencode(value)
    if value == true then
        value = "true"
    elseif value == false then
        value = "false"
    elseif value == nil then
        value = "null"
    else
        value = tostring(value)
    end
    return (value:gsub("([^%w%-_%.~])", function(ch)
        return string.format("%%%02X", ch:byte())
    end))
end

--- 把字符串每个字节编成十六进制拼接。
---@param s string
---@return string
local function byteHex(s)
    local out = {}
    for i = 1, #s do
        out[i] = string.format("%x", s:byte(i))
    end
    return table.concat(out)
end

--- 微信读书 ID/时间戳混淆（reader URL、正文参数 b/c/pc）。
---@param value any
---@return string
function Protocol.encode(value)
    local s = tostring(value)
    local h = md5(s)
    local result = h:sub(1, 3)
    local chunks = {}
    local type_flag
    if isDigitString(s) then
        type_flag = "3"
        local i = 1
        while i <= #s do
            local part = s:sub(i, i + 8)
            chunks[#chunks + 1] = string.format("%x", tonumber(part))
            i = i + 9
        end
    else
        type_flag = "4"
        chunks[1] = byteHex(s)
    end
    result = result .. type_flag .. "2" .. h:sub(-2)
    for i, chunk in ipairs(chunks) do
        result = result .. string.format("%02x", #chunk) .. chunk
        if i < #chunks then
            result = result .. "g"
        end
    end
    if #result < 20 then
        result = result .. h:sub(1, 20 - #result)
    end
    return result .. md5(result):sub(1, 3)
end

--- 按键排序拼 query（排除签名字段 s）。
---@param params table
---@return string
function Protocol.sortedQuery(params)
    local keys = {}
    for key in pairs(params) do
        if key ~= "s" then
            keys[#keys + 1] = key
        end
    end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = key .. "=" .. urlencode(params[key])
    end
    return table.concat(parts, "&")
end

--- 计算微信读书 Web 请求签名。
---@param query string
---@return string
function Protocol.sign(query)
    local a = 0x15051505
    local b = a
    local length = #query
    local i = length
    while i > 1 do
        a = bit.band(bit.bxor(a, bit.lshift(query:byte(i), ((length - i + 1) % 30))), 0x7fffffff)
        b = bit.band(bit.bxor(b, bit.lshift(query:byte(i - 1), ((i - 1) % 30))), 0x7fffffff)
        i = i - 2
    end
    return string.format("%x", a + b):lower()
end

--- 构造 reader 页 URL。
---@param book_id string|number
---@param chapter_uid string|number|nil
---@return string
function Protocol.readerUrl(book_id, chapter_uid)
    local url = "https://weread.qq.com/web/reader/" .. Protocol.encode(book_id)
    if chapter_uid then
        url = url .. "k" .. Protocol.encode(chapter_uid)
    end
    return url
end

--- 正文分片 POST body。
---@param book_id string|number
---@param chapter_uid string|number
---@param psvts string
---@param opts { ct: number|nil, sc: number|nil, style: boolean|nil }|nil
---@return table
function Protocol.contentParams(book_id, chapter_uid, psvts, opts)
    opts = opts or {}
    local ct = opts.ct or os.time()
    if Protocol.encode(ct) == psvts then
        ct = ct + 1
    end
    local params = {
        b = Protocol.encode(book_id),
        c = Protocol.encode(chapter_uid),
        r = tostring(math.random(0, 9999) ^ 2),
        ct = tostring(ct),
        ps = psvts,
        pc = Protocol.encode(ct),
        sc = opts.sc or 1,
        prevChapter = false,
        st = opts.style and 1 or 0,
    }
    params.s = Protocol.sign(Protocol.sortedQuery(params))
    return params
end

-- --- 分片解码（响应：32 字节 MD5 头 + 混淆 body；去掉首字符后反交换再 base64）---

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

--- Base64 解码（兼容 URL-safe 字符）。
---@param data string
---@return string
local function base64Decode(data)
    data = data:gsub("-", "+"):gsub("_", "/")
    local pad = #data % 4
    if pad > 0 then
        data = data .. string.rep("=", 4 - pad)
    end
    data = data:gsub("[^" .. B64 .. "=]", "")
    return (data:gsub(".", function(char)
        if char == "=" then
            return ""
        end
        local bits = ""
        local index = B64:find(char, 1, true) - 1
        for b = 6, 1, -1 do
            bits = bits .. (index % 2 ^ b - index % 2 ^ (b - 1) > 0 and "1" or "0")
        end
        return bits
    end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(bits)
        if #bits ~= 8 then
            return ""
        end
        local byte = 0
        for i = 1, 8 do
            if bits:sub(i, i) == "1" then
                byte = byte + 2 ^ (8 - i)
            end
        end
        return string.char(byte)
    end))
end

--- 从混淆串推导交换位置列表。
---@param encoded string
---@return number[]
local function swapPositions(encoded)
    local length = #encoded
    if length < 4 then
        return {}
    end
    if length < 11 then
        return { 0, 2 }
    end
    local n = math.min(4, math.floor((length + 9) / 10))
    local tmp = {}
    for i = length, length - n + 1, -1 do
        local byte = encoded:byte(i)
        local bin = {}
        repeat
            table.insert(bin, 1, tostring(byte % 2))
            byte = math.floor(byte / 2)
        until byte == 0
        tmp[#tmp + 1] = tostring(tonumber(table.concat(bin), 4) or 0)
    end
    tmp = table.concat(tmp)
    local result = {}
    local m = length - n - 2
    local step = #tostring(m)
    local i = 1
    while #result < 10 and i + step - 1 < #tmp do
        result[#result + 1] = (tonumber(tmp:sub(i, i + step - 1)) or 0) % m
        local end2 = math.min(i + step, #tmp)
        if i + 1 <= #tmp then
            result[#result + 1] = (tonumber(tmp:sub(i + 1, end2)) or 0) % m
        end
        i = i + step
    end
    return result
end

--- 按位置列表反向交换还原混淆串。
---@param encoded string
---@param positions number[]
---@return string
local function reverseSwaps(encoded, positions)
    local chars = {}
    for i = 1, #encoded do
        chars[i] = encoded:sub(i, i)
    end
    for i = #positions, 1, -2 do
        for k = 1, 0, -1 do
            local left = positions[i] + k + 1
            local right = positions[i - 1] + k + 1
            chars[left], chars[right] = chars[right], chars[left]
        end
    end
    return table.concat(chars)
end

--- 校验分片 MD5 头并返回 body。
---@param response_text string|nil
---@return string|nil, string|nil
local function checkedBody(response_text)
    if not response_text or #response_text <= 32 then
        return nil, "shard too short"
    end
    local expected = response_text:sub(1, 32)
    local body = response_text:sub(33)
    if md5(body):upper() ~= expected then
        return nil, "shard md5 mismatch"
    end
    return body
end

--- 解码已通过校验的混淆 body 为明文。
---@param body string|nil
---@return string
local function decodeEncodedBody(body)
    if not body or #body == 0 then
        return ""
    end
    local encoded = body:sub(2)
    return base64Decode(reverseSwaps(encoded, swapPositions(encoded)))
end

--- 拼接 e0+e1+e3（或 t0+t1）并解码为明文。
---@param ... string
---@return string|nil text, string|nil err
function Protocol.decodeShards(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local raw = select(i, ...)
        if raw and raw ~= "" then
            local body, err = checkedBody(raw)
            if not body then
                return nil, err
            end
            parts[#parts + 1] = body
        end
    end
    if #parts == 0 then
        return nil, "empty shards"
    end
    return decodeEncodedBody(table.concat(parts))
end

return Protocol
