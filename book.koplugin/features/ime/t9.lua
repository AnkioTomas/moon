--[[--
九宫格拼音：数字键位表与按键序列 → 拼音码的展开。

输入码是数字 2-9；词库仍是拼音词库，这里只把数字串展开成
若干切分合法的拼音码，逐个交给词库查，不另建词库。

@module koplugin.book.features.ime.t9
--]]

local T9 = {}

local GROUPS = {
    ["2"] = "abc", ["3"] = "def", ["4"] = "ghi", ["5"] = "jkl",
    ["6"] = "mno", ["7"] = "pqrs", ["8"] = "tuv", ["9"] = "wxyz",
}

local LETTER_KEY = {}
for digit, letters in pairs(GROUPS) do
    for i = 1, #letters do LETTER_KEY[letters:sub(i, i)] = digit end
end

local MAX_CODES = 12 -- 查词的拼音码上限：每个码一次查询
local MAX_WORDS = 21 -- 候选词上限
local MAX_VISIT = 200 -- 展开的搜索步数上限，长数字串不会指数爆炸

---@param key string
---@return string|nil
function T9.mapKey(key)
    if GROUPS[key] then return key end
end

---@param syllables string[]
---@return table sig 数字串 → 完整音节表
---@return table prefix 数字串 → 半截音节（含完整音节本身）
local function indexSyllables(syllables)
    local full, partial = {}, {}
    for _idx, syl in ipairs(syllables) do
        local digits = syl:gsub(".", LETTER_KEY)
        full[digits] = full[digits] or {}
        table.insert(full[digits], syl)
        for i = 1, #syl do
            local prefix = syl:sub(1, i)
            local pd = digits:sub(1, i)
            partial[pd] = partial[pd] or {}
            partial[pd][prefix] = true
        end
    end
    return full, partial
end

local index

--- 数字串 → 候选拼音码，完整音节串优先、音节少的优先。
---@param digits string 数字 2-9
---@return string[]
function T9.codes(digits)
    if not index then
        local full, partial = indexSyllables(require("features.ime.pinyin.dictionary").SYLLABLES)
        index = { full = full, partial = partial }
    end
    local found, visited = {}, 0
    local n = #digits
    local function walk(pos, parts)
        visited = visited + 1
        if visited > MAX_VISIT then return end
        if pos > n then
            found[#found + 1] = { code = table.concat(parts), syllables = #parts, tail = 0 }
            return
        end
        for last = n, pos, -1 do
            local sig = digits:sub(pos, last)
            for _idx, syl in ipairs(index.full[sig] or {}) do
                parts[#parts + 1] = syl
                walk(last + 1, parts)
                parts[#parts] = nil
            end
        end
        local rest = digits:sub(pos)
        if index.partial[rest] and not index.full[rest] then
            for prefix in pairs(index.partial[rest]) do
                found[#found + 1] = {
                    code = table.concat(parts) .. prefix, syllables = #parts + 1, tail = 1,
                }
            end
        end
    end
    walk(1, {})
    for i, item in ipairs(found) do item.order = i end
    table.sort(found, function(a, b)
        if a.tail ~= b.tail then return a.tail < b.tail end
        if a.syllables ~= b.syllables then return a.syllables < b.syllables end
        return a.order < b.order
    end)
    local out, seen = {}, {}
    local complete = found[1] and found[1].tail == 0
    for _idx, item in ipairs(found) do
        -- 有完整切分时半截音节只会带来噪音（64 → og / oh）
        if (item.tail == 0 or not complete) and not seen[item.code] and #out < MAX_CODES then
            seen[item.code] = true
            out[#out + 1] = item.code
        end
    end
    return out
end

--- 查词：单键给字母，多键逐个拼音码查拼音词库并去重合并。
---@param dictionary table 拼音词库
---@param digits string
---@return string[]
function T9.lookup(dictionary, digits)
    if #digits == 1 then
        local letters = {}
        for letter in GROUPS[digits]:gmatch(".") do letters[#letters + 1] = letter end
        return letters
    end
    -- 各拼音码的词表按名次交错合并：先按码拼接会让第一个码的词占满上限，
    -- 其余同键位的读音（如 64 的 mi / ni）永远排不进来。
    local lists, depth = {}, 0
    for _idx, code in ipairs(T9.codes(digits)) do
        local list = dictionary:lookup(code)
        if #list > 0 then
            lists[#lists + 1] = list
            depth = math.max(depth, #list)
        end
    end
    local words, seen = {}, {}
    for rank = 1, depth do
        for _idx, list in ipairs(lists) do
            local word = list[rank]
            if word and not seen[word] then
                seen[word] = true
                words[#words + 1] = word
            end
        end
        if #words >= MAX_WORDS then break end
    end
    return words
end

--- 九宫格键位：4 列 × 4 行；每行宽度合计 10，与候选行的 10 个占位键等宽。
---@param base table[] 原始 zh_CN 布局的行（取退格、地球、空格、回车键帽）
---@return table[]
function T9.rows(base)
    local util = require("util")
    local function key(width, entry)
        return { entry, entry, entry, entry, width = width }
    end
    local function digit(d)
        return key(2.5, { label = GROUPS[d]:upper(), alt_label = d, d })
    end
    local function copy(piece, width)
        local out = util.tableDeepCopy(piece)
        out.width = width
        return out
    end
    return {
        { key(2.5, "，"), digit("2"), digit("3"), copy(base[4][9], 2.5) },
        { key(2.5, "。"), digit("4"), digit("5"), digit("6") },
        { key(2.5, "！"), digit("7"), digit("8"), digit("9") },
        { copy(base[5][2], 2.5), copy(base[5][4], 5), copy(base[5][7], 2.5) },
    }
end

return T9
