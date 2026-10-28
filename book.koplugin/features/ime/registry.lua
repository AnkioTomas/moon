--[[--
中文输入法注册表。

每个方法只声明按键映射、键帽和词库；候选状态机不按输入法堆分支。

@module koplugin.book.features.ime.registry
--]]

local Settings = require("utils.settings")
local _ = require("gettext")

local CANGJIE = {
    a = "日", b = "月", c = "金", d = "木", e = "水", f = "火", g = "土",
    h = "竹", i = "戈", j = "十", k = "大", l = "中", m = "一", n = "弓",
    o = "人", p = "心", q = "手", r = "口", s = "尸", t = "廿", u = "山",
    v = "女", w = "田", x = "難", y = "卜",
}

local WUBI = {
    q = "金", w = "人", e = "月", r = "白", t = "禾",
    y = "言", u = "立", i = "水", o = "火", p = "之",
    a = "工", s = "木", d = "大", f = "土", g = "王",
    h = "目", j = "日", k = "口", l = "田",
    x = "纟", c = "又", v = "女", b = "子", n = "已", m = "山",
}

local ZHUYIN = {
    ["1"] = "ㄅ", q = "ㄆ", a = "ㄇ", z = "ㄈ",
    ["2"] = "ㄉ", w = "ㄊ", s = "ㄋ", x = "ㄌ",
    e = "ㄍ", d = "ㄎ", c = "ㄏ", r = "ㄐ", f = "ㄑ", v = "ㄒ",
    ["5"] = "ㄓ", t = "ㄔ", g = "ㄕ", b = "ㄖ",
    y = "ㄗ", h = "ㄘ", n = "ㄙ", u = "ㄧ", j = "ㄨ", m = "ㄩ",
    ["8"] = "ㄚ", i = "ㄛ", k = "ㄜ", [","] = "ㄝ",
    ["9"] = "ㄞ", o = "ㄟ", l = "ㄠ", ["."] = "ㄡ",
    ["0"] = "ㄢ", p = "ㄣ", [";"] = "ㄤ", ["/"] = "ㄥ", ["-"] = "ㄦ",
    ["6"] = "ˊ", ["3"] = "ˇ", ["4"] = "ˋ", ["7"] = "˙",
}

-- 声母键标 zh/ch/sh，其余标韵母；a/e 与字母同形不标。
local XIAOHE = {
    q = "iu", w = "ei", r = "uan", t = "ue", y = "un", u = "sh", i = "ch", o = "uo", p = "ie",
    s = "ong", d = "ai", f = "en", g = "eng", h = "ang", j = "an", k = "ing", l = "iang",
    z = "ou", x = "ia", c = "ao", v = "zh", b = "in", n = "iao", m = "ian",
}

-- mapKey(key: string) → 写进输入框的预编辑字符，同时也是词库码；非本方法按键返回 nil。
local function letterKey(key)
    if not key:match("^%a$") then return nil end
    return key:lower()
end

local function mappedKey(map, key)
    return map[#key == 1 and key:lower() or key]
end

-- 速成 = 仓颉首尾码：两键查仓颉码 GLOB `首*尾`（含恰好两码的字）；单键同仓颉；没有三键以上的码。
local function quickLookup(dictionary, code)
    if #code == 1 then return dictionary:lookup(code) end
    if #code > 2 then return {} end
    return dictionary:glob(code:sub(1, 1) .. "*" .. code:sub(2, 2))
end

local METHODS = {
    pinyin = {
        id = "pinyin",
        dictionary = "pinyin",
        label = _("拼音"),
        mapKey = letterKey,
    },
    t9 = {
        id = "t9",
        dictionary = "pinyin",
        label = _("九宫格拼音"),
        mapKey = function(key) return require("features.ime.t9").mapKey(key) end,
        query = function(dictionary, code) return require("features.ime.t9").lookup(dictionary, code) end,
        rows = function(base) return require("features.ime.t9").rows(base) end,
    },
    xiaohe = {
        id = "xiaohe",
        dictionary = "pinyin",
        label = _("小鹤双拼"),
        labels = XIAOHE,
        show_codes = true,
        optional_labels = true,
        mapKey = letterKey,
        toCode = function(code) return require("features.ime.xiaohe").toPinyin(code) end,
    },
    wubi = {
        id = "wubi",
        dictionary = "wubi",
        label = _("五笔"),
        labels = WUBI,
        show_codes = true,
        optional_labels = true,
        mapKey = letterKey,
    },
    cangjie = {
        id = "cangjie",
        dictionary = "cangjie",
        label = _("仓颉"),
        labels = CANGJIE,
        show_codes = true,
        optional_labels = true,
        mapKey = letterKey,
    },
    quick = {
        id = "quick",
        dictionary = "cangjie",
        label = _("速成"),
        labels = CANGJIE,
        show_codes = true,
        optional_labels = true,
        mapKey = letterKey,
        query = quickLookup,
    },
    zhuyin = {
        id = "zhuyin",
        dictionary = "zhuyin",
        label = _("注音"),
        labels = ZHUYIN,
        mapKey = function(key) return mappedKey(ZHUYIN, key) end,
    },
}

local ORDER = { "pinyin", "t9", "xiaohe", "wubi", "cangjie", "quick", "zhuyin" }

local M = {}

---@return table[]
function M.list()
    local out = {}
    for _idx, id in ipairs(ORDER) do out[#out + 1] = METHODS[id] end
    return out
end

---@param id string|nil
---@return table
function M.get(id)
    return METHODS[id] or METHODS.pinyin
end

---@return table
function M.current()
    return M.get(Settings.get("features.ime").ime_layout)
end

-- M.isAvailable/fileExists/lookup/entries/builtAt/reset(method, ...)：method 为 profile 或 id，
-- 转发到该方法所用词库（profile.dictionary）的 table_dictionary 实例。
-- 声明了 toCode 的方法（双拼）查词前先把键码翻译成词库码；声明了 query 的（九宫格、速成）自己决定怎么查。
for _idx, name in ipairs({ "isAvailable", "fileExists", "lookup", "entries", "builtAt", "reset" }) do
    M[name] = function(method, ...)
        local profile = M.get(type(method) == "table" and method.id or method)
        local dictionary = require("features.ime." .. profile.dictionary .. ".dictionary")
        if name == "lookup" and profile.query then
            return profile.query(dictionary, (...))
        elseif name == "lookup" and profile.toCode then
            return dictionary:lookup(profile.toCode((...)))
        end
        return dictionary[name](dictionary, ...)
    end
end

return M
