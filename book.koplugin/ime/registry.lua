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
        mapKey = letterKey,
    },
    cangjie = {
        id = "cangjie",
        label = _("仓颉"),
        commit_space = true,
        labels = CANGJIE,
        show_codes = true,
        mapKey = letterKey,
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
