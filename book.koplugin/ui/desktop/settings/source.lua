--[[-- 数据源设置项。
@module koplugin.book.ui.desktop.settings.source
--]]

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Popup = require("ui.components.popup")
local SettingRow = require("ui.components.settingrow")
local MoonSettings = require("utils.settings")
local SourceRegistry = require("source.registry")
local _ = require("gettext")
local T = require("ffi/util").template

local Source = {}

local function loadSourceSetting(id)
    local ok, mod = pcall(require, "source." .. tostring(id) .. ".setting")
    if ok and type(mod) == "table" then return mod end
    return nil
end

local function pickSource(desktop, plugin, active_id)
    local sources = SourceRegistry.listEnabled()
    if #sources == 0 then return end
    local items = {}
    for _idx, meta in ipairs(sources) do
        local id = meta.id
        local name = meta.name or meta.id
        items[#items + 1] = { text = id == active_id and "✓ " .. name or name, value = id }
    end
    Popup.sheet{
        title = _("选择数据源"),
        items = items,
        on_select = function(id)
            if not id or id == active_id then return end
            SourceRegistry.setActive(id)
            if plugin and plugin.onSourceChanged then plugin:onSourceChanged() end
            local name = id
            for _idx, meta in ipairs(sources) do
                if meta.id == id then name = meta.name or meta.id break end
            end
            UIManager:show(InfoMessage:new{
                text = T(_("已切换数据源：%1"), name), timeout = 2,
            })
            desktop:rebuild()
        end,
    }
end

local function pickEnabledSources(desktop)
    local active_id = MoonSettings.activeSourceId()
    local items = {}
    for _idx, meta in ipairs(SourceRegistry.list()) do
        items[#items + 1] = {
            text = meta.name or meta.id,
            value = meta.id,
            checked = SourceRegistry.isEnabled(meta.id),
            enabled = meta.id ~= active_id,
        }
    end
    Popup.list{
        title = _("启用源"), select_mode = "multi", items = items,
        on_toggle = function(id, on) SourceRegistry.setEnabled(id, on) end,
        close_callback = function() desktop:rebuild() end,
    }
end

--- 构建数据源子页分组。
---@param ctx table
---@return table
function Source.sections(ctx)
    local desktop, plugin = ctx.desktop, ctx.plugin
    local active_id, active_name = ctx.active_id, ctx.active_name
    local source = plugin and plugin.getSource and plugin:getSource() or nil
    local enabled = SourceRegistry.listEnabled()
    local common_rows = {
        function(iw)
            return SettingRow.build(iw, {
                kind = "nav", icon = "source", title = _("当前数据源"),
                status = active_name, status_on = true,
                callback = function() pickSource(desktop, plugin, active_id) end,
            })
        end,
        function(iw)
            return SettingRow.build(iw, {
                kind = "nav", icon = "checklist", title = _("已启用的数据源"),
                status = T(_("已启用 %1/%2"), #enabled, #SourceRegistry.list()),
                status_on = true,
                callback = function() pickEnabledSources(desktop) end,
            })
        end,
    }
    local sections = { { title = _("数据源"), rows = common_rows } }

    local local_setting = loadSourceSetting("local")
    if local_setting and type(local_setting.open) == "function" then
        local status, status_on = local_setting.rowStatus()
        sections[#sections + 1] = {
            title = _("本地"),
            rows = { function(iw)
                return SettingRow.build(iw, {
                    kind = "nav", icon = "folder", title = _("本地目录"),
                    status = status, status_on = status_on,
                    callback = function() local_setting.open(plugin) end,
                })
            end },
        }
    end

    for _idx, meta in ipairs(enabled) do
        if meta.id ~= "local" then
            local mod = loadSourceSetting(meta.id)
            if mod and type(mod.open) == "function" then
                local status, status_on
                if type(mod.rowStatus) == "function" then status, status_on = mod.rowStatus() end
                local title = (mod.rowTitle and mod.rowTitle()) or _("源设置")
                local icon = (mod.rowIcon and mod.rowIcon()) or "dns"
                sections[#sections + 1] = {
                    title = meta.name or meta.id,
                    rows = { function(iw)
                        return SettingRow.build(iw, {
                            kind = "nav", icon = icon, title = title,
                            status = status, status_on = status_on,
                            callback = function() mod.open(plugin) end,
                        })
                    end },
                }
            end
        end
    end

    local extra_rows = {}
    if type(source and source.importBookAsync) == "function" then
        local store_setting = require("zlib.setting")
        local status, status_on = store_setting.rowStatus()
        extra_rows[#extra_rows + 1] = function(iw)
            return SettingRow.build(iw, {
                kind = "nav", icon = "storefront", title = _("Z-Library 账号"),
                status = status, status_on = status_on,
                callback = function() store_setting.open(plugin) end,
            })
        end
    end
    if source then
        extra_rows[#extra_rows + 1] = function(iw)
            return SettingRow.build(iw, {
                kind = "action", icon = "sync", title = _("立即同步"),
                callback = function()
                    UIManager:show(InfoMessage:new{ text = _("正在同步…"), timeout = 2 })
                    require("book.sync").runAsync(source, nil, function(result, err)
                        if desktop._closed then return end
                        if result then
                            desktop._home_state = nil
                            desktop._home_loaded = false
                            desktop._library_state = nil
                            desktop._insight_state = nil
                            desktop._insight_loaded = false
                            desktop:rebuild()
                        end
                        UIManager:show(InfoMessage:new{
                            text = result and _("同步完成") or (err and tostring(err) or _("同步失败")),
                            timeout = 2,
                        })
                    end)
                end,
            })
        end
    end
    if #extra_rows > 0 then
        sections[#sections + 1] = { title = _("同步与书城"), rows = extra_rows }
    end
    return sections
end

return Source
