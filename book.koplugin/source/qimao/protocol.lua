--[[--
七猫 App 接口协议：请求签名与正文解密（纯函数，零 KOReader 依赖）。

签名 = md5(按键名排序的 `k=v` 直接拼接 .. SIGN_KEY)，请求头和查询参数各签一次（请求头里的 sign 不参与查询签名）。
正文 content 是 base64，前 16 字节为 IV，其余为 AES-128-CBC(PKCS7) 密文，密钥固定。

@module koplugin.book.source.qimao.protocol
--]]

local Aes = require("crypto.aes")
local Hex = require("crypto.hex")
local Md5 = require("crypto.md5")
local Text = require("utils.text")

local Protocol = {}

local SIGN_KEY = "d3dGiJc651gSQ8w1"
local AES_KEY = Hex.from_hex("32343263636238323330643730396531")
local VERSIONS = { "73720", "73700", "73620", "73600", "73500", "73420", "73400", "73328", "73325", "73320" }

Protocol.BC = "https://api-bc.wtzw.com"
Protocol.KS = "https://api-ks.wtzw.com"

---@param params table<string, any>
---@return string
function Protocol.sign(params)
    local keys = {}
    for k in pairs(params) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for i, k in ipairs(keys) do parts[i] = k .. "=" .. tostring(params[k]) end
    return Md5.hex(table.concat(parts) .. SIGN_KEY)
end

--- 带签名的请求头。版本号只是风控里的取值，按书号稳定挑一个，同一本书请求头不变。
---@param book_id string|nil
---@return table<string, string>
function Protocol.headers(book_id)
    local seed = 0
    for i = 1, #(book_id or "") do seed = seed + book_id:byte(i) end
    local headers = {
        ["AUTHORIZATION"] = "",
        ["app-version"] = VERSIONS[seed % #VERSIONS + 1],
        ["application-id"] = "com.****.reader",
        ["channel"] = "unknown",
        ["net-env"] = "1",
        ["platform"] = "android",
        ["qm-params"] = "",
        ["reg"] = "0",
    }
    headers.sign = Protocol.sign(headers)
    return headers
end

--- 带签名的完整 URL。
---@param base string
---@param path string
---@param params table<string, any>
---@return string
function Protocol.url(base, path, params)
    local query = {}
    for k, v in pairs(params) do query[k] = tostring(v) end
    query.sign = Protocol.sign(query)
    return base .. path .. "?" .. Text.formEncode(query)
end

--- 解密 chapter/content 的 data.content。
---@param content string base64
---@return string|nil, string|nil
function Protocol.decrypt(content)
    local raw = Text.base64Decode(content)
    if #raw <= 16 or (#raw - 16) % 16 ~= 0 then return nil, "bad content" end
    local ok, plain = pcall(Aes.cbc_decrypt, raw:sub(17), AES_KEY, raw:sub(1, 16))
    if not ok then return nil, "decrypt failed" end
    return plain
end

return Protocol
