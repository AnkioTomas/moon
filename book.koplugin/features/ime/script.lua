--[[--
候选词简繁转换（OpenCC 精简表，见 tools/build_opencc.py）。

表是插件自带的只读 SQLite `opencc.sqlite3`（s2t 简 → 繁，t2s 繁 → 简，主键索引），不读进内存：
每批候选把全部子串（不超过该方向最长源词字数）一次 IN 查询取回，再按最长匹配转换——
先词组（如 头发 → 頭髮），没有再单字，单字也没有就原样保留。一批最多 21 个候选，只查一次。

@module koplugin.book.features.ime.script
--]]

local Script = {}

local PATH = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$") .. "/opencc.sqlite3"
local UTF8_CHAR = "[%z\1-\127\194-\244][\128-\191]*"
-- 低于老版本 SQLite 的绑定参数上限 999。
local CHUNK = 500

--- 转换目标 → 表名。
local TABLES = { traditional = "s2t", simplified = "t2s" }

local conn
---@type table<string, integer>
local max_len = {}

---@return table
local function open()
    if conn then return conn end
    conn = require("lua-ljsqlite3/init").open(PATH, "ro")
    local stmt = conn:prepare("SELECT k, v FROM meta WHERE k IN ('s2t_max', 't2s_max')")
    for row in stmt:rows() do max_len[row[1]:sub(1, 3)] = tonumber(row[2]) end
    stmt:close()
    return conn
end

--- 一次取回 keys 里在表中的映射。
---@param tbl string
---@param keys string[]
---@return table<string, string>
local function fetch(tbl, keys)
    local map = {}
    for first = 1, #keys, CHUNK do
        local last = math.min(#keys, first + CHUNK - 1)
        local stmt = open():prepare("SELECT k, v FROM " .. tbl .. " WHERE k IN (?"
            .. string.rep(",?", last - first) .. ")")
        for i = first, last do stmt:bind1(i - first + 1, keys[i]) end
        for row in stmt:rows() do map[row[1]] = row[2] end
        stmt:close()
    end
    return map
end

---@param chars string[]
---@param map table<string, string>
---@param max integer
---@return string
local function longestMatch(chars, map, max)
    local out, i = {}, 1
    while i <= #chars do
        local hit, len
        for n = math.min(max, #chars - i + 1), 2, -1 do
            hit = map[table.concat(chars, "", i, i + n - 1)]
            if hit then len = n break end
        end
        if not hit then hit, len = map[chars[i]] or chars[i], 1 end
        out[#out + 1] = hit
        i = i + len
    end
    return table.concat(out)
end

--- 文本列表逐条转成目标字形（按位对齐，不去重）。
---@param texts string[]
---@param target "simplified"|"traditional"
---@return string[]
function Script.convertTexts(texts, target)
    local tbl = TABLES[target]
    open()
    local max = max_len[tbl]
    local split, keys, seen = {}, {}, {}
    for w, text in ipairs(texts) do
        local chars = {}
        for ch in text:gmatch(UTF8_CHAR) do chars[#chars + 1] = ch end
        split[w] = chars
        for i = 1, #chars do
            for j = i, math.min(#chars, i + max - 1) do
                local key = table.concat(chars, "", i, j)
                if not seen[key] then
                    seen[key] = true
                    keys[#keys + 1] = key
                end
            end
        end
    end
    local map = fetch(tbl, keys)
    local out = {}
    for w = 1, #texts do out[w] = longestMatch(split[w], map, max) end
    return out
end

--- 候选词表转成目标字形；保序，转换后重复的词只留第一个（如 乾 / 干 转简体后都是 干）。
---@param words string[]
---@param target "simplified"|"traditional"
---@return string[]
function Script.convertWords(words, target)
    local out, dup = {}, {}
    for _idx, converted in ipairs(Script.convertTexts(words, target)) do
        if not dup[converted] then
            dup[converted] = true
            out[#out + 1] = converted
        end
    end
    return out
end

return Script
