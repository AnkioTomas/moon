--[[--
盐选网页 VIP 接口签名（101_3_3.1）。

MD5 原文按官网顺序拼版本、完整路径和 d_c0 原值（含引号）。
分组轮函数复用 SM4，但替换表、轮密钥和输出编码是盐选协议，不是标准 SM4。

@module source.zhihu.sign
--]]

local bit = require("bit")
local Pad = require("crypto.pad")
local Sm4 = require("crypto.sm4")
local md5 = require("ffi/sha2").md5

local Sign = {}
local VERSION = "101_3_3.1"
local ALPHABET = "p9Vc6dUJGTu/YXKZPSAlm3j4Lyna+=oHMFz1vtqkBEDghW75O2Nb8xReCfIi0wQsr"
local random = math.random
local ROUND_KEYS = {
    -203535452, -89892647, -611010325, -1788458313, 1605777840, -24024647, -1551084381, -648937602,
    -410783454, 1611114722, -1473915266, 1319334601, 581282997, 1852100228, 1049921566, -1062880464,
    2128563442, -748483983, -343522048, -1367557827, -79403890, -1710684240, 1697342685, 981842533,
    -167308242, 1770909019, 213640201, 817718050, 199423269, 1141645961, -1342602837, 1722529140,
}
local SBOX = {
    23,218,72,119,134,104,62,138,169,177,141,13,204,208,235,184,
    6,60,174,178,129,38,79,179,252,142,103,110,121,139,70,1,
    40,222,213,115,20,101,152,102,117,180,52,17,37,35,229,195,
    69,192,140,147,113,118,135,221,91,200,86,182,82,63,189,148,
    234,155,145,230,233,55,68,46,9,18,131,51,171,236,205,4,
    157,125,153,123,217,75,29,107,241,22,16,211,167,198,226,97,
    154,251,80,181,242,99,216,132,10,50,114,111,116,120,162,207,
    15,32,144,224,124,93,8,215,248,240,187,199,126,206,243,166,
    34,159,228,253,237,47,25,227,185,33,196,24,28,57,19,59,
    239,92,64,214,58,88,136,31,156,197,149,53,247,61,137,76,
    30,193,78,219,5,42,158,163,194,176,89,231,164,11,2,73,
    165,12,45,201,44,49,3,223,67,48,71,151,130,41,21,100,
    143,191,249,160,105,106,98,27,26,0,209,250,255,202,220,85,
    39,43,210,172,112,81,244,150,245,212,203,161,94,14,170,54,
    238,83,66,122,225,190,188,96,183,87,74,84,108,127,109,36,
    7,90,95,146,186,168,65,128,173,232,175,56,246,133,77,254,
}
local IV = ("4548afd21eadee59"):gsub(".", function(char)
    return string.char(bit.bxor(char:byte(), 42))
end)

---@param path string 完整路径与查询串，顺序必须和 HTTP 请求一致
---@param cookie string|nil
---@return table<string, string>
function Sign.headers(path, cookie)
    local dc0 = cookie and (";" .. cookie):match(";%s*d_c0=([^;]+)")
    local source = VERSION .. "+" .. path .. (dc0 and "+" .. dc0 or "")
    local data = Pad.pkcs7_pad(string.char(math.floor(random() * 127), 2) .. md5(source), 16)
    local blocks, prev = {}, IV
    for offset = 1, #data, 16 do
        local mixed = {}
        for i = 1, 16 do
            mixed[i] = string.char(bit.bxor(data:byte(offset + i - 1), prev:byte(i)))
        end
        prev = Sm4.block(table.concat(mixed), ROUND_KEYS, SBOX)
        blocks[#blocks + 1] = prev
    end
    local cipher = table.concat(blocks)
    cipher = cipher .. string.rep("\0", (3 - #cipher % 3) % 3)
    local encoded, group = {}, 0
    for i = #cipher - 2, 1, -3 do
        local a, b, c = cipher:byte(i, i + 2)
        local word = bit.bxor(a * 65536 + b * 256 + c, bit.lshift(58, group % 4 * 8))
        for shift = 0, 18, 6 do
            local at = bit.band(bit.rshift(word, shift), 63) + 1
            encoded[#encoded + 1] = ALPHABET:sub(at, at)
        end
        group = group + 1
    end
    return { ["x-zse-93"] = VERSION, ["x-zse-96"] = "2.0_" .. table.concat(encoded) }
end

return Sign
