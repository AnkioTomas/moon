--[[--
生僻字注音词库：解析、查找、屏上文字匹配。纯函数，不碰 UI 与文件以外的东西。

词库文件是 UTF-8 文本（格式见同目录 README.md）：

  #name=汉字拼音      元信息，# 开头，key=value
  #lang=zh           zh：逐字匹配 + 多字词组最长匹配；en：按字母切词、小写、简单词形还原
  #levels=6500,3500,0  三档阈值：最生僻 / 生僻 / 全部；rank 大于阈值才注音
  字<TAB>注音<TAB>rank

@module koplugin.book.features.rare.lexicon
--]]

local Lexicon = {}

--- 档位在 levels 里的下标。
Lexicon.LEVELS = { rarest = 1, rare = 2, all = 3 }

local DEFAULT_LEVELS = { zh = { 6500, 3500, 0 }, en = { 20000, 8000, 0 } }

---@class RareLexicon
---@field meta table<string, string>
---@field lang string
---@field levels number[]
---@field entries table<string, { [1]: string, [2]: number }> key → { 注音, rank }
---@field max_len integer 最长 key 的字数（zh 词组最长匹配用）

--- 解析词库文本；坏行跳过，没有任何条目时报错。
---@param text string
---@return RareLexicon
function Lexicon.parse(text)
    local meta, entries, max_len, count = {}, {}, 1, 0
    for line in text:gmatch("[^\r\n]+") do
        if line:sub(1, 1) == "#" then
            local k, v = line:match("^#%s*([%w_]+)%s*=%s*(.-)%s*$")
            if k then meta[k] = v end
        else
            local key, ann, rank = line:match("^([^\t]+)\t([^\t]+)\t(%d+)")
            if key then
                entries[key] = { ann, tonumber(rank) }
                count = count + 1
                local n = select(2, key:gsub("[^\128-\191]", ""))
                if n > max_len then max_len = n end
            end
        end
    end
    if count == 0 then error("empty lexicon") end
    local lang = meta.lang == "zh" and "zh" or "en"
    local levels = {}
    for n in (meta.levels or ""):gmatch("%d+") do levels[#levels + 1] = tonumber(n) end
    if #levels ~= 3 then levels = DEFAULT_LEVELS[lang] end
    return { meta = meta, lang = lang, levels = levels, entries = entries, max_len = max_len, count = count }
end

---@param lex RareLexicon
---@param level "rarest"|"rare"|"all"
---@return number
function Lexicon.threshold(lex, level)
    return lex.levels[Lexicon.LEVELS[level] or 2]
end

--- 英文词形还原的候选（复数、过去式、进行时）。只在原词查不到时用。
---@param word string 小写
---@return string[]
function Lexicon.stems(word)
    local out = {}
    local function add(s) if #s >= 3 then out[#out + 1] = s end end
    if word:sub(-3) == "ies" then add(word:sub(1, -4) .. "y") end
    if word:sub(-2) == "es" then add(word:sub(1, -3)) end
    if word:sub(-1) == "s" then add(word:sub(1, -2)) end
    if word:sub(-2) == "ed" then add(word:sub(1, -3)); add(word:sub(1, -2)) end
    if word:sub(-3) == "ing" then add(word:sub(1, -4)); add(word:sub(1, -4) .. "e") end
    return out
end

--- 英文：按连续字母切词。
---@param text string
---@return string[]
function Lexicon.words(text)
    local out = {}
    for w in text:gmatch("%a+") do out[#out + 1] = w end
    return out
end

---@param lex RareLexicon
---@param word string 原文
---@return table|nil
local function lookupWord(lex, word)
    local lower = word:lower()
    local e = lex.entries[lower]
    if e then return e end
    for _idx, stem in ipairs(Lexicon.stems(lower)) do
        e = lex.entries[stem]
        if e then return e end
    end
end

--- 屏上文字里 rank 超过阈值的词，按出现顺序去重：{ key = 原文, ann = 注音 }。
---@param lex RareLexicon
---@param text string
---@param threshold number
---@param limit integer|nil 最多返回几个
---@return { key: string, ann: string }[]
function Lexicon.match(lex, text, threshold, limit)
    local out, seen = {}, {}
    limit = limit or math.huge
    local function hit(key, e)
        if e[2] > threshold and not seen[key] then
            seen[key] = true
            out[#out + 1] = { key = key, ann = e[1] }
        end
    end
    if lex.lang == "en" then
        for _idx, w in ipairs(Lexicon.words(text)) do
            if #out >= limit then break end
            if #w >= 3 then
                local e = lookupWord(lex, w)
                if e then hit(w, e) end
            end
        end
        return out
    end
    local chars = {}
    for c in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = c end
    local i = 1
    while i <= #chars and #out < limit do
        local step = 1
        -- 只有非 ASCII 字才查；最长词组优先，词组读音覆盖单字首选读音。
        if #chars[i] > 1 then
            for n = math.min(lex.max_len, #chars - i + 1), 1, -1 do
                local key = table.concat(chars, "", i, i + n - 1)
                local e = lex.entries[key]
                if e then
                    hit(key, e)
                    step = n
                    break
                end
            end
        end
        i = i + step
    end
    return out
end

return Lexicon
