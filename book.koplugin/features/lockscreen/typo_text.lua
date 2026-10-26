--[[--
文字海报的纯文本规则：切字、按词断行 + 避头尾、分句、竖排标点、挑关键词。不碰绘图，便于单测。

@module koplugin.book.features.lockscreen.typo_text
--]]

local M = {}

--- UTF-8 切成字符数组。
---@param text string
---@return string[]
function M.chars(text)
    local out = {}
    for ch in tostring(text or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        out[#out + 1] = ch
    end
    return out
end

local function set(list)
    local s = {}
    for _idx, ch in ipairs(M.chars(list)) do s[ch] = true end
    return s
end

-- 行首禁则：收尾标点不能开头；行尾禁则：开头括号引号不能收尾。
M.NO_START = set("，。、；：！？）》」』】〉〕…—·‧,.;:!?)]}%’”")
M.NO_END = set("（《「『【〈〔“‘([{")
local PUNCT = set("，。、；：！？（）《》「」『』【】〈〉〔〕…—·‧,.;:!?()[]{}“”‘’ ")
-- 分句点：其后断开（连续的标点归前一句）。
local CLAUSE_END = set("，。、；：！？…,;:!?")

---@param ch string
---@return boolean
function M.isPunct(ch) return PUNCT[ch] == true end

--- 断行单元：按词（分词结果）一个单元，连续拉丁字母 / 数字一整个单元，标点、空格各自成单元；
--- keep（关键词）整体一个单元，绝不拆到两行。
---@param text string
---@param keep string|nil
---@return string[]
function M.units(text, keep)
    local units, word = {}, nil
    local function push(u)
        if u:match("^[%w'%-]$") then
            word = (word or "") .. u
            return
        end
        if word then units[#units + 1], word = word, nil end
        if u ~= "\n" and u ~= "\r" and u ~= "\t" then units[#units + 1] = u end
    end
    local function piece(s)
        for _idx, w in ipairs(M.segment(s)) do push(w) end
    end
    text = tostring(text or "")
    local pos = 1
    if keep and keep ~= "" then
        while true do
            local a, b = text:find(keep, pos, true)
            if not a then break end
            piece(text:sub(pos, a - 1))
            if word then units[#units + 1], word = word, nil end
            units[#units + 1] = keep
            pos = b + 1
        end
    end
    piece(text:sub(pos))
    if word then units[#units + 1] = word end
    return units
end

local function firstChar(unit) return M.chars(unit)[1] end
local function lastChar(unit) local c = M.chars(unit); return c[#c] end

--- 贪心断行 + 避头尾：下一单元若以收尾标点开头，就挂到本行末（允许超出，标点悬挂）；
--- 本行若以开头括号收尾，就把它推到下一行。行首空格丢掉。
---@param text string
---@param max number 每行容量（与 measure 同单位）
---@param measure (fun(unit: string): number)|nil 缺省按字符数
---@param keep string|nil 不拆开的关键词
---@return string[]
function M.breakLines(text, max, measure, keep)
    measure = measure or function(unit) return #M.chars(unit) end
    local lines, cur, used = {}, {}, 0
    local function flush()
        while cur[#cur] == " " do cur[#cur] = nil end
        if #cur > 0 then lines[#lines + 1] = table.concat(cur) end
        cur, used = {}, 0
    end
    for _idx, unit in ipairs(M.units(text, keep)) do
        local w = measure(unit)
        if #cur == 0 and unit == " " then
            -- 行首空格不占位
        elseif used + w <= max or #cur == 0 or M.NO_START[firstChar(unit)] then
            cur[#cur + 1], used = unit, used + w
        else
            local carry = {}
            while #cur > 1 and M.NO_END[lastChar(cur[#cur])] do
                table.insert(carry, 1, table.remove(cur))
            end
            flush()
            for _i, u in ipairs(carry) do cur[#cur + 1], used = u, used + measure(u) end
            if not (#cur == 0 and unit == " ") then cur[#cur + 1], used = unit, used + w end
        end
    end
    flush()
    return lines
end

--- 分句：在逗号句号等之后断开，标点留在句尾；英文标点要后跟空格才断。去首尾空白，丢空句。
---@param text string
---@return string[]
function M.clauses(text)
    local out, cur = {}, {}
    local chars = M.chars((tostring(text or ""):gsub("[\r\n\t]", " ")))
    local function flush()
        local s = table.concat(cur):gsub("^%s+", ""):gsub("%s+$", "")
        if s ~= "" then out[#out + 1] = s end
        cur = {}
    end
    for i, ch in ipairs(chars) do
        cur[#cur + 1] = ch
        local nxt = chars[i + 1]
        if CLAUSE_END[ch] and not (nxt and (CLAUSE_END[nxt] or M.NO_START[nxt]))
            and (#ch > 1 or nxt == nil or nxt == " ") then
            flush()
        end
    end
    flush()
    return out
end

-- 竖排用的标点：优先 Unicode 竖排形（U+FE10…），其余由绘制端居中。
local VERTICAL = {
    ["，"] = "︐", ["、"] = "︑", ["。"] = "︒", ["："] = "︓", ["；"] = "︔",
    ["！"] = "︕", ["？"] = "︖", ["…"] = "︙", ["—"] = "︱", ["－"] = "︲",
    ["（"] = "︵", ["）"] = "︶", ["《"] = "︽", ["》"] = "︾", ["〈"] = "︿", ["〉"] = "﹀",
    ["「"] = "﹁", ["」"] = "﹂", ["『"] = "﹃", ["』"] = "﹄", ["【"] = "︻", ["】"] = "︼",
    ["“"] = "﹁", ["”"] = "﹂", ["‘"] = "﹃", ["’"] = "﹄", ["("] = "︵", [")"] = "︶",
    [","] = "︐", ["."] = "︒", [":"] = "︓", [";"] = "︔", ["!"] = "︕", ["?"] = "︖",
}

---@param ch string
---@return string
function M.vertical(ch) return VERTICAL[ch] or ch end

-- 词表：jieba dict.txt（MIT）前 4 万个 2–4 字词，按 log2 词频分桶、带词性首字母。
M.WORDS_PATH = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$") or ".") .. "/typo_words.txt"
local dict

--- 懒加载词表：词 → 频次桶 * 256 + 词性字节（一个数，省掉 4 万个小表）。
---@return table<string, number>
function M.dict()
    if dict then return dict end
    local f = assert(io.open(M.WORDS_PATH, "r"))
    local d, b, p = {}, nil, nil
    for line in f:lines() do
        if line:match("^@%l%a$") then
            b, p = line:byte(2) - 97, line:byte(3)
        elseif b and line:sub(1, 1) ~= "#" then
            for w in line:gmatch("%S+") do d[w] = b * 256 + p end
        end
    end
    f:close()
    dict = d
    return d
end

--- 释放词表（约 3MB），画完一张海报即调；下次用时重读。
function M.release() dict = nil end

local function isHan(ch) return #ch == 3 and ch >= "\228\184\128" and ch <= "\233\191\191" end

--- 最大概率分词：每个汉字连续段做 DP，词典词 logP = 桶 - 26，单字 -24；非汉字原样成段。
---@param text string
---@return string[]
function M.segment(text)
    local d, out, run = M.dict(), {}, {}
    local function flush()
        local n = #run
        if n == 0 then return end
        local best, from = { [0] = 0 }, {}
        for i = 1, n do
            best[i], from[i] = best[i - 1] - 24, i - 1
            for len = 2, math.min(4, i) do
                local e = d[table.concat(run, "", i - len + 1, i)]
                local b = e and math.floor(e / 256)
                if b and best[i - len] + b - 26 > best[i] then
                    best[i], from[i] = best[i - len] + b - 26, i - len
                end
            end
        end
        local seg, i = {}, n
        while i > 0 do
            table.insert(seg, 1, table.concat(run, "", from[i] + 1, i))
            i = from[i]
        end
        for _idx, w in ipairs(seg) do out[#out + 1] = w end
        run = {}
    end
    for _idx, ch in ipairs(M.chars(text)) do
        if isHan(ch) then run[#run + 1] = ch else flush(); out[#out + 1] = ch end
    end
    flush()
    return out
end

-- 词性权重：名词最重，成语/习语次之；虚词（副、代、连、介、助、数、量）不入选。
local POS = { n = 3, l = 2.5, i = 2.5, s = 1.5, j = 1.5, a = 1.2, v = 1, b = 1, z = 1, t = 1 }
local function wordSet(list)
    local s = {}
    for w in list:gmatch("%S+") do s[w] = true end
    return s
end
local STOP = wordSet("就是 一个 什么 没有 可以 这个 那个 我们 你们 他们 自己 已经 因为 所以 但是 如果 还是 只是 不是 这样 那样 "
    .. "怎么 为什么 时候 东西 主义 最好 一切 一种 一样 所有 应该 能够 知道 觉得 需要 成为 发现 找出 出来 起来 之中 之间 "
    .. "以后 以前 现在 永远 总是 真正 彻头彻尾 每个 这些 那些 一些 有些 其实 甚至 或者 而是 非常 比较 不会 不能 开始")
local EN_STOP = wordSet("the and that this with from have been were they their there which would could should about "
    .. "into than then them what when where while your yours because being other some such only very just more most "
    .. "better someone something everything nothing")

--- 低于此分不放大关键词，版式退回无大字。
M.MIN_SCORE = 2.5

--- 候选词与分数（高到低，去重）：分词后给 2–4 字词打分：词性 + 辨识度（不太常见也不极罕见）
--- + 越靠句尾越重 + 重复出现加分。没有汉字词时取 ≥4 字母的非虚词英文单词，越长越高。
---@param text string
---@return table[] { {word, score}, ... }
function M.rankWords(text)
    local d, segs = M.dict(), M.segment(text)
    local seen, best, at = {}, {}, {}
    for _idx, w in ipairs(segs) do seen[w] = (seen[w] or 0) + 1 end
    for i, w in ipairs(segs) do
        local e = d[w]
        local pos = e and POS[string.char(e % 256)]
        if pos and not STOP[w] then
            local b = math.floor(e / 256)
            local s = pos + (#w == 12 and 0.3 or 0)
                + math.min(11, math.max(0, 16 - b)) * 0.3 - (b < 5 and (5 - b) * 0.4 or 0)
                + 0.8 * i / #segs + (seen[w] - 1) * 1.5
            if not best[w] or s > best[w] then best[w], at[w] = s, i end
        end
    end
    local list = {}
    for w, s in pairs(best) do list[#list + 1] = { w, s, at[w] } end
    if #list == 0 then
        for w in tostring(text):gmatch("%a+") do
            if #w >= 4 and not EN_STOP[w:lower()] and not best[w] then
                best[w] = M.MIN_SCORE + #w * 0.2
                list[#list + 1] = { w, best[w], #list }
            end
        end
    end
    -- 同分取先出现的；英文同分取更长（分数已含长度）里先出现的
    table.sort(list, function(a, b) return a[2] > b[2] or (a[2] == b[2] and a[3] < b[3]) end)
    return list
end

--- 关键词与分数。
---@param text string
---@return string|nil keyword, number score
function M.scoreKeyword(text)
    local top = M.rankWords(text)[1]
    if top then return top[1], top[2] end
    return nil, -math.huge
end

--- 关键词：显式【标记】优先；否则分词打分，分数不够返回 nil（宁缺毋滥）。
---@param text string
---@return string|nil
function M.keyword(text)
    text = tostring(text or "")
    local marked = text:match("【(.-)】")
    if marked and marked ~= "" then return marked end
    local kw, score = M.scoreKeyword(text)
    if kw and score >= M.MIN_SCORE then return kw end
    return nil
end

--- 去掉【】标记，留给正文显示。
---@param text string
---@return string
function M.strip(text)
    return (tostring(text or ""):gsub("【", ""):gsub("】", ""))
end

--- 按分数从高到低的候选词，用于散落背景字。
---@param text string
---@param n number
---@return string[]
function M.topWords(text, n)
    local out = {}
    for _idx, it in ipairs(M.rankWords(text)) do
        if #out >= n then break end
        out[#out + 1] = it[1]
    end
    return out
end

return M
