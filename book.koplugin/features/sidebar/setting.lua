--[[--
阅读页侧栏设置：打开手势、底栏显示哪些页面。

@module koplugin.book.features.sidebar.setting
--]]

local T = require("ffi/util").template
local _ = require("gettext")

local GESTURES = {
    { value = "edge", text = _("左边缘右滑") },
    { value = "full", text = _("任意位置右滑") },
    { value = "off", text = _("关闭") },
}

---@param settings table
---@return string|nil
local function statusText(settings)
    local current = settings.sidebar_gesture
    for _idx, option in ipairs(GESTURES) do
        if option.value == current then return option.text end
    end
end

local Setting = {}

--- 侧栏页面，顺序即底栏顺序；note 说明按条件出现的页。
Setting.TABS = {
    { id = "info", text = _("书籍"), icon = "info" },
    { id = "toc", text = _("目录"), icon = "menu_book" },
    { id = "font", text = _("阅读字体"), icon = "text_fields", note = _("文档支持时显示") },
    { id = "notes", text = _("书摘"), icon = "format_ink_highlighter" },
    { id = "xray", text = _("X-Ray"), icon = "person_search", note = _("开启 X-Ray 后显示") },
    { id = "ticket", text = _("阅读票根"), icon = "confirmation_number" },
    { id = "stats", text = _("统计"), icon = "insights", note = _("订阅文章不显示") },
}

-- sidebar_gesture 取 GESTURES 的 value；sidebar_hidden_tabs 记隐藏的页 id（新加的页缺省显示）；
-- sidebar_tab_order 记用户排的页 id 顺序（空 = 按 TABS，TABS 里新加的页追加在末尾）。
Setting.defaults = { sidebar_gesture = "edge", sidebar_hidden_tabs = {}, sidebar_tab_order = {} }

--- 按用户顺序排好的页定义（含隐藏页）。
---@param settings table
---@return table[]
function Setting.orderedTabs(settings)
    local by_id, ordered = {}, {}
    for _idx, tab in ipairs(Setting.TABS) do by_id[tab.id] = tab end
    for _idx, id in ipairs(settings.sidebar_tab_order) do
        if by_id[id] then
            ordered[#ordered + 1] = by_id[id]
            by_id[id] = nil
        end
    end
    for _idx, tab in ipairs(Setting.TABS) do
        if by_id[tab.id] then ordered[#ordered + 1] = tab end
    end
    return ordered
end

---@param settings table
---@return table<string, boolean>
function Setting.hiddenTabs(settings)
    local hidden = {}
    for _idx, id in ipairs(settings.sidebar_hidden_tabs) do hidden[id] = true end
    return hidden
end

---@param settings table
---@return string
local function tabsStatus(settings)
    local hidden = Setting.hiddenTabs(settings)
    local shown = 0
    for _idx, tab in ipairs(Setting.TABS) do
        if not hidden[tab.id] then shown = shown + 1 end
    end
    return T(_("%1 / %2"), shown, #Setting.TABS)
end

--- 勾选侧栏页面；每次勾选即落盘，最后一页不让取消。
---@param settings table
---@param desktop BookDesktop
local function pickTabs(settings, desktop)
    local MoonSettings = require("utils.settings")
    local hidden = Setting.hiddenTabs(settings)
    local items = {}
    for index, tab in ipairs(Setting.orderedTabs(settings)) do
        items[index] = { text = tab.text, value = tab.id, mandatory = tab.note, checked = not hidden[tab.id] }
    end
    require("ui.themes.widgets.list"):new{
        title = _("侧栏页面"),
        multi = true,
        items = items,
        on_toggle = function(_id, _checked, item)
            local ids = {}
            for _idx, it in ipairs(items) do
                if not it.checked then ids[#ids + 1] = it.value end
            end
            if #ids == #items then
                item.checked = true
                require("ui.themes.widgets.toast"):new{ text = _("至少保留一个页面") }:show()
                return
            end
            settings.sidebar_hidden_tabs = ids
            MoonSettings.save("features.sidebar", settings)
        end,
        close_callback = function() desktop:updateView() end,
    }:show()
end

--- 调整页面顺序：每行右侧上移 / 下移按钮，点一下即落盘并就地刷新（翻页由列表负责）。
---@param settings table
---@param desktop BookDesktop
local function pickOrder(settings, desktop)
    local MoonSettings = require("utils.settings")
    local Button = require("ui.themes.widgets.button")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local Theme = require("ui.themes")
    local tabs = Setting.orderedTabs(settings)
    local list
    local items
    local function move(index, delta)
        tabs[index], tabs[index + delta] = tabs[index + delta], tabs[index]
        local ids = {}
        for _idx, tab in ipairs(tabs) do ids[#ids + 1] = tab.id end
        settings.sidebar_tab_order = ids
        MoonSettings.save("features.sidebar", settings)
        list:setItems(items())
    end
    local function arrow(icon, index, delta)
        local size = Theme.px(36)
        return Button:new{
            icon = icon, variant = "ghost", width = size, height = size,
            enabled = index + delta >= 1 and index + delta <= #tabs,
            callback = function() move(index, delta) end,
        }
    end
    items = function()
        local result = {}
        for index, tab in ipairs(tabs) do
            result[index] = {
                text = tab.text,
                icon = tab.icon,
                keep_open = true,
                callback = function() end,
                widget = function()
                    return HorizontalGroup:new{
                        align = "center",
                        arrow("arrow_upward", index, -1),
                        HorizontalSpan:new{ width = Theme.px(4) },
                        arrow("arrow_downward", index, 1),
                    }
                end,
            }
        end
        return result
    end
    list = require("ui.themes.widgets.list"):new{
        title = _("页面顺序"),
        items = items(),
        close_callback = function() desktop:updateView() end,
    }
    list:show()
end

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    local MoonSettings = require("utils.settings")
    local Row = require("ui.themes.widgets.row")
    return {
        {
            group = "reader",
            order = 12,
            icon = "side_navigation",
            title = _("阅读侧栏"),
            subtitle = _("呼出手势与页面"),
            page = {
                title = _("阅读侧栏"),
                sections = function()
                    local settings = MoonSettings.get("features.sidebar")
                    local current = settings.sidebar_gesture
                    return {
                        {
                            title = _("阅读侧栏"),
                            rows = {
                                function(iw)
                                    return Row.widget({
                                        width = iw,
                                        chevron = true,
                                        kind = "nav",
                                        icon = "swipe_right",
                                        title = _("侧栏手势"),
                                        subtitle = _("也可在 KOReader 手势管理中绑定「打开月读侧栏」"),
                                        status = statusText(settings),
                                        callback = function()
                                            require("ui.themes.widgets.list"):new{
                                                title = _("侧栏手势"),
                                                items = GESTURES,
                                                current = current,
                                                centered = true,
                                                on_select = function(value)
                                                    settings.sidebar_gesture = value
                                                    MoonSettings.save("features.sidebar", settings)
                                                    desktop:updateView()
                                                end,
                                            }:show()
                                        end,
                                    })
                                end,
                                function(iw)
                                    return Row.widget({
                                        width = iw,
                                        chevron = true,
                                        kind = "nav",
                                        icon = "view_sidebar",
                                        title = _("侧栏页面"),
                                        subtitle = _("选择侧栏底部显示哪些页面"),
                                        status = tabsStatus(settings),
                                        callback = function() pickTabs(settings, desktop) end,
                                    })
                                end,
                                function(iw)
                                    return Row.widget({
                                        width = iw,
                                        chevron = true,
                                        kind = "nav",
                                        icon = "swap_vert",
                                        title = _("页面顺序"),
                                        subtitle = _("调整侧栏底部页面的排列顺序"),
                                        callback = function() pickOrder(settings, desktop) end,
                                    })
                                end,
                            },
                        },
                    }
                end,
            },
        },
    }
end

return Setting
