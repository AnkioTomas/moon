--[[-- 首页布局设置。
@module koplugin.book.ui.desktop.settings.home
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local Popup = require("ui.components.popup")
local SettingRow = require("ui.components.settingrow")
local MoonSettings = require("utils.settings")
local Base = require("ui.desktop.home.components.base")
local _ = require("gettext")
local T = require("ffi/util").template

local HomeSettings = {}

--- 写回首页启用组件的有序列表。
---@param layout string[] 组件 id，顺序即首页显示顺序
local function saveLayout(layout)
    local home = MoonSettings.get("home")
    home.home_layout = layout
    MoonSettings.saveSection("home", home)
end

--- 判断组件是否在启用列表里。
---@param id string 组件 id
---@param layout string[] 启用列表
---@return boolean
local function isEnabled(id, layout)
    for i, item in ipairs(layout) do
        if item == id then return true end
    end
    return false
end

--- 组件在启用列表中的序号。
---@param id string 组件 id
---@param layout string[] 启用列表
---@return number|nil 未启用时为 nil
local function position(id, layout)
    for i, item in ipairs(layout) do
        if item == id then return i end
    end
    return nil
end

--- 启用/停用组件并立刻重建桌面。
--- 启用时追加到末尾。清掉 desktop 的首页缓存，否则组件已装卸但界面仍用旧数据。
---@param id string 组件 id
---@param desktop table 桌面实例
local function toggle(id, desktop)
    local layout = Base.enabledLayout()
    if isEnabled(id, layout) then
        local out = {}
        for i, item in ipairs(layout) do
            if item ~= id then out[#out + 1] = item end
        end
        saveLayout(out)
    else
        layout[#layout + 1] = id
        saveLayout(layout)
    end
    require("ui.desktop.home").invalidate(desktop)
    desktop:rebuild()
end

--- 在启用列表里挪动组件位置并重建桌面。
--- 越界或未启用时静默忽略。
---@param id string 组件 id
---@param delta number 位移量，-1 上移 / 1 下移
---@param desktop table 桌面实例
local function move(id, delta, desktop)
    local layout = Base.enabledLayout()
    local pos = position(id, layout)
    if not pos then return end
    local next_pos = pos + delta
    if next_pos < 1 or next_pos > #layout then return end
    local item = layout[pos]
    table.remove(layout, pos)
    table.insert(layout, next_pos, item)
    saveLayout(layout)
    desktop:rebuild()
end

--- 弹出单个组件的操作面板：启用/停用，已启用时另给上移下移。
---@param desktop table 桌面实例
---@param comp table 组件定义（id / label / icon）
local function configure(desktop, comp)
    local layout = Base.enabledLayout()
    local enabled = isEnabled(comp.id, layout)
    local pos = position(comp.id, layout)
    local dialog
    local buttons = {}
    buttons[#buttons + 1] = {{
        text = enabled and _("停用") or _("启用"),
        callback = function()
            UIManager:close(dialog)
            toggle(comp.id, desktop)
        end,
    }}
    if enabled then
        buttons[#buttons + 1] = {
            {
                text = _("上移"),
                enabled = pos and pos > 1,
                callback = function()
                    UIManager:close(dialog)
                    move(comp.id, -1, desktop)
                end,
            },
            {
                text = _("下移"),
                enabled = pos and pos < #layout,
                callback = function()
                    UIManager:close(dialog)
                    move(comp.id, 1, desktop)
                end,
            },
        }
    end
    buttons[#buttons + 1] = {{
        text = _("关闭"),
        callback = function() UIManager:close(dialog) end,
    }}
    dialog = ButtonDialog:new{
        title = comp.label,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--- 弹出已启用组件的排序列表，点按进入单组件操作面板。
--- 一个都没启用时不弹空列表。
---@param desktop table 桌面实例
local function openSortList(desktop)
    local layout = Base.enabledLayout()
    if #layout == 0 then return end
    local items = {}
    for i, id in ipairs(layout) do
        local comp = Base.find(id)
        if comp then
            items[#items + 1] = {
                text = comp.label,
                icon = comp.icon,
                mandatory = T(_("第 %1 位"), i),
                callback = function()
                    configure(desktop, comp)
                end,
            }
        end
    end
    Popup.list{
        title = _("组件排序"),
        subtitle = _("点按可上移或下移"),
        items = items,
    }
end

--- 造一个组件设置行的构造器（延迟到拿到内容宽度时才建 widget）。
---@param desktop table 桌面实例
---@param comp table 组件定义（id / label / icon）
---@param enabled boolean 当前是否启用
---@param pos number|nil 启用时的序号
---@return fun(iw: number): table
local function componentRow(desktop, comp, enabled, pos)
    return function(iw)
        local status
        if enabled then
            status = T(_("第 %1 位"), pos)
        else
            status = _("未启用")
        end
        return SettingRow.build(iw, {
            kind = "nav",
            icon = comp.icon or "widgets",
            title = comp.label,
            status = status,
            status_on = enabled,
            callback = function() configure(desktop, comp) end,
        })
    end
end

---@param desktop table
---@return table
function HomeSettings.sections(desktop)
    local home = MoonSettings.get("home")
    local mode = home.home_recent_list_mode or "hero_grid"
    local mode_label = mode == "list_only" and _("纯列表") or _("长条+列表")
    local layout = Base.enabledLayout()
    local enabled_set = {}
    for i, id in ipairs(layout) do
        enabled_set[id] = i
    end

    local layout_rows = {
        function(iw)
            return SettingRow.build(iw, {
                kind = "nav",
                icon = "sort",
                title = _("组件排序"),
                status = T(_("%1 项"), #layout),
                status_on = #layout > 0,
                callback = function() openSortList(desktop) end,
            })
        end,
        function(iw)
            return SettingRow.build(iw, {
                kind = "nav",
                icon = "grid_view",
                title = _("最近阅读列表形态"),
                status = mode_label,
                status_on = true,
                callback = function()
                    Popup.list{
                        title = _("最近阅读列表形态"),
                        items = {
                            { text = _("长条+列表"), value = "hero_grid" },
                            { text = _("纯列表"), value = "list_only" },
                        },
                        current = mode,
                        on_select = function(value)
                            home.home_recent_list_mode = value
                            MoonSettings.saveSection("home", home)
                            desktop:rebuild()
                        end,
                    }
                end,
            })
        end,
    }

    local enabled_rows = {}
    for i, id in ipairs(layout) do
        local comp = Base.find(id)
        if comp then
            enabled_rows[#enabled_rows + 1] = componentRow(desktop, comp, true, i)
        end
    end

    local disabled_rows = {}
    for i, comp in ipairs(Base.components) do
        if not enabled_set[comp.id] then
            disabled_rows[#disabled_rows + 1] = componentRow(desktop, comp, false, nil)
        end
    end

    local sections = {
        { title = _("布局"), rows = layout_rows },
    }
    if #enabled_rows > 0 then
        sections[#sections + 1] = { title = _("已启用"), rows = enabled_rows }
    end
    if #disabled_rows > 0 then
        sections[#sections + 1] = { title = _("未启用"), rows = disabled_rows }
    end
    return sections
end

return HomeSettings
