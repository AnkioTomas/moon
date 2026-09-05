--[[--
中文输入法注册表。

每个方法只声明按键映射、键帽和词库；候选状态机不按输入法堆分支。

@module koplugin.book.ime.registry
--]]

local Settings = require("utils.settings")
local _ = require("gettext")

local CANGJIE = {
    a = "日", b = "月", c = "金", d = "木", e = "水", f = "火", g = "土",
    h = "竹", i = "戈", j = "十", k = "大", l = "中", m = "一", n = "弓",
    o = "人", p = "心", q = "手", r = "口", s = "尸", t = "廿", u = "山",
    v = "女", w = "田", x = "難", y = "卜", z = "符",
}

local WUBI = {
    q = "金勹儿", w = "人亻八", e = "月彡乃", r = "白扌斤", t = "禾竹攵",
    y = "言讠方", u = "立辛门", i = "水氵小", o = "火灬米", p = "之宀辶",
    a = "工艹匚", s = "木丁西", d = "大犬石", f = "土士十", g = "王一五",
    h = "目止卜", j = "日刂虫", k = "口川", l = "田囗车",
    x = "纟幺弓", c = "又巴马", v = "女刀九", b = "子耳阝", n = "已尸心", m = "山贝冂",
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

local function letterKey(key)
    if type(key) ~= "string" or not key:match("^%a$") then return nil end
    key = key:lower()
    return key, key
end

local function mappedKey(map, key)
    if type(key) ~= "string" then return nil end
    local normalized = #key == 1 and key:lower() or key
    local symbol = map[normalized]
    if not symbol then return nil end
    return symbol, symbol
end

local function codedKey(labels, key)
    if type(key) ~= "string" or not key:match("^%a$") then return nil end
    local code = key:lower()
    return code, labels[code] or code
end

local METHODS = {
    pinyin = {
        id = "pinyin",
        label = _("拼音"),
        commit_space = true,
        mapKey = letterKey,
    },
    wubi = {
        id = "wubi",
        label = _("五笔"),
        commit_space = true,
        labels = WUBI,
        show_codes = true,
        mapKey = function(key) return codedKey(WUBI, key) end,
    },
    cangjie = {
        id = "cangjie",
        label = _("仓颉"),
        commit_space = true,
        labels = CANGJIE,
        show_codes = true,
        mapKey = function(key) return codedKey(CANGJIE, key) end,
    },
    zhuyin = {
        id = "zhuyin",
        label = _("注音"),
        commit_space = true,
        labels = ZHUYIN,
        mapKey = function(key) return mappedKey(ZHUYIN, key) end,
    },
}

local ORDER = { "pinyin", "wubi", "cangjie", "zhuyin" }

local M = {}

---@return table[]
function M.list()
    local out = {}
    for _, id in ipairs(ORDER) do out[#out + 1] = METHODS[id] end
    return out
end

---@param id string|nil
---@return table
function M.get(id)
    return METHODS[id] or METHODS.pinyin
end

---@return table
function M.current()
    return M.get(Settings.get().ime_layout)
end

---@param method table|string
---@return table
function M.dictionary(method)
    local id = type(method) == "table" and method.id or method
    return require("ime." .. M.get(id).id .. ".dictionary")
end

---@param method table|string
---@param name string
---@param ... any
---@return any
local function callDictionary(method, name, ...)
    local profile = type(method) == "table" and method or M.get(method)
    local dictionary = M.dictionary(profile)
    if profile.id == "pinyin" then
        return dictionary[name](...)
    end
    return dictionary[name](dictionary, ...)
end

function M.isAvailable(method)
    return callDictionary(method, "isAvailable")
end

function M.fileExists(method)
    return callDictionary(method, "fileExists")
end

function M.lookup(method, code)
    return callDictionary(method, "lookup", code)
end

function M.entries(method)
    return callDictionary(method, "entries")
end

function M.builtAt(method)
    return callDictionary(method, "builtAt")
end

function M.reset(method)
    return callDictionary(method, "reset")
end

return M
