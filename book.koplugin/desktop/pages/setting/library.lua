--[[-- 图书馆封面网格显示设置项（settings/ui.lua 的 library_*）。
@module koplugin.book.desktop.pages.setting.library
--]]

local Row = require("ui.themes.widgets.row")
local MoonSettings = require("utils.settings")
local _ = require("gettext")

---@class BookSettingsLibrary
local Library = {}

local STYLES = {
    { value = "kindle", text = _("Kindle") },
    { value = "kobo", text = _("Kobo") },
}
local TAPS = {
    { value = "open", text = _("打开书籍") },
    { value = "detail", text = _("进入详情") },
}

---@param items table[]
---@param value string
---@return string
local function label(items, value)
    for _idx, item in ipairs(items) do
        if item.value == value then return item.text end
    end
    return items[1].text
end

---@param desktop table
---@param key string settings/ui.lua 里的键
---@param icon string
---@param title string
---@param subtitle string
---@return fun(iw: number): table
local function toggleRow(desktop, key, icon, title, subtitle)
    return function(iw)
        local conf = MoonSettings.get("ui")
        return Row.widget({
            width = iw, icon = icon, title = title, subtitle = subtitle,
            toggle = conf[key],
            callback = function()
                conf[key] = not conf[key]
                MoonSettings.save("ui", conf)
                desktop:updateView()
            end,
        })
    end
end

---@param desktop table
---@param key string
---@param icon string
---@param title string
---@param subtitle string
---@param items table[] { value, text }
---@return fun(iw: number): table
local function choiceRow(desktop, key, icon, title, subtitle, items)
    return function(iw)
        local conf = MoonSettings.get("ui")
        return Row.widget({
            width = iw, kind = "nav", icon = icon, title = title, subtitle = subtitle,
            status = label(items, conf[key]), status_on = true,
            callback = function()
                require("ui.themes.widgets.list"):new{
                    title = title,
                    items = items,
                    current = conf[key],
                    centered = true,
                    on_select = function(value)
                        conf[key] = value
                        MoonSettings.save("ui", conf)
                        desktop:updateView()
                    end,
                }:show()
            end,
        })
    end
end

---@param desktop table
---@return table
function Library:rows(desktop)
    return {
        choiceRow(desktop, "library_style", "style", _("封面风格"),
            _("Kindle：状态叠在封面上；Kobo：封面干净，下载状态、进度和更多收在封面下方"), STYLES),
        toggleRow(desktop, "library_title", "title", _("显示名称"), _("封面下方显示书名")),
        toggleRow(desktop, "library_author", "person", _("显示作者"), _("书名下方显示作者")),
        choiceRow(desktop, "library_tap", "touch_app", _("点击书籍"), _("点封面时的动作"), TAPS),
    }
end

return Library
