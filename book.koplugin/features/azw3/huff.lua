--[[--
MOBI HUFF/CDIC 解压（compression = 0x4448）。

算法移植自 Calibre `ebooks/mobi/huffcdic.py`（GPL-3.0，原作者 darkninja / igorsk / Kovid Goyal）：
读 HUFF 码表 + CDIC 词典，按位解码每条文本记录。词典条目可递归引用（未展开的 slice 再走一遍 unpack）。

所有码表运算按无符号 32 位（`mod 2^32`），不用 `bit.lshift`：LuaJIT 对移位量取模 32，
`<< 32` 会变成 `<< 0`，码表一错全盘皆墨。

@module koplugin.book.features.azw3.huff
--]]

local bit = require("bit")

local Huff = {}

local HUFF_MAGIC = "HUFF\0\0\0\24"
local CDIC_MAGIC = "CDIC\0\0\0\16"
local U32 = 4294967296

local function u32(s, o)
    local a, b, c, d = s:byte(o + 1, o + 4)
    if not d then error("truncated u32") end
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local function u16(s, o)
    local a, b = s:byte(o + 1, o + 2)
    if not b then error("truncated u16") end
    return a * 256 + b
end

local function band32(n)
    return n % U32
end

--- 无符号左移；n ≥ 32 时为 0（与宽整数一致，不是 LuaJIT 的 mod-32）。
local function shl32(v, n)
    if n <= 0 then return band32(v) end
    if n >= 32 then return 0 end
    return band32(v * (2 ^ n))
end

local function shr32(v, n)
    if n <= 0 then return band32(v) end
    if n >= 32 then return 0 end
    return math.floor(band32(v) / (2 ^ n))
end

--- 64 位窗口的高 / 低 32 位。
local function be64parts(s, o)
    return u32(s, o), u32(s, o + 4)
end

--- n ∈ [1, 32]：`(hi<<32|lo) >> n` 的低 32 位。
local function codeAt(hi, lo, n)
    if n == 32 then return hi end
    return band32(shl32(hi, 32 - n) + shr32(lo, n))
end

---@class HuffReader
local Reader = {}
Reader.__index = Reader

function Reader:loadHuff(huff)
    if huff:sub(1, 8) ~= HUFF_MAGIC then error("invalid HUFF header") end
    local off1, off2 = u32(huff, 8), u32(huff, 12)
    local dict1 = {}
    for i = 0, 255 do
        local v = u32(huff, off1 + i * 4)
        local codelen = bit.band(v, 0x1F)
        local term = bit.band(v, 0x80)
        local maxcode = bit.rshift(v, 8)
        if codelen == 0 then error("invalid HUFF code length") end
        if codelen <= 8 and term == 0 then error("invalid HUFF short code") end
        -- ((maxcode + 1) << (32 - codelen)) - 1
        maxcode = band32(shl32(maxcode + 1, 32 - codelen) - 1)
        dict1[i + 1] = { codelen, term, maxcode }
    end
    self.dict1 = dict1
    local mincode, maxcode = { [0] = 0 }, { [0] = 0 }
    for codelen = 1, 32 do
        local min_v = u32(huff, off2 + (codelen - 1) * 8)
        local max_v = u32(huff, off2 + (codelen - 1) * 8 + 4)
        mincode[codelen] = shl32(min_v, 32 - codelen)
        maxcode[codelen] = band32(shl32(max_v + 1, 32 - codelen) - 1)
    end
    self.mincode, self.maxcode = mincode, maxcode
    self.dictionary = {}
end

function Reader:loadCdic(cdic)
    if cdic:sub(1, 8) ~= CDIC_MAGIC then error("invalid CDIC header") end
    local phrases, bits = u32(cdic, 8), u32(cdic, 12)
    local n = math.min(2 ^ bits, phrases - #self.dictionary)
    local dict = self.dictionary
    for i = 0, n - 1 do
        local off = u16(cdic, 16 + i * 2)
        -- 长度在 16+off（0-based），正文紧随其后；Lua sub 含端点
        local blen = u16(cdic, 16 + off)
        local len = bit.band(blen, 0x7FFF)
        local from = 16 + off + 2 + 1
        dict[#dict + 1] = { cdic:sub(from, from + len - 1), bit.band(blen, 0x8000) }
    end
end

function Reader:unpack(data)
    local bitsleft = #data * 8
    data = data .. "\0\0\0\0\0\0\0\0"
    local pos, n = 0, 32
    local hi, lo = be64parts(data, pos)
    local out, oi = {}, 1
    local dict1, mincode, maxcode, dictionary = self.dict1, self.mincode, self.maxcode, self.dictionary

    while true do
        if n <= 0 then
            pos = pos + 4
            hi, lo = be64parts(data, pos)
            n = n + 32
        end
        local code = codeAt(hi, lo, n)
        local entry = dict1[shr32(code, 24) + 1]
        local codelen, term, maxc = entry[1], entry[2], entry[3]
        if term == 0 then
            while code < mincode[codelen] do
                codelen = codelen + 1
            end
            maxc = maxcode[codelen]
        end
        n = n - codelen
        bitsleft = bitsleft - codelen
        if bitsleft < 0 then break end

        -- (maxc - code) >> (32 - codelen)，无符号差
        local r = shr32(band32(maxc - code), 32 - codelen) + 1
        local slot = dictionary[r]
        if not slot then error("HUFF dictionary index out of range") end
        local slice, flag = slot[1], slot[2]
        if flag == 0 then
            dictionary[r] = { nil, 1 }
            slice = self:unpack(slice)
            dictionary[r] = { slice, 1 }
        end
        out[oi] = slice
        oi = oi + 1
    end
    return table.concat(out)
end

--- 从 HUFF + CDIC 记录列表构造解压器；返回 `unpack(data) -> string`。
---@param records string[] records[1] = HUFF，其后为 CDIC
---@return fun(data: string): string
function Huff.reader(records)
    if not records or not records[1] then error("missing HUFF record") end
    local r = setmetatable({}, Reader)
    r:loadHuff(records[1])
    for i = 2, #records do
        r:loadCdic(records[i])
    end
    return function(data)
        return r:unpack(data)
    end
end

return Huff
