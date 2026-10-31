--[[--
设置页编排：根页是分组目录，点分组进叠层列该组条目；再点才是具体设置页。

条目多的组（阅读 / 系统 / 维护）在组页里按分类分节平铺，不另开一层目录（总深度最多三层：根 → 组 → 设置页）。
分类只影响展示，不改 group / 配置键；表见 GROUP_FOLDERS。
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
local Input = require("ui.input")
local _ = require("gettext")
local T = require("ffi/util").template

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
function Settings:onEvent(event, payload)
    if event == "source_changed" then
        self:reset()
    elseif event == "swipe" and (payload.direction == "west" or payload.direction == "east") then
        self.page = Input.page(self.page + (payload.direction == "west" and 1 or -1), self.pages or 1)
        self.desktop:updateView()
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
            group = "library", order = 5, id = "enabled_sources",
            row = function(iw)
                local n = #SourceRegistry.listEnabled()
                return Row.widget({
                    width = iw, kind = "nav", icon = "checklist", title = _("启用的书源"),
                    subtitle = _("选择在书库与账号里出现哪些书源"),
                    status = T(_("%1 个"), n), status_on = true,
                    callback = function() Source.pickEnabled(desktop) end,
                })
            end,
        },
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
            subtitle = _("本地书籍与书源账号"),
            page = {
                title = _("账号"),
                sections = function() return Source:configSections{ desktop = desktop, plugin = plugin } end,
            },
        },
        {
            group = "appearance", order = 10, id = "appearance", icon = "palette", title = _("主题与字体"),
            subtitle = _("界面风格、字体、缩放"),
            status = string.format("%d%%", Theme.scale()), status_on = true,
            page = {
                title = _("主题与字体"),
                sections = function()
                    return Display:appearanceSections{
                        desktop = desktop, font_name = Fonts.currentName(), scale = Theme.scale(),
                    }
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
            group = "system", order = 5, id = "startup", icon = "keyboard", title = _("启动与按键"),
            subtitle = _("启动进入月读、翻页键"),
            page = {
                title = _("启动与按键"),
                sections = function()
                    return {
                        { title = _("启动与按键"), rows = DesktopSettings:rows(desktop, require("menu").openOnStart()) },
                        { title = _("分页与弹窗"), rows = DesktopSettings:inputRows(desktop) },
                    }
                end,
            },
        },
        {
            group = "desktop", order = 10, id = "tabbar_labels",
            row = DesktopSettings:tabbarLabelsRow(desktop),
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
        -- 页面：底栏四个内容页的设置，一律三级叠层（图书馆 / 订阅 / 书城 / 统计）。
        {
            group = "desktop", order = 40, id = "library", icon = "local_library", title = _("图书馆"),
            subtitle = _("书架布局、封面与点击行为"),
            page = {
                title = _("图书馆"),
                sections = function() return LibrarySettings:sections(desktop) end,
            },
        },
        {
            group = "desktop", order = 42, id = "store", icon = "storefront", title = _("书城"),
            subtitle = _("底栏书城与 Z站、OPDS"),
            page = {
                title = _("书城"),
                sections = function() return Source:storeSections{ desktop = desktop, plugin = plugin } end,
            },
        },
        {
            group = "desktop", order = 43, id = "insight", icon = "monitoring", title = _("统计"),
            subtitle = _("选择显示哪些页面与数据，其余自动拉伸"),
            page = { title = _("统计"), sections = function() return InsightSettings:sections(desktop) end },
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
        { group = "appearance", order = 40, id = "language", row = Language:row() },
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
        { group = "maintenance", order = 30, id = "clear_stats", row = Maintenance:clearStatsRow(desktop) },
        { group = "maintenance", order = 40, id = "import_stats", row = Maintenance:importKoreaderStatsRow(desktop) },
        { group = "maintenance", order = 70, id = "debug_log", row = Maintenance:debugLogRow(desktop) },
        { group = "maintenance", order = 80, id = "about", row = Maintenance:aboutRow() },
        { group = "maintenance", order = 90, id = "close_desktop", row = Maintenance:closeRow(desktop) },
    }
end

--- 条目导航行。push=true 时叠在当前叠层上（组内进子页，返回回到组）。
---@param desktop BookDesktop
---@param entry BookSettingNode
---@param push boolean|nil
---@return fun(iw: number): table
local function navRow(desktop, entry, push)
    return function(iw)
        return Row.widget({
            width = iw,
            kind = "nav",
            icon = entry.icon,
            title = entry.title,
            subtitle = entry.subtitle,
            status = entry.status,
            status_on = entry.status_on,
            callback = function()
                if push then Overlay.push(desktop, entry.page) else Overlay.open(desktop, entry.page) end
            end,
        })
    end
end

--- 组内条目行：导航用 push，直接行原样。
---@param desktop BookDesktop
---@param entries BookSettingNode[]
---@return (fun(iw: number): table)[]
local function entryRows(desktop, entries)
    local rows = {}
    for _idx, entry in ipairs(entries) do
        rows[#rows + 1] = entry.row or navRow(desktop, entry, true)
    end
    return rows
end

--- 条目 id 是否命中前缀表（精确相等，或 `前缀:` 开头，如 feature:xray:1）。
---@param key string
---@param prefixes string[]
---@return boolean
local function idMatch(key, prefixes)
    for _idx, prefix in ipairs(prefixes) do
        if key == prefix or key:sub(1, #prefix + 1) == prefix .. ":" then return true end
    end
    return false
end

--- 大组才拆分类（只影响展示，不改 group / 配置键）。未点名的落入 default=true 的那一类。
--- match 写条目 id：核心裸 id；feature 页面是 feature:<name>:<id>；feature 直接行是自己写的 id。
local GROUP_FOLDERS = {
    desktop = {
        {
            id = "bar", icon = "web_asset", title = _("顶栏与底栏"),
            subtitle = _("顶栏项、底栏名称与拓展"), default = true,
            match = { "topbar", "tabbar_labels", "feature:extensions" },
        },
        {
            id = "pages", icon = "dashboard", title = _("页面"),
            subtitle = _("图书馆、订阅、书城、统计"),
            -- 订阅是 feature:subscribe:main；其余核心裸 id。
            match = { "library", "feature:subscribe", "store", "insight" },
        },
        {
            id = "actions", icon = "dashboard_customize", title = _("快捷面板"),
            subtitle = _("桌面快捷开关"),
            match = { "feature:panel" },
        },
    },
    reader = {
        {
            id = "ui", icon = "touch_app", title = _("阅读界面"),
            subtitle = _("行为、栏、侧栏、翻页、快捷面板与段评"), default = true,
            -- 段评是页内标记，跟栏/侧栏一类；未列在其它类的（字体映射、翻页动画等）也归这里。
        },
        {
            id = "lookup", icon = "format_ink_highlighter", title = _("划词与词典"),
            subtitle = _("查词、词典、百科、OCR、生僻字"),
            match = { "lookup", "popup_menu", "feature:dictionary", "feature:baike", "feature:ocr", "feature:rare" },
        },
        {
            id = "smart", icon = "psychology", title = _("智能"),
            subtitle = _("X-Ray、AI、翻译"),
            match = { "ai", "feature:xray", "feature:translate" },
        },
    },
    system = {
        {
            id = "connect", icon = "lan", title = _("连接"),
            subtitle = _("网络与远程管理"),
            match = { "network", "feature:remote" },
        },
        {
            id = "local", icon = "devices", title = _("本机"),
            subtitle = _("启动、时间、输入法与设备"), default = true,
            match = { "startup", "device", "feature:clock", "feature:ime" },
        },
        {
            id = "status", icon = "monitoring", title = _("状态"),
            subtitle = _("进程的内存与 CPU"),
            match = { "feature:monitor" },
        },
    },
    maintenance = {
        {
            -- id 不能叫 features：边界检查会把裸 "features" 串当成 require("features")。
            id = "manage", icon = "delete_sweep", title = _("功能与更新"),
            subtitle = _("功能开关与检查更新"),
            match = { "feature:manage", "update_auto", "update_check" },
        },
        {
            id = "data", icon = "storage", title = _("数据"),
            subtitle = _("存储与统计"),
            match = { "feature:storage", "clear_stats", "import_stats" },
        },
        {
            id = "other", icon = "info", title = _("其它"),
            subtitle = _("调试、关于与关闭桌面"), default = true,
            match = { "debug_log", "about", "close_desktop" },
        },
    },
}

---@param entry BookSettingNode
---@param folders { id: string, match: string[]|nil, default: boolean|nil }[]
---@return string
local function folderId(entry, folders)
    local key = entry.id or ""
    local fallback
    for _idx, folder in ipairs(folders) do
        if folder.default then fallback = folder.id end
        if folder.match and idMatch(key, folder.match) then return folder.id end
    end
    return fallback or folders[1].id
end

---@param group { entries: BookSettingNode[] }
---@param folders { id: string, match: string[]|nil, default: boolean|nil }[]
---@param bucket string
---@return BookSettingNode[]
local function folderEntries(group, folders, bucket)
    local out = {}
    for _idx, entry in ipairs(group.entries) do
        if folderId(entry, folders) == bucket then out[#out + 1] = entry end
    end
    return out
end

--- 普通分组叠层：该组全部条目一页列出。
---@param desktop BookDesktop
---@param group { id: string, title: string, entries: BookSettingNode[] }
---@return BookSettingsOverlaySpec
local function groupPage(desktop, group)
    return {
        id = "group:" .. group.id,
        title = group.title,
        sections = function()
            return {{ title = group.title, rows = entryRows(desktop, group.entries) }}
        end,
    }
end

--- 大组叠层：分类做成同一页的分节（不再多点一层），总深度 = 根目录 → 组页 → 设置页。
---@param desktop BookDesktop
---@param group { id: string, title: string, entries: BookSettingNode[] }
---@param folders { id: string, icon: string, title: string, subtitle: string, match: string[]|nil, default: boolean|nil }[]
---@return BookSettingsOverlaySpec
local function folderGroupPage(desktop, group, folders)
    return {
        id = "group:" .. group.id,
        title = group.title,
        sections = function()
            local sections = {}
            for _idx, folder in ipairs(folders) do
                local entries = folderEntries(group, folders, folder.id)
                if #entries > 0 then
                    sections[#sections + 1] = { title = folder.title, rows = entryRows(desktop, entries) }
                end
            end
            return sections
        end,
    }
end

--- 根页顶部的搜索行：首次点开才建索引，缓存在本次 groups 上，根页重建即失效。
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

--- 根页分组导航行：点开该组叠层。
---@param desktop BookDesktop
---@param group { id: string, title: string, icon: string|nil, entries: BookSettingNode[] }
---@return fun(iw: number): table|nil
local function groupRow(desktop, group)
    if #group.entries == 0 then return nil end
    return function(iw)
        return Row.widget({
            width = iw,
            kind = "nav",
            icon = group.icon,
            title = group.title,
            status = string.format("%d", #group.entries),
            status_on = true,
            callback = function()
                local folders = GROUP_FOLDERS[group.id]
                local page = folders and folderGroupPage(desktop, group, folders) or groupPage(desktop, group)
                Overlay.open(desktop, page)
            end,
        })
    end
end

--- 构建设置根页：只列搜索 + 分组目录；组内条目在叠层里。
---@return table
function Settings:updateView()
    local desktop = self.desktop
    local entries = coreEntries(desktop)
    for _idx, entry in ipairs(Tree.features(desktop)) do entries[#entries + 1] = entry end
    local roots = {
        { id = "library", title = _("书库"), icon = "local_library" },
        { id = "appearance", title = _("外观"), icon = "palette" },
        { id = "desktop", title = _("桌面"), icon = "home" },
        { id = "games", title = _("游戏"), icon = "sports_esports" },
        { id = "reader", title = _("阅读"), icon = "menu_book" },
        { id = "system", title = _("系统"), icon = "settings" },
        { id = "security", title = _("安全"), icon = "lock" },
        { id = "maintenance", title = _("维护"), icon = "handyman" },
    }
    -- 扩展分组（setting.groups）插在 after 指定的分组后，没写 after 排在最后。
    for _idx, g in ipairs(require("utils.extension").list("setting.groups")) do
        local at = #roots + 1
        for i, r in ipairs(roots) do
            if g.after and (r.id == g.after or r.after == g.after) then at = i + 1 end
        end
        table.insert(roots, at, { id = g.id, title = g.title, after = g.after, icon = g.icon })
    end
    local groups = Tree.build(roots, entries) ---@type table[]
    -- Tree.build 不传 icon，从 roots 补回去。
    local icons = {}
    for _idx, r in ipairs(roots) do icons[r.id] = r.icon end
    for _idx, group in ipairs(groups) do group.icon = icons[group.id] end

    local group_rows = {}
    for _idx, group in ipairs(groups) do
        local row = groupRow(desktop, group)
        if row then group_rows[#group_rows + 1] = row end
    end
    local sections = {
        { title = _("搜索"), rows = { searchRow(self, groups) } },
        { title = _("分类"), rows = group_rows },
    }
    local body
    body, self.page, self.pages = Sections.widget({
        width = desktop.dimen.w,
        height = desktop:contentHeight(),
        page = self.page,
        keys = false,
        on_page = function(page) self.page = page; desktop:updateView() end,
        sections = sections,
    })
    return body
end

return Settings
