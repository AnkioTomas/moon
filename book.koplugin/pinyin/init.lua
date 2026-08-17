--[[--
中文键盘入口（拼音候选由 KOReader 原生 zh_CN 键盘的内置 IME 提供）。

开关只存 Book 通用设置（沿用旧键 pinyin_enabled，兼容已有配置）。
开启 = 把 zh_CN（以及 en，用于一键切回）补进 KOReader 键盘布局列表，
用户点键盘上的 🌐 键在中英之间循环切换；候选词弹窗是原生 IME 的事，
本插件不做任何键盘 hook。

@module koplugin.book.pinyin
--]]

local Settings = require("utils.settings")
require("l10n").apply()

local Pinyin = {}

--- 当前是否启用中文键盘入口。
---@return boolean
function Pinyin.isEnabled()
    return Settings.get().pinyin_enabled == true
end

--- 把 en / zh_CN 补进 KOReader 键盘布局列表（保留用户已有布局与顺序）。
---@return nil
local function ensureLayouts()
    local layouts = G_reader_settings:readSetting("keyboard_layouts", {})
    local have = {}
    for _, l in ipairs(layouts) do
        have[l] = true
    end
    if not have.en then
        table.insert(layouts, "en")
    end
    if not have.zh_CN then
        table.insert(layouts, "zh_CN")
    end
    G_reader_settings:saveSetting("keyboard_layouts", layouts)
end

--- 写入开关；开启时补键盘布局（关闭不动布局列表——可能还有别人在用）。
---@param value boolean
---@return boolean
function Pinyin.setEnabled(value)
    local settings = Settings.get()
    settings.pinyin_enabled = value == true
    Settings.save(settings)
    if settings.pinyin_enabled then
        ensureLayouts()
    end
    return settings.pinyin_enabled
end

return Pinyin
