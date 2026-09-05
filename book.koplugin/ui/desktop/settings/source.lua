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

--- 取某个源的 setting 模块。
--- 源不一定带设置模块，require 失败即视为没有，不作为错误。
---@param id string|nil 源标识
---@return table|nil
local function loadSourceSetting(id)
    local ok, mod = pcall(require, "source." .. tostring(id) .. ".setting")
    if ok and type(mod) == "table" then return mod end
    return nil
end

--- 弹出已启用源列表，选中后切换当前源并通知插件。
--- 选回当前源视为无操作，避免白重建一次桌面。
---@param desktop table 桌面实例
---@param plugin table|nil 插件实例，用于回调 onSourceChanged
---@param active_id string|nil 当前源标识，用于打勾与去重
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

--- 弹出已启用数据源列表并切换当前源。
---@param desktop table
---@param plugin table|nil
function Source.pickActive(desktop, plugin)
    pickSource(desktop, plugin, MoonSettings.activeSourceId())
end

--- 弹出全部源的多选列表，勾选即时生效，关闭时重建桌面。
--- 当前源那一项不可取消勾选，否则会没有可用源。
---@param desktop table 桌面实例
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
                callback = function() Source.pickActive(desktop, plugin) end,
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

    for _idx, meta in ipairs(enabled) do
        if meta.id ~= "local" then
            local mod = loadSourceSetting(meta.id)
            if mod and (type(mod.rows) == "function" or type(mod.open) == "function") then
                local status, status_on
                if type(mod.rowStatus) == "function" then status, status_on = mod.rowStatus() end
                local title = (mod.rowTitle and mod.rowTitle()) or _("源设置")
                local icon = (mod.rowIcon and mod.rowIcon()) or "dns"
                local rows = type(mod.rows) == "function" and mod.rows(plugin) or { function(iw)
                    return SettingRow.build(iw, {
                        kind = "nav", icon = icon, title = title,
                        status = status, status_on = status_on,
                        callback = function() mod.open(plugin) end,
                    })
                end }
                sections[#sections + 1] = {
                    title = meta.name or meta.id,
                    rows = rows,
                }
            end
        end
    end

    local local_setting = loadSourceSetting("local")
    if local_setting and (type(local_setting.rows) == "function" or type(local_setting.open) == "function") then
        local status, status_on = local_setting.rowStatus()
        local rows = type(local_setting.rows) == "function" and local_setting.rows(plugin) or { function(iw)
            return SettingRow.build(iw, {
                kind = "nav", icon = "folder", title = _("本地目录"),
                status = status, status_on = status_on,
                callback = function() local_setting.open(plugin) end,
            })
        end }
        sections[#sections + 1] = {
            title = _("本地"),
            rows = rows,
        }
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
    if #extra_rows > 0 then
        sections[#sections + 1] = { title = _("书城"), rows = extra_rows }
    end
    return sections
end

return Source
