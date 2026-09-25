--[[--
小鹤双拼：两键一音节，查词前翻译成全拼后复用拼音词库。

反查表由拼音音节表按小鹤规则正向编码生成，一键多韵（如 s=ong/iong）
靠「只收合法音节」自然消歧，不写特例表。

@module koplugin.book.ime.xiaohe
--]]

local SYLLABLES = require("ime.pinyin.dictionary").SYLLABLES

local INITIAL = { zh = "v", ch = "i", sh = "u" }

local FINAL = {
    a = "a", o = "o", e = "e", i = "i", u = "u", v = "v",
    iu = "q", ei = "w", uan = "r", ue = "t", ve = "t", un = "y", uo = "o", ie = "p",
    ong = "s", iong = "s", ai = "d", en = "f", eng = "g", ang = "h", an = "j",
    ing = "k", uai = "k", iang = "l", uang = "l", ou = "z", ia = "x", ua = "x",
    ao = "c", ui = "v", ["in"] = "b", iao = "n", ian = "m",
}

--- 单个声母键（输入到一半）展开成的全拼前缀。
local LONE = { v = "zh", i = "ch", u = "sh" }

local M = {}

---@param syllable string
---@return string
local function encode(syllable)
    if syllable:match("^[aeo]") then
        local final = #syllable == 2 and syllable:sub(2) or FINAL[syllable]
        return syllable:sub(1, 1) .. assert(final, syllable)
    end
    local head = syllable:sub(1, 2)
    local initial = INITIAL[head]
    local rest = syllable:sub(initial and 3 or 2)
    return (initial or syllable:sub(1, 1)) .. assert(FINAL[rest], syllable)
end

local DECODE = {}
for _, syllable in ipairs(SYLLABLES) do
    local code = encode(syllable)
    assert(not DECODE[code], code)
    DECODE[code] = syllable
end

--- 双拼键码 → 全拼。末尾单键展开成声母前缀交给拼音词库前缀查询；
--- 出现非法键对返回空串（拼音词库对空串返回无候选）。
---@param code string 小写字母串
---@return string
function M.toPinyin(code)
    local out = {}
    for i = 1, #code - 1, 2 do
        local syllable = DECODE[code:sub(i, i + 1)]
        if not syllable then return "" end
        out[#out + 1] = syllable
    end
    if #code % 2 == 1 then
        local key = code:sub(-1)
        out[#out + 1] = LONE[key] or key
    end
    return table.concat(out)
end

return M
