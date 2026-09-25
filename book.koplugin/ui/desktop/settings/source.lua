--[[-- 数据源设置项。
@module koplugin.book.ui.desktop.settings.source
--]]

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Popup = require("ui.views.popup")
local SettingRow = require("ui.components.settingrow")
local MoonSettings = require("utils.settings")
local SourceRegistry = require("source.registry")
local _ = require("gettext")
local T = require("ffi/util").template

--- 选择器哨兵：与真实源 id 并列，表示开启混合展示。
local MIXED = "__mixed__"

---@class BookSettingsSource
local Source = {}
--- 当前数据源状态文案：混合开启时显示「混合模式」，否则为活跃源名。
---@param active_name string|nil
---@return string
function Source.displayName(active_name)
    if MoonSettings.libraryMixed() then return _("混合模式") end
    return active_name or MoonSettings.activeSourceId() or _("未知源")
end

--- 取某个源的 setting 模块。
--- 源不一定带设置模块，require 失败即视为没有，不作为错误。
---@param id string|nil 源标识
---@return table|nil
local function loadSourceSetting(id)
    local ok, mod = pcall(require, "source." .. tostring(id) .. ".setting")
    if ok and type(mod) == "table" then return mod end
    return nil
end

--- 换展示范围后通知桌面重拉；混合开关与换源共用。
---@param desktop table
---@param plugin table|nil
local function notifyScopeChanged(desktop, plugin)
    if plugin and plugin.onSourceChanged then
        plugin:onSourceChanged()
    elseif desktop and desktop.onEvent then
        desktop:onEvent("source_changed", desktop.source)
    end
    desktop:updateView()
end

--- 弹出：混合模式（置顶）+ 已启用源。选混合只改 library_mixed；选源则关混合并切活跃源。
---@param desktop table 桌面实例
---@param plugin table|nil 插件实例，用于回调 onSourceChanged
---@param active_id string|nil 当前源标识，用于打勾与去重
local function pickSource(desktop, plugin, active_id)
    local sources = SourceRegistry.listEnabled()
    if #sources == 0 then return end
    local mixed = MoonSettings.libraryMixed()
    local items = {
        { text = mixed and ("✓ " .. _("混合模式")) or _("混合模式"), value = MIXED },
    }
    for _idx, meta in ipairs(sources) do
        local id = meta.id
        local name = meta.name or meta.id
        local checked = not mixed and id == active_id
        items[#items + 1] = { text = checked and ("✓ " .. name) or name, value = id }
    end
    Popup.sheet{
        title = _("选择数据源"),
        items = items,
        on_select = function(id)
            if id == MIXED then
                if mixed then return end
                MoonSettings.save({ library_mixed = true })
                UIManager:show(InfoMessage:new{
                    text = T(_("已切换数据源：%1"), _("混合模式")), timeout = 2,
                })
                notifyScopeChanged(desktop, plugin)
                return
            end
            if not id then return end
            if not mixed and id == active_id then return end
            if mixed then MoonSettings.save({ library_mixed = false }) end
            SourceRegistry.setActive(id)
            local name = id
            for _idx, meta in ipairs(sources) do
                if meta.id == id then name = meta.name or meta.id break end
            end
            UIManager:show(InfoMessage:new{
                text = T(_("已切换数据源：%1"), name), timeout = 2,
            })
            notifyScopeChanged(desktop, plugin)
        end,
    }
end

--- 弹出已启用数据源列表并切换当前源（含置顶的混合模式）。
---@param desktop table
---@param plugin table|nil
function Source:pickActive(desktop, plugin)
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
        close_callback = function() desktop:updateView() end,
    }
end

--- 书籍来源：当前源 + 启用哪些。
---@param ctx table
---@return table
function Source:scopeSections(ctx)
    local desktop, plugin = ctx.desktop, ctx.plugin
    local active_name = ctx.active_name
    local enabled = SourceRegistry.listEnabled()
    return {{
        title = _("书籍来源"),
        rows = {
            function(iw)
                return SettingRow.build(iw, {
                    kind = "nav", icon = "source", title = _("当前数据源"),
                    status = Source.displayName(active_name), status_on = true,
                    callback = function() Source.pickActive(desktop, plugin) end,
                })
            end,
            function(iw)
                return SettingRow.build(iw, {
                    kind = "nav", icon = "checklist", title = _("已启用的数据源"),
                    subtitle = _("决定书库中可以切换哪些书籍来源"),
                    status = T(_("已启用 %1/%2"), #enabled, #SourceRegistry.list()),
                    status_on = true,
                    callback = function() pickEnabledSources(desktop) end,
                })
            end,
        },
    }}
end

--- 来源配置：各源账号 / 本地目录 / Z-Lib。一页展开，不按源再钻一层。
---@param ctx table
---@return table
function Source:configSections(ctx)
    local desktop, plugin = ctx.desktop, ctx.plugin
    local sections = {}
    for _idx, meta in ipairs(SourceRegistry.listEnabled()) do
        if meta.id ~= "local" then
            local mod = loadSourceSetting(meta.id)
            if mod and (type(mod.rows) == "function" or type(mod.open) == "function") then
                local status, status_on
                if type(mod.rowStatus) == "function" then status, status_on = mod.rowStatus() end
                local title = (mod.rowTitle and mod.rowTitle()) or _("账号与登录")
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

    local extra_rows = {
        function(iw)
            local on = MoonSettings.zlibEnabled()
            return SettingRow.build(iw, {
                kind = "toggle", icon = "storefront", title = _("Z-Library"),
                subtitle = _("底栏显示 Z站；下载后导入本地书库"),
                status = on and _("开") or _("关"),
                status_on = on,
                callback = function()
                    MoonSettings.save({ zlib_enabled = not on })
                    notifyScopeChanged(desktop, plugin)
                end,
            })
        end,
    }
    if MoonSettings.zlibEnabled() then
        local store_setting = require("zlib.setting")
        local status, status_on = store_setting.rowStatus()
        extra_rows[#extra_rows + 1] = function(iw)
            return SettingRow.build(iw, {
                kind = "nav", icon = "vpn_key", title = _("Z-Library 账号"),
                status = status, status_on = status_on,
                callback = function() store_setting.open(plugin) end,
            })
        end
    end
    sections[#sections + 1] = { title = _("Z-Library"), rows = extra_rows }
    return sections
end

return Source
