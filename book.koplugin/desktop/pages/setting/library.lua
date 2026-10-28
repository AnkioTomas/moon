--[[-- 书架显示设置项（每行数量 + settings/ui.lua 的 library_*）。
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
local RANDOM_SCOPES = {
    { value = "new", text = _("未读") },
    { value = "reading", text = _("未读 + 阅读中") },
}
local TAPS = {
    { value = "open", text = _("打开书籍") },
    { value = "detail", text = _("进入详情") },
}

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
        return Row.choice({
            width = iw, icon = icon, title = title, subtitle = subtitle,
            items = items, current = conf[key],
            on_select = function(value)
                conf[key] = value
                MoonSettings.save("ui", conf)
                desktop:updateView()
            end,
        })
    end
end

--- 书库显示哪些分组页签：多选弹窗，勾选即存，书籍页签恒显示。
---@param desktop table
---@return fun(iw: number): table
local function tabsRow(desktop)
    return function(iw)
        local conf = MoonSettings.get("ui")
        return Row.widget({
            width = iw, kind = "nav", icon = "tab", title = _("书库页签"),
            subtitle = _("选择书库顶部显示哪些分组；文件夹页签仅本地书库有"),
            status = tostring(#conf.library_tabs), status_on = true,
            callback = function()
                local chosen, items = {}, {}
                for _idx, id in ipairs(conf.library_tabs) do chosen[id] = true end
                for _idx, tab in ipairs(require("desktop.pages.library").tabOptions()) do
                    items[#items + 1] = { text = tab.text, value = tab.id,
                        checked = tab.id == "books" or chosen[tab.id] == true, enabled = tab.id ~= "books" }
                end
                require("ui.themes.widgets.list"):new{
                    title = _("书库页签"), multi = true, items = items, centered = true,
                    close_callback = function()
                        local ids = {}
                        for _idx, item in ipairs(items) do
                            if item.checked then ids[#ids + 1] = item.value end
                        end
                        conf.library_tabs = ids
                        MoonSettings.save("ui", conf)
                        desktop:updateView()
                    end,
                }:show()
            end,
        })
    end
end

---@param desktop table
---@return BookThemeSection[]
function Library:sections(desktop)
    local function gridRow(iw)
        local CoverCell = require("ui.widgets.cover")
        return Row.widget({
            width = iw, kind = "nav", icon = "grid_view", title = _("书架每行数量"),
            subtitle = _("调整书库和 Z站 每行显示的卡片数"),
            status = tostring(CoverCell.gridCols()), status_on = true,
            callback = function()
                require("ui.themes.widgets.spin"):new{
                    title = _("书架每行数量"),
                    fields = { { value = CoverCell.gridCols(), min = CoverCell.gridColsMin(),
                        max = CoverCell.gridColsMax() } },
                    callback = function(v)
                        CoverCell.setGridCols(v)
                        desktop:updateView()
                    end,
                }:show()
            end,
        })
    end
    return {
        { title = _("封面"), rows = {
            gridRow,
            choiceRow(desktop, "library_style", "style", _("封面风格"),
                _("Kindle：状态叠在封面上；Kobo：封面干净，下载状态、进度和更多收在封面下方"), STYLES),
            toggleRow(desktop, "library_title", "title", _("显示名称"), _("封面下方显示书名")),
            toggleRow(desktop, "library_author", "person", _("显示作者"), _("书名下方显示作者")),
        } },
        { title = _("书库"), rows = {
            tabsRow(desktop),
            choiceRow(desktop, "library_tap", "touch_app", _("点击书籍"), _("点封面时的动作"), TAPS),
        } },
        { title = _("随机一本"), rows = {
            toggleRow(desktop, "library_random", "casino", _("显示随机一本"),
                _("书库工具栏显示骰子，优先从未读的书里随机抽一本")),
            choiceRow(desktop, "random_scope", "casino", _("随机范围"),
                _("书库与首页的随机一本从哪些书里抽，已读完的不会抽到"), RANDOM_SCOPES),
        } },
    }
end

return Library
