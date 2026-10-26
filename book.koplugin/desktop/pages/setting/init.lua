--[[--
设置页编排：根页功能目录，子页走详情叠层。

根页与各页面由「条目」按层级（分组 → 页面 → 分节）合并而成，规则见 tree.lua。
本文件只声明核心条目；feature 的条目在各自的 setting.lua，扫描得到。各设置项实现位于 desktop/pages/setting/。

@module koplugin.book.desktop.pages.setting
--]]

local Sections = require("ui.themes.widgets.sections")
local Theme = require("ui.themes")
local Row = require("ui.themes.widgets.row")
local Fonts = require("ui.fonts")
local SourceRegistry = require("source.registry")
local Overlay = require("desktop.pages.setting.overlay")
local _ = require("gettext")

local Tree = require("desktop.pages.setting.tree")
local Source = require("desktop.pages.setting.source")
local Display = require("desktop.pages.setting.display")
local LibrarySettings = require("desktop.pages.setting.library")
local DesktopSettings = require("desktop.pages.setting.desktop")
local TopbarSettings = require("desktop.pages.setting.topbar")
local InsightSettings = require("desktop.pages.setting.insight")
local Language = require("desktop.pages.setting.language")
local Maintenance = require("desktop.pages.setting.maintenance")
local AISettings = require("desktop.pages.setting.ai")
local DeviceSettings = require("desktop.pages.setting.device")
local ReaderSettings = require("desktop.pages.setting.reader")
local HttpSetting = require("http.proxy.setting")

---@class BookSettings
---@field desktop BookDesktop
---@field page integer
---@field source BookSettingsSource 顶栏点源名经此换源
---@field cache_clear_job { cancel: fun() }|nil 清理缓存任务（不随页面取消，清理必须落地）
local Settings = {}
Settings.__index = Settings

---@param opts { desktop: BookDesktop }
---@return BookSettings
function Settings:new(opts)
    return setmetatable({ desktop = opts.desktop, page = 1, source = Source }, self)
end

--- 由 Tab 切换恢复时关掉叠层；系统唤醒时保留。
---@param changed boolean|nil TAB 点击时传 boolean；桌面唤醒时不重置
function Settings:activate(changed)
    if changed == nil then return end
    self:reset()
end

function Settings:destroy()
end

--- 回到设置根页并关闭功能叠层。
function Settings:reset()
    self.page = 1
    Overlay.closeAll(self.desktop)
end

--- 换源后关掉叠层，避免停在过期的来源页。
---@param event string 父组件转发的事件名称或事件对象
function Settings:onEvent(event)
    if event == "source_changed" then
        self:reset()
    end
end

---@return string, string
local function activeSource()
    local active_id = SourceRegistry.activeId()
    local active_name = active_id
    for _idx, meta in ipairs(SourceRegistry.list()) do
        if meta.id == active_id then active_name = meta.name or meta.id break end
    end
    return active_id, Source.displayName(active_name)
end

--- 核心条目：根页分组里的行、核心页面与它们自带 / 追加的分节（格式见 tree.lua）。
---@param desktop BookDesktop
---@return BookSettingEntry[]
local function coreEntries(desktop)
    local plugin = desktop.plugin
    local network = HttpSetting.entry(desktop)
    network.group, network.order = "system", 10
    return {
        {
            group = "library", order = 10,
            row = function(iw)
                return Row.widget({
                    width = iw, kind = "nav", icon = "source", title = _("当前书库"),
                    subtitle = _("切换当前书源或混合模式"), status = select(2, activeSource()), status_on = true,
                    callback = function() Source:pickActive() end,
                })
            end,
        },
        {
            group = "library", order = 20, id = "source_config", icon = "tune", title = _("账号"),
            subtitle = _("本地书籍、书源账号、Z-Library / OPDS 书城"),
            page = {
                title = _("账号"),
                right_icon = "checklist",
                right_callback = function() Source.pickEnabled(desktop) end,
                sections = function() return Source:configSections{ desktop = desktop, plugin = plugin } end,
            },
        },
        {
            group = "appearance", order = 10, id = "appearance", icon = "palette", title = _("外观"),
            subtitle = _("界面风格、字体、缩放"),
            status = string.format("%d%%", Theme.scale()), status_on = true,
            page = {
                title = _("外观"),
                sections = function()
                    return {{
                        title = _("外观"),
                        rows = Display:appearanceRows{
                            desktop = desktop, font_name = Fonts.currentName(), scale = Theme.scale(),
                        },
                    }}
                end,
            },
        },
        {
            group = "appearance", order = 30, id = "display", icon = "display_settings", title = _("屏幕"),
            subtitle = _("屏幕刷新、夜间、亮度"),
            page = {
                title = _("屏幕"),
                sections = function()
                    local rows = Display:screenRows{ desktop = desktop }
                    return #rows > 0 and {{ title = _("屏幕"), rows = rows }} or {}
                end,
            },
        },
        {
            group = "desktop", order = 10, id = "startup", icon = "keyboard", title = _("启动与按键"),
            subtitle = _("启动进入月读、翻页键"),
            page = {
                title = _("启动与按键"),
                sections = function()
                    return {{ title = _("启动与按键"), rows = DesktopSettings:rows(desktop, require("menu").openOnStart()) }}
                end,
            },
        },
        {
            group = "library", order = 30, id = "library_display", icon = "grid_view", title = _("书架显示"),
            subtitle = _("图书馆、最近阅读、书架的每行数量与封面风格"),
            page = {
                title = _("书架显示"),
                sections = function() return LibrarySettings:sections(desktop) end,
            },
        },
        {
            group = "desktop", order = 20, id = "topbar", icon = "toolbar", title = _("桌面顶栏"),
            subtitle = _("时钟、电量等状态项"),
            page = {
                title = _("桌面顶栏"),
                preview = function(width) return TopbarSettings.preview(width) end,
                sections = function() return {{ title = _("顶栏"), rows = TopbarSettings:rows(desktop) }} end,
            },
        },
        {
            group = "desktop", order = 30, id = "insight", icon = "monitoring", title = _("统计页"),
            subtitle = _("选择显示哪些页面与数据，其余自动拉伸"),
            page = { title = _("统计页"), sections = function() return InsightSettings:sections(desktop) end },
        },
        {
            group = "reader", order = 10, id = "reader_behavior", icon = "touch_app", title = _("阅读行为"),
            subtitle = _("脚注与阅读行为"),
            page = { title = _("阅读行为"), sections = function() return ReaderSettings:sections(desktop) end },
        },
        {
            group = "reader", order = 50, id = "lookup", icon = "format_ink_highlighter", title = _("查词"),
            subtitle = _("选区与划词"),
            page = { title = _("查词") },
        },
        { parent = "lookup", order = 10, sections = function() return ReaderSettings:lookupSections(desktop) end },
        {
            group = "reader", order = 60, id = "popup_menu", icon = "touch_long", title = _("划词菜单"),
            subtitle = _("按钮开关、顺序与来源"),
            page = {
                title = _("划词菜单"),
                sections = function() return {{ title = _("按钮"), rows = ReaderSettings:popupRows(desktop) }} end,
            },
        },
        { group = "appearance", order = 40, row = Language:row() },
        {
            group = "system", order = 50, id = "device", icon = "devices", title = _("设备"),
            subtitle = _("设备名称与头像"),
            page = { title = _("设备"), sections = function() return {{ title = _("设备"), rows = DeviceSettings:rows(desktop) }} end },
        },
        {
            group = "reader", order = 55, id = "ai", icon = "psychology", title = _("AI 接口"),
            subtitle = _("X-Ray 使用的大模型接口"),
            page = { title = _("AI 接口"), sections = function() return {{ title = _("AI"), rows = AISettings:rows(desktop) }} end },
        },
        network,
        { group = "maintenance", order = 30, row = Maintenance:clearStatsRow(desktop) },
        { group = "maintenance", order = 40, row = Maintenance:importKoreaderStatsRow(desktop) },
        { group = "maintenance", order = 70, row = Maintenance:debugLogRow(desktop) },
        { group = "maintenance", order = 80, row = Maintenance:aboutRow() },
        { group = "maintenance", order = 90, row = Maintenance:closeRow(desktop) },
    }
end

--- 根页导航行：点开条目的页面叠层。
---@param desktop BookDesktop
---@param entry BookSettingNode
---@return fun(iw: number): table
local function navRow(desktop, entry)
    return function(iw)
        return Row.widget({
            width = iw,
            kind = "nav",
            icon = entry.icon,
            title = entry.title,
            subtitle = entry.subtitle,
            status = entry.status,
            status_on = entry.status_on,
            callback = function() Overlay.open(desktop, entry.page) end,
        })
    end
end

--- 根页顶部的搜索行：首次点开才建索引（要把所有页面的行建一遍），缓存在本次 groups 上，根页重建即失效。
---@param self BookSettings
---@param groups table[] Tree.build 的结果
---@return fun(iw: number): table
local function searchRow(self, groups)
    return function(iw)
        return Row.widget({
            width = iw,
            icon = "search",
            title = _("搜索设置"),
            subtitle = _("按名称或说明查找设置项"),
            callback = function()
                local Search = require("desktop.pages.setting.search")
                ---@cast groups table[]|{ search_hits?: table }
                groups.search_hits = groups.search_hits or Search.build(groups)
                Search.prompt(self.desktop, groups.search_hits)
            end,
        })
    end
end

--- 构建设置根页：核心条目 + 扫描到的 feature 条目按层级合并；按内容区尺寸现建，翻页经桌面 updateView 重建。
---@return table
function Settings:updateView()
    local desktop = self.desktop
    local entries = coreEntries(desktop)
    for _idx, entry in ipairs(Tree.features(desktop)) do entries[#entries + 1] = entry end
    local roots = {
        { id = "library", title = _("书库") },
        { id = "appearance", title = _("外观") },
        { id = "desktop", title = _("桌面") },
        { id = "reader", title = _("阅读") },
        { id = "system", title = _("系统") },
        { id = "security", title = _("安全") },
        { id = "maintenance", title = _("维护") },
    }
    -- 扩展分组（setting.groups）插在 after 指定的分组后，没写 after 排在最后。
    for _idx, g in ipairs(require("utils.extension").list("setting.groups")) do
        local at = #roots + 1
        for i, r in ipairs(roots) do
            if g.after and (r.id == g.after or r.after == g.after) then at = i + 1 end
        end
        table.insert(roots, at, { id = g.id, title = g.title, after = g.after })
    end
    local groups = Tree.build(roots, entries)
    local sections = {{ title = _("搜索"), rows = { searchRow(self, groups) } }}
    for _idx, group in ipairs(groups) do
        local rows = {}
        for _i, entry in ipairs(group.entries) do rows[#rows + 1] = entry.row or navRow(desktop, entry) end
        sections[#sections + 1] = { title = group.title, rows = rows }
    end
    local body
    body, self.page = Sections.widget({
        width = desktop.dimen.w,
        height = desktop:contentHeight(),
        page = self.page,
        on_page = function(page) self.page = page; desktop:updateView() end,
        sections = sections,
    })
    return body
end

return Settings
