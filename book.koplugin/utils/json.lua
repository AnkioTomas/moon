--[[--
JSON 解码薄封装：KOReader 自带的 luajson 把 `\uD83D\uDE00` 这类代理对逐半编码（CESU-8，非法 UTF-8），
emoji 因此显示为空 / 乱码。这里解码后把结果里的代理对字节合成正常的 4 字节 UTF-8（键和值都修）。
合法 UTF-8 里不会出现代理区字节，修复不会误伤。
--]]

local Json = {}

--- 把 CESU-8 代理对（ED A0-AF xx ED B0-BF xx）合成 4 字节 UTF-8；没有代理对原样返回。
---@param s string
---@return string
function Json.fixSurrogates(s)
    if not s:find("\237[\160-\175]") then return s end
    return (s:gsub("\237([\160-\175])([\128-\191])\237([\176-\191])([\128-\191])", function(a, b, c, d)
        local hi = 0xD000 + (a:byte() - 0x80) * 64 + (b:byte() - 0x80)
        local lo = 0xD000 + (c:byte() - 0x80) * 64 + (d:byte() - 0x80)
        local cp = 0x10000 + (hi - 0xD800) * 0x400 + (lo - 0xDC00)
        return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 64,
            0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
    end))
end

local function repair(v, seen)
    local t = type(v)
    if t == "string" then return Json.fixSurrogates(v) end
    if t ~= "table" or seen[v] then return v end
    seen[v] = true
    local fixed = {}
    for k, val in pairs(v) do
        local nk = type(k) == "string" and Json.fixSurrogates(k) or k
        if nk ~= k then fixed[#fixed + 1] = { k, nk } end
        v[k] = repair(val, seen)
    end
    for _idx, kk in ipairs(fixed) do
        v[kk[2]], v[kk[1]] = v[kk[1]], nil
    end
    return v
end

--- 同 `require("json").decode`（出错照样抛），结果里的代理对修成正常 UTF-8。
---@param text string
---@param opts any 透传给 luajson（如 JSON.decode.simple）
---@return any, any
function Json.decode(text, opts)
    local JSON = require("json") -- 每次取：测试 / 热替换 json 模块后不拿旧引用
    local v, err
    if opts ~= nil then v, err = JSON.decode(text, opts) else v, err = JSON.decode(text) end
    return repair(v, {}), err
end

return Json
