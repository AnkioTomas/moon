--[[-- 界面语言设置项。输入法在 features/ime。
@module koplugin.book.desktop.pages.setting.language
--]]

local List = require("ui.themes.widgets.list")
local Row = require("ui.themes.widgets.row")
local _ = require("gettext")

--- 插件有翻译的语言（源字符串 + l10n/*.lua）；C 即 KOReader 的英文。
local LOCALES = { "zh_CN", "zh_TW", "C" }

---@class BookSettingsLanguage
local Language = {}

--- 弹出界面语言选择列表。条目取自 KOReader 原生语言菜单项，切换行为完全交给它。
local function pickLanguage()
    local LanguageApi = require("ui/language")
    local items = {}
    for _idx, locale in ipairs(LOCALES) do
        local item = LanguageApi:genLanguageSubItem(locale)
        items[#items + 1] = { text = item.text, checked = item.checked_func(), callback = item.callback }
    end
    List:new{ title = _("语言"), items = items }:show()
end

--- 造设置根页「语言」行：点击直接弹语言列表。
---@return fun(iw: number): table
function Language:row()
    return function(iw)
        local lang = G_reader_settings:readSetting("language") or "C"
        return Row.widget({
            width = iw,
            kind = "nav",
            icon = "language",
            title = _("语言"),
            subtitle = _("界面语言"),
            status = require("ui/language"):getLanguageName(lang),
            status_on = true,
            callback = pickLanguage,
        })
    end
end

return Language
