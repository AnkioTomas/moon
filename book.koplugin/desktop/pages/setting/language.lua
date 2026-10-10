--[[-- 界面语言设置项。输入法在 features/ime。
@module koplugin.book.desktop.pages.setting.language
--]]

local List = require("ui.themes.widgets.list")
local Row = require("ui.themes.widgets.row")
local _ = require("gettext")

---@class BookSettingsLanguage
local Language = {}

--- 弹出界面语言选择列表。
--- 选项与回调都直接取自 KOReader 原生语言菜单，切换行为完全交给它。
local function pickLanguage()
    local source = require("ui/language"):getLangMenuTable()
    local items = {}
    for _idx, item in ipairs(source.sub_item_table or {}) do
        items[#items + 1] = {
            text = item.text,
            checked = item.checked_func and item.checked_func(),
            callback = item.callback,
        }
    end
    List:new{ title = _("语言"), items = items }:show()
end

---@param desktop BookDesktop
---@return BookQuickPanelSettingSection[]
function Language:sections(desktop)
    local lang = G_reader_settings:readSetting("language") or "C"
    local LanguageApi = require("ui/language")
    return {
        {
            title = _("语言"),
            rows = {
                function(iw)
                    return Row.widget({
                        width = iw,
                        kind = "nav",
                        icon = "language",
                        title = _("语言"),
                        status = LanguageApi:getLanguageName(lang),
                        status_on = true,
                        callback = pickLanguage,
                    })
                end,
            },
        },
    }
end

return Language
