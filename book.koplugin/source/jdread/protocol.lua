--[[--
京东读书协议：e.m.jd.com 请求签名与下载接口 AES 编解码。

@module koplugin.book.source.jdread.protocol
--]]

local md5 = require("ffi/sha2").md5
local JSON = require("json")
local Aes = require("crypto.aes")
local Text = require("utils.text")

local Protocol = {}

local APP = "jdread-m"

---@param raw string
---@return string
local function md5bin(raw)
    return (md5(raw):gsub("(%x%x)", function(pair)
        return string.char(tonumber(pair, 16))
    end))
end

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

--- 下载接口强制偶数时间戳，只走 AES，避开 DES 分支。
---@param tm integer|nil
---@return integer
function Protocol.evenTime(tm)
    tm = tm or (os.time() * 1000 + math.random(0, 998))
    if tm % 2 ~= 0 then
        tm = tm + 1
    end
    return tm
end

--- 加密 e.m.jd.com 下载接口的已签名 query。
---@param query string
---@param tm integer
---@return string
function Protocol.encryptQuery(query, tm)
    local raw = Aes.ecb_encrypt(query, md5bin(tostring(tm) .. APP))
    return (Text.base64Encode(raw):gsub("+", "-"):gsub("/", "_"))
end

---@param envelope table
---@return table|nil, string|nil, integer|nil
local function checkDownload(envelope)
    local code = tonumber(envelope.result_code)
    if code ~= 0 then
        return nil, envelope.message or ("JD error " .. tostring(envelope.result_code)), code
    end
    return envelope
end

--- 解开 /jdread/api/download/chapter 的 AES 正文。明文和密文都可能是错误信封。
---@param raw string
---@param tm integer
---@return table|nil, string|nil, integer|nil result_code
function Protocol.decodeDownload(raw, tm)
    if type(raw) ~= "string" or raw == "" then
        return nil, "empty JD download"
    end
    if raw:sub(1, 1) == "{" then
        local ok, envelope = pcall(JSON.decode, raw)
        if ok and type(envelope) == "table" then
            return checkDownload(envelope)
        end
    end
    local ok, text = pcall(Aes.ecb_decrypt, Text.base64Decode(raw), md5bin(tostring(tm) .. APP))
    if not ok or type(text) ~= "string" or text == "" then
        return nil, "invalid JD download"
    end
    local decoded_ok, decoded = pcall(JSON.decode, text)
    if not decoded_ok or type(decoded) ~= "table" then
        return nil, "invalid JD download payload"
    end
    return checkDownload(decoded)
end

return Protocol
