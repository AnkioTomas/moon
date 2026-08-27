--[[--
划词弹窗显隐：不替换 KOReader 原生 ButtonDialog，仅按设置裁剪已有按钮。

在 onShowHighlightMenu 前给已知按钮挂上 show_in_highlight_dialog_func；
含 qrclipboard 的 12_generate_qr_code。

@module koplugin.book.ui.reader.highlight_menu
--]]

require("l10n").apply()

local MoonSettings = require("utils.settings")

local HighlightMenu = {}

--- ReaderHighlight._highlight_buttons 键 → 设置项 id
---@type table<string, string>
local INDEX_TO_KEY = {
    ["01_select"] = "select",
    ["02_highlight"] = "highlight",
    ["03_copy"] = "copy",
    ["04_add_note"] = "add_note",
    ["05_wikipedia"] = "wikipedia",
    ["06_dictionary"] = "dictionary",
    ["07_translate"] = "translate",
    ["09_view_html"] = "view_html",
    ["12_generate_qr_code"] = "qrcode",
    ["12_search"] = "search",
}

--- 划词弹窗某项是否应在菜单中显示。
---@param key string
---@return boolean
function HighlightMenu.isEnabled(key)
    local buttons = MoonSettings.get().reader_popup_buttons
    if type(buttons) ~= "table" then
        return true
    end
    return buttons[key] ~= false
end

---@param fn function
---@param key string
---@return function
local function wrapFactory(fn, key)
    return function(this, index)
        local button = fn(this, index)
        if not button then
            return button
        end
        local orig_show = button.show_in_highlight_dialog_func
        button.show_in_highlight_dialog_func = function()
            if not HighlightMenu.isEnabled(key) then
                return false
            end
            return not orig_show or orig_show()
        end
        return button
    end
end

--- 给当前 ReaderHighlight 实例挂上显隐门控（含晚注册的插件按钮）。
---@param highlight table|nil
---@return nil
function HighlightMenu.ensureWrapped(highlight)
    if not highlight or not highlight._highlight_buttons then
        return
    end
    highlight._book_popup_wrapped = highlight._book_popup_wrapped or {}
    for idx, factory in pairs(highlight._highlight_buttons) do
        if not highlight._book_popup_wrapped[idx] then
            local key = INDEX_TO_KEY[idx]
            if key then
                highlight._highlight_buttons[idx] = wrapFactory(factory, key)
            end
            highlight._book_popup_wrapped[idx] = true
        end
    end
end

local function patchShowMenu()
    local ok, ReaderHighlight = pcall(require, "apps/reader/modules/readerhighlight")
    if not ok or ReaderHighlight._book_popup_patched then
        return
    end
    ReaderHighlight._book_popup_patched = true
    local orig = ReaderHighlight.onShowHighlightMenu
    function ReaderHighlight:onShowHighlightMenu(index)
        HighlightMenu.ensureWrapped(self)
        return orig(self, index)
    end
end

--- 安装划词弹窗显隐门控；重复调用无副作用。
---@param ui table|nil
---@return nil
function HighlightMenu.install(ui)
    patchShowMenu()
    if not ui or not ui.highlight then
        return
    end
    HighlightMenu.ensureWrapped(ui.highlight)
    if ui.registerPostInitCallback then
        ui:registerPostInitCallback(function()
            HighlightMenu.ensureWrapped(ui.highlight)
        end)
    end
end

return HighlightMenu
