--[[--
拼音词库只读查询（rime-ice 转换产物 dictionary.sqlite3）。

库由 pinyin/download 下载落盘到 $DATA/.moon/dictionary.sqlite3；
文件缺失 / 打不开 / 查询失败一律降级为空结果，绝不影响原生单字候选。

schema（tools/build_pinyin_dict.py 生成）：
  meta(k PRIMARY KEY, v)           -- source_tag / built_at / entries
  words(word, pinyin, weight)      -- pinyin 无声调、空格分隔音节（"ni hao"）
  INDEX idx_pinyin(pinyin, weight DESC)

查询模型：IME 给的输入码是连写拼音（"nihao"），词库键是空格分隔（"ni hao"）。
本模块把连写码按音节边界贪心切成空格分隔前缀，做 LIKE 'prefix%' 匹配，
再按音节边界过滤掉跨音节误命中（"ni" 不能命中 "niu"/"nie"）。
单字（8105 字表）与整词（base/ext/tencent）同库，前缀天然混合排序。

@module koplugin.book.pinyin.dictionary
--]]

local lfs = require("libs/libkoreader-lfs")
local Paths = require("utils.paths")

local M = {}

local MAX_CANDI = 100 -- 候选栏分页展示，单次最多保留 100 条

-- 拼音音节表（无声调，ü=v）。用于把连写码切成音节序列。
-- 来自现代汉语拼音方案全音节集合；宁可多不可少（多切不出词条只是无结果，不少）。
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
-- 最长音节 6（chuang/shuang）；建长度→集合 索引供贪心匹配
local SYL_BY_LEN = {}
local MAX_SYL_LEN = 0
for _, s in ipairs(SYLLABLES) do
    SYL_BY_LEN[#s] = SYL_BY_LEN[#s] or {}
    SYL_BY_LEN[#s][s] = true
    if #s > MAX_SYL_LEN then
        MAX_SYL_LEN = #s
    end
end

local _conn -- lua-ljsqlite3 连接；false = 已判定不可用
local _meta -- meta 缓存

--- 打开只读连接（只试一次；失败即标记不可用，后续直接走降级）。
---@return userdata|nil
local function ensureOpen()
    if _conn ~= nil then
        return _conn or nil
    end
    _conn = false
    local path = Paths.pinyinDictPath()
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" or (attr.size or 0) == 0 then
        return nil
    end
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok or not SQ3 then
        return nil
    end
    local ok2, c = pcall(SQ3.open, path, "ro")
    if not ok2 or not c then
        return nil
    end
    _conn = c
    return _conn
end

--- 词库是否可用（文件在且能打开）。
---@return boolean
function M.isAvailable()
    return ensureOpen() ~= nil
end

--- 词库文件是否已经落盘。与 isAvailable 分开，便于设置页区分“未下载”和“文件损坏/依赖缺失”。
---@return boolean
function M.fileExists()
    local attr = lfs.attributes(Paths.pinyinDictPath())
    return attr and attr.mode == "file" and (attr.size or 0) > 0 or false
end

--- 词库文件变更后调用（下载/更新落盘）：关旧连接、清缓存，下次访问重新打开。
--- 否则负缓存（_conn=false）会把「不可用」记到进程结束，设置页状态永远不刷新；
--- 已打开的旧连接也会继续读已删除的旧文件。
---@return nil
function M.reset()
    if _conn and _conn ~= false then
        pcall(function()
            _conn:close()
        end)
    end
    _conn = nil
    _meta = nil
end

--- 读 meta 键；库不可用返回 nil。
---@param k string
---@return string|nil
local function metaValue(k)
    if _meta then
        return _meta[k]
    end
    local conn = ensureOpen()
    if not conn then
        return nil
    end
    _meta = {}
    local ok = pcall(function()
        local stmt = conn:prepare("SELECT k, v FROM meta")
        if not stmt then
            return
        end
        for row in stmt:rows() do
            _meta[row[1]] = row[2]
        end
        stmt:close()
    end)
    if not ok then
        _meta = nil
        return nil
    end
    return _meta[k]
end

--- 词条总数（设置页状态显示用）；不可用返回 nil。
---@return string|nil
function M.entries()
    return metaValue("entries")
end

--- 来源 tag（rime-ice release）；不可用返回 nil。
---@return string|nil
function M.sourceTag()
    return metaValue("source_tag")
end

--- 连写码 → 空格分隔前缀（贪心最长匹配音节）。
--- "nihao" → "ni hao"；"ni h"（输到一半）→ "ni h"。切不出完整首音节返回 nil。
---@param code string 纯小写连写拼音
---@return string|nil
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
        if matched then
            parts[#parts + 1] = matched
            i = i + #matched
        else
            -- 最后一个不完整音节（用户还在敲）：原样收尾
            parts[#parts + 1] = code:sub(i)
            break
        end
    end
    return table.concat(parts, " ")
end

--- 前缀查词：连写输入码 → 候选词列表，按权重降序。
--- 音节边界过滤：词库拼音的前缀必须与输入码的切分逐段兼容——
--- 输入码 "ni" 只允许命中 "ni" 或 "ni X..."，不允许 "niu"/"nie"（不同音节）。
---@param code string 连写拼音（纯小写）
---@return string[]
function M.lookup(code)
    if type(code) ~= "string" or not code:match("^[a-z]+$") then
        return {}
    end
    local conn = ensureOpen()
    if not conn then
        return {}
    end
    local prefix = M.toPrefix(code)
    if not prefix or prefix == "" then
        return {}
    end
    -- 音节数：输入码切出几段
    local syl_count = select(2, prefix:gsub(" ", "")) + 1
    local out = {}
    local ok = pcall(function()
        -- LIKE 前缀走索引；% 转义不需要（拼音无 %/_）
        local stmt = conn:prepare(
            "SELECT word, pinyin FROM words WHERE pinyin LIKE ? ORDER BY weight DESC LIMIT " .. (MAX_CANDI * 8)
        )
        if not stmt then
            return
        end
        stmt:bind1(1, prefix .. "%")
        for row in stmt:rows() do
            -- 音节边界校验：词库拼音第 syl_count 段必须以输入码末段开头，
            -- 且其后的边界必须落在空格或词尾（防 "ni" 命中 "niu"）
            local py = row[2]
            if M._boundaryOk(py, prefix) then
                out[#out + 1] = row[1]
                if #out >= MAX_CANDI then
                    break
                end
            end
        end
        stmt:close()
    end)
    if not ok then
        return {}
    end
    if #out == 0 and #code >= 2 then
        local pattern = code:sub(1, 1) .. "%"
        for i = 2, #code do
            pattern = pattern .. " " .. code:sub(i, i) .. "%"
        end
        pcall(function()
            local stmt = conn:prepare(
                "SELECT word FROM words WHERE pinyin LIKE ? ORDER BY weight DESC LIMIT " .. MAX_CANDI
            )
            if not stmt then return end
            stmt:bind1(1, pattern)
            for row in stmt:rows() do out[#out + 1] = row[1] end
            stmt:close()
        end)
    end
    return out
end

--- 校验词库拼音 py 是否与输入前缀 prefix 在音节边界上兼容。
--- prefix 由 toPrefix 生成（空格分隔，末段可能不完整）。
--- 规则：py 必须以 prefix 为前缀；且 prefix 的每个完整段与 py 对应段严格相等
--- （"ni" 不允许命中 "niu"），末段允许是 py 对应段的前缀（"ni h" 命中 "ni hao"）。
---@param py string 词库拼音（"ni hao"）
---@param prefix string 输入前缀（"ni h"）
---@return boolean
function M._boundaryOk(py, prefix)
    if py:sub(1, #prefix) ~= prefix then
        return false
    end
    -- 逐段校验：除末段外，prefix 的每段必须等于 py 对应段
    local pi = 1
    local segs = {}
    for seg in prefix:gmatch("[^ ]+") do
        segs[#segs + 1] = seg
    end
    for idx, seg in ipairs(segs) do
        local sp = py:find(" ", pi, true)
        local py_seg = py:sub(pi, sp and (sp - 1) or #py)
        if idx < #segs then
            -- 完整段：严格相等
            if py_seg ~= seg then
                return false
            end
            if not sp then
                return false -- py 段数少于 prefix 完整段数
            end
        else
            -- 末段：py 段以 seg 开头即可（含相等）
            if py_seg:sub(1, #seg) ~= seg then
                return false
            end
        end
        if not sp then
            break
        end
        pi = sp + 1
    end
    return true
end

return M
