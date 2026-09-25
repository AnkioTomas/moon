--[[--
拼音词库只读查询（rime-ice 转换产物 dictionary.sqlite3）。

库由 ime/download 下载落盘到 $DATA/.moon/dictionary.sqlite3；
文件缺失 / 打不开 / 查询失败一律降级为空结果，绝不影响原生单字候选。

schema（tools/build_pinyin_dict.py 生成）：
  meta(k PRIMARY KEY, v)                    -- schema_version / source_tag / built_at / entries
  words(word, code, initials, weight)       -- code="nihao"，initials="nh"
  quick(mode, code, rank, word_id)          -- 高频短码已在构建期排好前 21 候选
  INDEX idx_code(code, weight DESC)
  INDEX idx_initials(initials, weight DESC)

查询模型：短码是输入最高频路径，构建期已把其候选按权重排好，设备只做
`mode + code` 的等值读取。长码命中集合已足够小，才退回 `code GLOB 'nihao*'`
或 `initials GLOB 'nhg*'`。输入码只允许小写 ASCII；单字母半截不查。

连接、meta 与语句缓存复用 ime.table_dictionary，这里只覆写 lookup。

@module koplugin.book.ime.pinyin.dictionary
--]]

local M = require("ime.table_dictionary"):new("pinyin", "2")

local MAX_CANDI = 21 -- 候选栏约 3 页，多了也翻不到
local QUICK_DIRECT_MAX = 6
local QUICK_ABBREV_MAX = 5
local SQL_QUICK = "SELECT words.word FROM quick JOIN words ON words.rowid = quick.word_id"
    .. " WHERE quick.mode = ? AND quick.code = ? ORDER BY quick.rank LIMIT " .. MAX_CANDI
local SQL_EXACT = "SELECT word FROM words WHERE code = ? ORDER BY weight DESC LIMIT " .. MAX_CANDI
local SQL_DIRECT = "SELECT word FROM words WHERE code GLOB ? ORDER BY weight DESC LIMIT " .. MAX_CANDI
local SQL_ABBREV = "SELECT word FROM words WHERE initials GLOB ? ORDER BY weight DESC LIMIT " .. MAX_CANDI

-- 拼音音节表（无声调，ü=v），用于把连写输入切为词库的空格分隔形式。
local SYLLABLES = {
    "a", "ai", "an", "ang", "ao",
    "ba", "bai", "ban", "bang", "bao", "bei", "ben", "beng", "bi", "bian", "biao", "bie", "bin", "bing", "bo", "bu",
    "ca", "cai", "can", "cang", "cao", "ce", "cen", "ceng", "ci", "cong", "cou", "cu", "cuan", "cui", "cun", "cuo",
    "cha", "chai", "chan", "chang", "chao", "che", "chen", "cheng", "chi", "chong", "chou", "chu", "chua", "chuai",
    "chuan", "chuang", "chui", "chun", "chuo",
    "da", "dai", "dan", "dang", "dao", "de", "dei", "den", "deng", "di", "dia", "dian", "diao", "die", "ding",
    "diu", "dong", "dou", "du", "duan", "dui", "dun", "duo",
    "e", "ei", "en", "eng", "er",
    "fa", "fan", "fang", "fei", "fen", "feng", "fo", "fou", "fu",
    "ga", "gai", "gan", "gang", "gao", "ge", "gei", "gen", "geng", "gong", "gou", "gu", "gua", "guai", "guan",
    "guang", "gui", "gun", "guo",
    "ha", "hai", "han", "hang", "hao", "he", "hei", "hen", "heng", "hong", "hou", "hu", "hua", "huai", "huan",
    "huang", "hui", "hun", "huo",
    "ji", "jia", "jian", "jiang", "jiao", "jie", "jin", "jing", "jiong", "jiu", "ju", "juan", "jue", "jun",
    "ka", "kai", "kan", "kang", "kao", "ke", "kei", "ken", "keng", "kong", "kou", "ku", "kua", "kuai", "kuan",
    "kuang", "kui", "kun", "kuo",
    "la", "lai", "lan", "lang", "lao", "le", "lei", "leng", "li", "lia", "lian", "liang", "liao", "lie", "lin",
    "ling", "liu", "long", "lou", "lu", "lv", "luan", "lve", "lun", "luo",
    "ma", "mai", "man", "mang", "mao", "me", "mei", "men", "meng", "mi", "mian", "miao", "mie", "min", "ming",
    "miu", "mo", "mou", "mu",
    "na", "nai", "nan", "nang", "nao", "ne", "nei", "nen", "neng", "ni", "nian", "niang", "niao", "nie", "nin",
    "ning", "niu", "nong", "nou", "nu", "nv", "nuan", "nve", "nun", "nuo",
    "o", "ou",
    "pa", "pai", "pan", "pang", "pao", "pei", "pen", "peng", "pi", "pian", "piao", "pie", "pin", "ping", "po",
    "pou", "pu",
    "qi", "qia", "qian", "qiang", "qiao", "qie", "qin", "qing", "qiong", "qiu", "qu", "quan", "que", "qun",
    "ran", "rang", "rao", "re", "ren", "reng", "ri", "rong", "rou", "ru", "ruan", "rui", "run", "ruo",
    "sa", "sai", "san", "sang", "sao", "se", "sen", "seng", "si", "song", "sou", "su", "suan", "sui", "sun", "suo",
    "sha", "shai", "shan", "shang", "shao", "she", "shei", "shen", "sheng", "shi", "shou", "shu", "shua", "shuai",
    "shuan", "shuang", "shui", "shun", "shuo",
    "ta", "tai", "tan", "tang", "tao", "te", "teng", "ti", "tian", "tiao", "tie", "ting", "tong", "tou", "tu",
    "tuan", "tui", "tun", "tuo",
    "wa", "wai", "wan", "wang", "wei", "wen", "weng", "wo", "wu",
    "xi", "xia", "xian", "xiang", "xiao", "xie", "xin", "xing", "xiong", "xiu", "xu", "xuan", "xue", "xun",
    "ya", "yan", "yang", "yao", "ye", "yi", "yin", "ying", "yo", "yong", "you", "yu", "yuan", "yue", "yun",
    "za", "zai", "zan", "zang", "zao", "ze", "zei", "zen", "zeng", "zi", "zong", "zou", "zu", "zuan", "zui",
    "zun", "zuo",
    "zha", "zhai", "zhan", "zhang", "zhao", "zhe", "zhei", "zhen", "zheng", "zhi", "zhong", "zhou", "zhu", "zhua",
    "zhuai", "zhuan", "zhuang", "zhui", "zhun", "zhuo",
}
-- 按长度索引，供最长音节优先的贪心匹配。
local SYL_BY_LEN = {}
local MAX_SYL_LEN = 0
for _, s in ipairs(SYLLABLES) do
    SYL_BY_LEN[#s] = SYL_BY_LEN[#s] or {}
    SYL_BY_LEN[#s][s] = true
    if #s > MAX_SYL_LEN then
        MAX_SYL_LEN = #s
    end
end
-- 用于区分不完整音节和简拼。
local SYL_PREFIX = {}
for _, s in ipairs(SYLLABLES) do
    for i = 1, #s do
        SYL_PREFIX[s:sub(1, i)] = true
    end
end

--- 连写码 → 空格分隔前缀（贪心最长匹配音节）。
--- "nihao" → "ni hao", true；"nih" → "ni h", false。
---@param code string 纯小写连写拼音
---@return string prefix
---@return boolean complete 全部切成完整音节（末段不是半截）
function M.toPrefix(code)
    local parts = {}
    local i = 1
    local n = #code
    while i <= n do
        local matched
        local max_len = math.min(MAX_SYL_LEN, n - i + 1)
        for len = max_len, 1, -1 do
            local seg = code:sub(i, i + len - 1)
            if SYL_BY_LEN[len] and SYL_BY_LEN[len][seg] then
                matched = seg
                break
            end
        end
        if not matched then
            parts[#parts + 1] = code:sub(i)
            return table.concat(parts, " "), false
        end
        parts[#parts + 1] = matched
        i = i + #matched
    end
    return table.concat(parts, " "), true
end

--- 简拼：默认每个音节取首字母，也接受 zh/ch/sh 展开的声母。
--- 「jfyhdcm」和「jfyhdchm」都可命中「江枫渔火对愁眠」。
---@param code string 纯小写连写拼音
---@return string 简拼码
local function abbrevCode(code)
    local out = {}
    local i = 1
    local n = #code
    while i <= n do
        local pair = code:sub(i, i + 1)
        if pair == "zh" or pair == "ch" or pair == "sh" then
            out[#out + 1] = pair:sub(1, 1)
            i = i + 2
        else
            out[#out + 1] = code:sub(i, i)
            i = i + 1
        end
    end
    return table.concat(out)
end

--- 输入码应走哪张索引。保持单音节仅精确匹配的历史语义。
---@param code string
---@return "exact"|"direct"|"abbrev"|nil
local function lookupKind(code)
    local prefix, complete = M.toPrefix(code)
    if complete then
        return prefix:find(" ", 1, true) and "direct" or "exact"
    end
    local last = prefix:match("([^ ]+)$") or prefix
    local has_space = prefix:find(" ", 1, true) ~= nil
    if has_space or SYL_PREFIX[last] then
        if #code < 3 and not has_space then
            return nil
        end
        return "direct"
    end
    return #code >= 2 and "abbrev" or nil
end
--- 连写输入码转候选词，按词频降序。
--- 高频短码走构建期排序结果；长码才走原始索引前缀查询。
---@param code string 连写拼音（纯小写）
---@return string[]
function M:lookup(code)
    if type(code) ~= "string" or not code:match("^[a-z]+$") then
        return {}
    end
    if not self:open() then
        return {}
    end
    local kind = lookupKind(code)
    if not kind then
        return {}
    end

    local out = {}
    local ok = pcall(function()
        if kind == "exact" then
            out = self:fetch("exact", SQL_EXACT, code)
            return
        end

        local quick_mode = kind == "direct" and "direct" or "abbrev"
        local quick_limit = kind == "direct" and QUICK_DIRECT_MAX or QUICK_ABBREV_MAX
        if #code <= quick_limit then
            out = self:fetch("quick", SQL_QUICK, quick_mode, code)
            if #out > 0 then
                return
            end
        end

        if kind == "direct" then
            out = self:fetch("direct", SQL_DIRECT, code .. "*")
        else
            out = self:fetch("abbrev", SQL_ABBREV, abbrevCode(code) .. "*")
        end
    end)
    if not ok then
        -- 查询异常后语句可能停在 SQLITE_ROW；重置缓存语句，下一次输入仍可正常查词。
        for _, stmt in pairs(self.statements or {}) do
            pcall(function()
                stmt:clearbind():reset()
            end)
        end
        return {}
    end
    return out
end

return M
