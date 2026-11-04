--[[--
快捷面板的原生插件入口：保存稳定菜单 id 与用户图标，执行时重新取当前 UI 上的插件实例。

@module koplugin.book.features.panel.plugin_actions
--]]

require("l10n").apply()

local Settings = require("utils.settings")
local Menu = require("ui.plugin_menu")
local _ = require("gettext")

local Actions = {}

---@param ctx BookQuickPanelContext|nil
---@return BookPlugin|nil
local function plugin(ctx)
    local ui = ctx and ctx.ui or require("apps/reader/readerui").instance
        or require("apps/filemanager/filemanager").instance
    return ui and not ui.tearing_down and ui.book or nil
end

---@param owner BookPlugin|nil
---@param id string
---@return BookExtensionEntry|nil
local function find(owner, id)
    if not owner then return end
    for _idx, entry in ipairs(Menu.entries(owner)) do
        if entry.id == id then return entry end
    end
end

---@param id string
---@return BookQuickPanelAction|nil
function Actions.get(id)
    local saved = Settings.get("features.panel").quick_panel_plugins or {}
    local pin = saved[id]
    if not pin then return end
    return {
        id = id, title = pin.text, icon = pin.icon, scope = pin.scope,
        available = function(ctx)
            local entry = find(plugin(ctx), pin.entry)
            return entry ~= nil and entry.item.enabled ~= false
                and (not entry.item.enabled_func or entry.item.enabled_func()) == true
        end,
        run = function(ctx)
            local owner = plugin(ctx)
            if not owner or not Menu.run(owner, pin.entry) then
                require("ui.themes.widgets.toast"):new{ text = _("插件入口当前不可用") }:show()
            end
        end,
    }
end

---@param scope "desktop"|"reader"
---@return string[]
function Actions.order(scope)
    local out = {}
    for id, pin in pairs(Settings.get("features.panel").quick_panel_plugins or {}) do
        if pin.scope == scope then out[#out + 1] = id end
    end
    table.sort(out)
    return out
end

--- 选入口后再选图标；取消任一步都不改配置。
---@param scope "desktop"|"reader"
---@param ctx BookQuickPanelContext|nil
---@param on_add fun(id: string)
function Actions.choose(scope, ctx, on_add)
    local owner = plugin(ctx)
    local items = {}
    if owner then
        for _idx, entry in ipairs(Menu.entries(owner)) do
            items[#items + 1] = {
                text = entry.text, value = entry,
                enabled = entry.item.enabled ~= false and (not entry.item.enabled_func or entry.item.enabled_func()),
            }
        end
    end
    if #items == 0 then items[1] = { text = _("没有可添加的插件入口"), enabled = false } end
    require("ui.themes.widgets.list"):new{
        title = _("添加插件入口"), centered = true, items = items,
        on_select = function(entry)
            local id = "plugin:" .. scope .. ":" .. entry.id
            local saved = Settings.get("features.panel").quick_panel_plugins or {}
            require("ui.themes.widgets.icon_picker"):new{
                title = entry.text, current = saved[id] and saved[id].icon or "extension",
                on_select = function(icon)
                    local settings = Settings.get("features.panel")
                    settings.quick_panel_plugins = settings.quick_panel_plugins or {}
                    settings.quick_panel_plugins[id] = {
                        entry = entry.id, text = entry.text, icon = icon, scope = scope,
                    }
                    Settings.save("features.panel")
                    on_add(id)
                end,
            }:show()
        end,
    }:show()
end

---@param id string
---@param on_change fun()
function Actions.chooseIcon(id, on_change)
    local pin = Settings.get("features.panel").quick_panel_plugins[id]
    require("ui.themes.widgets.icon_picker"):new{
        title = pin.text, current = pin.icon,
        on_select = function(icon)
            pin.icon = icon
            Settings.save("features.panel")
            on_change()
        end,
    }:show()
end

return Actions
