--[[-- 数据源设置项。
@module koplugin.book.desktop.pages.setting.source
--]]

local List = require("ui.themes.widgets.list")
local Toast = require("ui.themes.widgets.toast")
local Row = require("ui.themes.widgets.row")
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
    if MoonSettings.get("source").library_mixed then return _("混合模式") end
    return active_name or SourceRegistry.activeId() or _("未知源")
end

--- 取某个源的 setting 模块；源不一定带。第三方源的设置模块挂在描述表的 setting 字段上。
--- 只按「找不到文件」判断没有：模块自身抛错必须冒出来，不能被当成没有设置页。
---@param id string 源标识
---@return table|nil
function Source.loadSetting(id)
    local ext = SourceRegistry.external(id)
    if ext then return ext.setting end
    local name = "source." .. id .. ".setting"
    if package.loaded[name] or package.preload[name] or package.searchpath(name, package.path) then
        return require(name)
    end
end

--- 弹出：混合模式（置顶）+ 已启用源。选混合只改 library_mixed；选源则关混合并切活跃源。
--- 重绘由桌面处理 SourceChanged 时的 switchTab 负责，这里不 updateView。
---@param active_id string|nil 当前源标识，用于打勾与去重
local function pickSource(active_id)
    local sources = SourceRegistry.listEnabled()
    if #sources == 0 then return end
    local mixed = MoonSettings.get("source").library_mixed
    local items = { { text = _("混合模式"), value = MIXED } }
    for _idx, meta in ipairs(sources) do
        items[#items + 1] = { text = meta.name or meta.id, value = meta.id }
    end
    List:new{
        title = _("选择数据源"),
        items = items,
        current = mixed and MIXED or active_id,
        centered = true,
        on_select = function(id)
            if id == MIXED then
                if mixed then return end
                MoonSettings.get("source").library_mixed = true
                MoonSettings.save("source")
                Toast:new{ text = T(_("已切换数据源：%1"), _("混合模式")), timeout = 2 }:show()
                SourceRegistry.notifyChanged()
                return
            end
            if not id then return end
            if not mixed and id == active_id then return end
            if mixed then
                MoonSettings.get("source").library_mixed = false
                MoonSettings.save("source")
            end
            SourceRegistry.setActive(id)
            local name = id
            for _idx, meta in ipairs(sources) do
                if meta.id == id then name = meta.name or meta.id break end
            end
            Toast:new{ text = T(_("已切换数据源：%1"), name), timeout = 2 }:show()
            SourceRegistry.notifyChanged()
        end,
    }:show()
end

--- 弹出已启用数据源列表并切换当前源（含置顶的混合模式）。
function Source:pickActive()
    pickSource(SourceRegistry.activeId())
end

--- 弹出全部源的多选列表，勾选即时生效，关闭时重建桌面。
--- 当前源那一项不可取消勾选，否则会没有可用源。
---@param desktop table 桌面实例
local function pickEnabledSources(desktop)
    local active_id = SourceRegistry.activeId()
    local items = {}
    for _idx, meta in ipairs(SourceRegistry.list()) do
        items[#items + 1] = {
            text = meta.name or meta.id,
            value = meta.id,
            checked = SourceRegistry.isEnabled(meta.id),
            enabled = meta.id ~= active_id,
        }
    end
    List:new{
        title = _("启用源"), multi = true, items = items, centered = true,
        on_toggle = function(id, on) SourceRegistry.setEnabled(id, on) end,
        close_callback = function() desktop:updateView() end,
    }:show()
end

--- 书籍来源：当前源 + 启用哪些。
---@param ctx table
---@return table
function Source:scopeSections(ctx)
    local desktop = ctx.desktop
    local active_name = ctx.active_name
    local enabled = SourceRegistry.listEnabled()
    return {{
        title = _("书籍来源"),
        rows = {
            function(iw)
                return Row.widget({
                    width = iw,
                    kind = "nav", icon = "source", title = _("当前数据源"),
                    status = Source.displayName(active_name), status_on = true,
                    callback = function() Source:pickActive() end,
                })
            end,
            function(iw)
                return Row.widget({
                    width = iw,
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
    local plugin = ctx.plugin
    local sections = {}
    for _idx, meta in ipairs(SourceRegistry.listEnabled()) do
        if meta.id ~= "local" then
            local mod = Source.loadSetting(meta.id)
            if mod and (type(mod.rows) == "function" or type(mod.open) == "function") then
                local status, status_on
                if type(mod.rowStatus) == "function" then status, status_on = mod.rowStatus() end
                local title = (mod.rowTitle and mod.rowTitle()) or _("账号与登录")
                local icon = (mod.rowIcon and mod.rowIcon()) or "dns"
                local rows = type(mod.rows) == "function" and mod.rows(plugin) or { function(iw)
                    return Row.widget({
                        width = iw,
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

    local local_setting = Source.loadSetting("local")
    if local_setting and (type(local_setting.rows) == "function" or type(local_setting.open) == "function") then
        local status, status_on = local_setting.rowStatus()
        local rows = type(local_setting.rows) == "function" and local_setting.rows(plugin) or { function(iw)
            return Row.widget({
                width = iw,
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

    local store = MoonSettings.get("store")
    sections[#sections + 1] = {
        title = _("书城"),
        rows = { function(iw)
            local on = store.enabled
            return Row.widget({
                width = iw,
                icon = "storefront", title = _("书城"),
                subtitle = _("底栏显示书城，搜索已启用的书源与 Z站、OPDS"),
                toggle = on,
                callback = function()
                    store.enabled = not on
                    MoonSettings.save("store")
                    SourceRegistry.notifyChanged()
                end,
            })
        end },
    }
    for _idx, def in ipairs({
        { id = "zlib", title = _("Z-Library"), icon = "storefront",
          subtitle = _("在书城中搜索 Z站；下载后导入本地书库"),
          entry = _("Z-Library 账号"), entry_icon = "vpn_key" },
        { id = "opds", title = _("OPDS"), icon = "rss_feed",
          subtitle = _("在书城中搜索 OPDS；Calibre、Komga、Kavita 等书库，下载后导入本地书库"),
          entry = _("OPDS 目录"), entry_icon = "link" },
    }) do
        local key = def.id .. "_enabled"
        local rows = { function(iw)
            local on = store[key]
            return Row.widget({
                width = iw,
                icon = def.icon, title = def.title, subtitle = def.subtitle,
                toggle = on,
                callback = function()
                    store[key] = not on
                    MoonSettings.save("store")
                    SourceRegistry.notifyChanged()
                end,
            })
        end }
        if store[key] then
            local setting = require("store." .. def.id .. ".setting")
            local status, status_on = setting.rowStatus()
            rows[2] = function(iw)
                return Row.widget({
                    width = iw,
                    kind = "nav", icon = def.entry_icon, title = def.entry,
                    status = status, status_on = status_on,
                    callback = function() setting.open(plugin) end,
                })
            end
        end
        sections[#sections + 1] = { title = def.title, rows = rows }
    end
    return sections
end

return Source
