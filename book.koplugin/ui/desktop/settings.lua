--[[--
设置页 UI（桌面 Tab）：十项主菜单 + 分类二级页。

  数据源 / 显示 / 锁屏 / 桌面 / 语言与输入 / 远程管理 /
  清理缓存 / 关于 / 关闭桌面 / 检查更新。
  子页首行固定「返回」；数据源子页再按源显示小标题。

布局（SettingRow 列表 + Pager.frame）：
  +-----------------------------------------------+
  | [icon] 数据源            微信读书           › |
  | [icon] 显示                  130%           › |
  | [icon] 维护                                 › |
  |  |«  ‹   Page N of M   ›  »|                  |
  +-----------------------------------------------+

@module koplugin.book.ui.settings
--]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local NetworkMgr = require("ui/network/manager")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local Icon = require("ui.components.icon")
local Pager = require("ui.components.pager")
local Popup = require("ui.components.popup")
local SettingRow = require("ui.components.settingrow")
local FontPicker = require("ui.components.fontpicker")
local MoonSettings = require("utils.settings")
local MoonFont = require("utils.font")
local LockScreen = require("lockscreen.init")
local Remote = require("remote.init")
local Pinyin = require("pinyin.init")
local SourceRegistry = require("source.registry")
local Cache = require("book.cache")
local Host = require("host")
local _ = require("gettext")
local T = require("ffi/util").template

local REPO_URL = "https://github.com/AnkioTomas/moon"
local REPO_HOST = "github.com/AnkioTomas/moon"

--- 读取插件版本号（bookversion 模块）。
---@return string
local function pluginVersion()
    local ok, ver = pcall(require, "bookversion")
    if ok and type(ver) == "string" and ver ~= "" then
        return ver
    end
    return "0.0.0-dev"
end

--- 弹出关于对话框。
local function showAbout()
    local ver = pluginVersion()
    local dialog
    local buttons = {}
    if Device:canOpenLink() then
        buttons[#buttons + 1] = {{
            text = _("打开 GitHub"),
            callback = function()
                Device:openLink(REPO_URL)
            end,
        }}
    end
    buttons[#buttons + 1] = {{
        text = _("关闭"),
        callback = function()
            UIManager:close(dialog)
        end,
    }}

    dialog = ButtonDialog:new{
        title = _("关于"),
        title_align = "center",
        use_info_style = false,
        buttons = buttons,
    }

    local avail_w = dialog:getAddedWidgetAvailableWidth()
    local body = VerticalGroup:new{ align = "center" }
    local icon = Icon.widget{
        name = "info",
        size = 44,
    }
    if icon then
        table.insert(body, icon)
        table.insert(body, VerticalSpan:new{ width = UI.sz(10) })
    end
    table.insert(body, TextWidget:new{
        text = _("Book 书库"),
        face = UI.face("cfont", 20),
    })
    table.insert(body, VerticalSpan:new{ width = UI.sz(4) })
    table.insert(body, TextWidget:new{
        text = T(_("版本 %1"), ver),
        face = UI.face("xx_smallinfofont", 13),
        fgcolor = UI.muted(),
    })
    table.insert(body, VerticalSpan:new{ width = UI.sz(12) })
    table.insert(body, TextBoxWidget:new{
        text = _("面向 KOReader 的书库桌面，支持多数据源与阅读进度同步。"),
        face = UI.face("xx_smallinfofont", 13),
        width = avail_w,
        alignment = "center",
        fgcolor = UI.dim(),
    })
    table.insert(body, VerticalSpan:new{ width = UI.sz(14) })
    table.insert(body, TextWidget:new{
        text = "AnkioTomas",
        face = UI.face("cfont", 14),
    })
    table.insert(body, VerticalSpan:new{ width = UI.sz(2) })
    table.insert(body, TextWidget:new{
        text = REPO_HOST,
        face = UI.face("xx_smallinfofont", 12),
        fgcolor = UI.muted(),
    })
    table.insert(body, VerticalSpan:new{ width = UI.sz(4) })
    table.insert(body, TextWidget:new{
        text = _("MIT License"),
        face = UI.face("xx_smallinfofont", 11),
        fgcolor = UI.muted(),
    })

    dialog:addWidget(body)
    UIManager:show(dialog)
end

local Settings = {}

--- 按源 id 加载 source.<id>.setting 模块。
---@param id string
---@return table|nil
local function loadSourceSetting(id)
    local ok, mod = pcall(require, "source." .. tostring(id) .. ".setting")
    if ok and type(mod) == "table" then
        return mod
    end
    return nil
end

--- 设置分组内的缩进分割线。
---@param width number
---@return table
local function insetDivider(width)
    local inset = UI.sz(8)
    local line_w = math.max(UI.sz(40), width - inset * 2)
    return CenterContainer:new{
        dimen = Geom:new{ w = width, h = UI.line() },
        LineWidget:new{
            background = UI.rule(),
            dimen = Geom:new{ w = line_w, h = UI.line() },
        },
    }
end

--- 分组标题 + 各行展平进 out；标题与 item 同等参与 Pager.pack 切页。
---@param out table
---@param width number
---@param title string
---@param row_builders table
local function appendSection(out, width, title, row_builders)
    if #out > 0 then
        table.insert(out, VerticalSpan:new{ width = UI.sectionGap() })
    end
    table.insert(out, LeftContainer:new{
        dimen = Geom:new{ w = width, h = UI.sz(28) },
        TextWidget:new{
            text = title,
            face = UI.face("cfont", 13),
            max_width = width,
            fgcolor = UI.muted(),
        },
    })
    for i, build in ipairs(row_builders) do
        if i > 1 then
            table.insert(out, insetDivider(width))
        end
        table.insert(out, build(width))
    end
end

--- 无标题行列表（行间缩进分割线）。
---@param out table
---@param width number
---@param row_builders table
local function appendRowList(out, width, row_builders)
    for i, build in ipairs(row_builders) do
        if i > 1 then
            table.insert(out, insetDivider(width))
        end
        table.insert(out, build(width))
    end
end

--- 进入子页 / 回主菜单（重置分页）。
---@param desktop table
---@param sub string|nil
local function gotoSub(desktop, sub)
    desktop._settings_sub = sub
    desktop._settings_page = 1
    desktop:rebuild()
end

--- 子页首行：返回主菜单。
---@param desktop table
---@return table
local function backRow(desktop)
    return function(iw)
        return SettingRow.build(iw, {
            kind = "action",
            icon = "arrow_back",
            title = _("返回"),
            callback = function()
                gotoSub(desktop, nil)
            end,
        })
    end
end

--- 弹出数据源选择 sheet（只列启用源）。
---@param desktop table
---@param plugin table|nil
---@param active_id string
local function pickSource(desktop, plugin, active_id)
    local sources = SourceRegistry.listEnabled()
    if #sources == 0 then return end
    local items = {}
    for _, meta in ipairs(sources) do
        local id = meta.id
        local name = meta.name or meta.id
        local label = name
        if id == active_id then
            label = "✓ " .. name
        end
        table.insert(items, {
            text = label,
            value = id,
        })
    end
    Popup.sheet{
        title = _("选择数据源"),
        items = items,
        on_select = function(id)
            if not id or id == active_id then
                return
            end
            SourceRegistry.setActive(id)
            if plugin and plugin.onSourceChanged then
                plugin:onSourceChanged()
            end
            local name = id
            for _, meta in ipairs(sources) do
                if meta.id == id then
                    name = meta.name or meta.id
                    break
                end
            end
            UIManager:show(InfoMessage:new{
                text = T(_("已切换数据源：%1"), name),
                timeout = 2,
            })
            desktop:rebuild()
        end,
    }
end

--- 启用源多选（活跃源强制勾选且不可点，见 Registry.setEnabled 的兜底拒绝）。
---@param desktop table
local function pickEnabledSources(desktop)
    local active_id = MoonSettings.activeSourceId()
    local items = {}
    for _, meta in ipairs(SourceRegistry.list()) do
        local id = meta.id
        items[#items + 1] = {
            text = meta.name or meta.id,
            value = id,
            checked = SourceRegistry.isEnabled(id),
            enabled = id ~= active_id,
        }
    end
    Popup.list{
        title = _("启用源"),
        select_mode = "multi",
        items = items,
        on_toggle = function(id, on)
            SourceRegistry.setEnabled(id, on)
        end,
        close_callback = function()
            desktop:rebuild()
        end,
    }
end

--- 数据源子页分组：通用、本地、各启用源、同步与书城。
---@param desktop table
---@param plugin table|nil
---@param active_id string
---@param active_name string
---@return table
local function sourceSections(desktop, plugin, active_id, active_name)
    local source = plugin and plugin.getSource and plugin:getSource() or nil
    local enabled = SourceRegistry.listEnabled()
    local common_rows = {}

    common_rows[#common_rows + 1] = function(iw)
        return SettingRow.build(iw, {
            kind = "nav",
            icon = "source",
            title = _("当前数据源"),
            status = active_name,
            status_on = true,
            callback = function()
                pickSource(desktop, plugin, active_id)
            end,
        })
    end

    local enabled_n = #enabled
    local total_n = #SourceRegistry.list()
    common_rows[#common_rows + 1] = function(iw)
        return SettingRow.build(iw, {
            kind = "nav",
            icon = "checklist",
            title = _("已启用的数据源"),
            status = T(_("已启用 %1/%2"), enabled_n, total_n),
            status_on = true,
            callback = function()
                pickEnabledSources(desktop)
            end,
        })
    end

    local sections = {
        { title = _("数据源"), rows = common_rows },
    }

    -- 本地目录固定可配置，不因本地源暂时停用而消失。
    local local_setting = loadSourceSetting("local")
    if local_setting and type(local_setting.open) == "function" then
        local status, status_on = local_setting.rowStatus()
        sections[#sections + 1] = {
            title = _("本地"),
            rows = {
                function(iw)
                    return SettingRow.build(iw, {
                        kind = "nav",
                        icon = "folder",
                        title = _("本地目录"),
                        status = status,
                        status_on = status_on,
                        callback = function()
                            local_setting.open(plugin)
                        end,
                    })
                end,
            },
        }
    end

    -- 其余已启用源继续保留原有配置入口。
    for _idx, meta in ipairs(enabled) do
        if meta.id ~= "local" then
            local mod = loadSourceSetting(meta.id)
            if mod and type(mod.open) == "function" then
                local status, status_on
                if type(mod.rowStatus) == "function" then
                    status, status_on = mod.rowStatus()
                end
                local title = (mod.rowTitle and mod.rowTitle()) or _("源设置")
                local icon = (mod.rowIcon and mod.rowIcon()) or "dns"
                sections[#sections + 1] = {
                    title = meta.name or meta.id,
                    rows = {
                        function(iw)
                            return SettingRow.build(iw, {
                                kind = "nav",
                                icon = icon,
                                title = title,
                                status = status,
                                status_on = status_on,
                                callback = function()
                                    mod.open(plugin)
                                end,
                            })
                        end,
                    },
                }
            end
        end
    end

    local extra_rows = {}
    -- Z-Library 是全局书城账号（不是源）：跟随活跃源的导入能力，同原语义。
    if type(source and source.importBookAsync) == "function" then
        local store_setting = require("zlib.setting")
        local status, status_on = store_setting.rowStatus()
        extra_rows[#extra_rows + 1] = function(iw)
            return SettingRow.build(iw, {
                kind = "nav",
                icon = "storefront",
                title = _("Z-Library 账号"),
                status = status,
                status_on = status_on,
                callback = function()
                    store_setting.open(plugin)
                end,
            })
        end
    end

    if type(source and source.putProgressAsync) == "function" then
        extra_rows[#extra_rows + 1] = function(iw)
            return SettingRow.build(iw, {
                kind = "action",
                icon = "sync",
                title = _("立即同步进度"),
                callback = function()
                    local Progress = require("book.progress")
                    local src = plugin and plugin.getSource and plugin:getSource()
                    if not src then
                        return
                    end
                    NetworkMgr:runWhenOnline(function()
                        Progress.flushPendingAsync(src, true)
                    end)
                end,
            })
        end
    end
    if #extra_rows > 0 then
        sections[#sections + 1] = {
            title = _("同步与书城"),
            rows = extra_rows,
        }
    end

    return sections
end

--- 弹出锁屏显示单选。
---@param desktop table
---@param current string
local function pickLockScreen(desktop, current)
    Popup.list{
        title = _("锁屏显示"),
        current = current,
        items = LockScreen.options(),
        on_select = function(mode)
            if not mode or mode == current then
                return
            end
            -- 先落盘：联网失败也要保住用户的选择，之后自动补下
            LockScreen.setMode(mode)
            desktop:rebuild()
            if mode == "ko" then
                return
            end
            NetworkMgr:runWhenOnline(function()
                UIManager:show(InfoMessage:new{
                    text = _("正在下载锁屏图…"),
                    timeout = 2,
                })
                LockScreen.refresh(function(ok, err)
                    UIManager:show(InfoMessage:new{
                        text = ok and T(_("已设为%1"), LockScreen.label(mode))
                            or T(_("下载失败: %1"), tostring(err or "")),
                        timeout = 2,
                    })
                end)
            end)
        end,
    }
end

--- 显示子页行。
---@param desktop table
---@param font_name string
---@param scale number
---@param grid_max_cols number
---@return table
local function displayRows(desktop, font_name, scale, grid_max_cols)
    return {
        function(iw)
            return SettingRow.build(iw, {
                kind = "nav",
                icon = "text_fields",
                title = _("字体"),
                status = font_name,
                status_on = true,
                callback = function()
                    FontPicker.open{
                        title = _("字体"),
                        on_done = function()
                            desktop:rebuild()
                        end,
                    }
                end,
            })
        end,
        function(iw)
            return SettingRow.build(iw, {
                kind = "nav",
                icon = "format_size",
                title = _("字号"),
                status = string.format("%d%%", scale),
                status_on = true,
                callback = function()
                    Popup.spin{
                        title = _("字号"),
                        value = UI.getScale(),
                        value_min = UI.scaleMin(),
                        value_max = UI.scaleMax(),
                        value_step = UI.scaleStep(),
                        unit = "%",
                        ok_always_enabled = true,
                        callback = function(spin)
                            local n = UI.setScale(spin.value)
                            UIManager:show(InfoMessage:new{
                                text = string.format("%d%%", n),
                                timeout = 1.5,
                            })
                            desktop:rebuild()
                        end,
                    }
                end,
            })
        end,
        function(iw)
            return SettingRow.build(iw, {
                kind = "nav",
                icon = "grid_view",
                title = _("网格最大列数"),
                status = tostring(grid_max_cols),
                status_on = true,
                callback = function()
                    Popup.spin{
                        title = _("网格最大列数"),
                        value = UI.getGridMaxCols(),
                        value_min = UI.gridMaxColsMin(),
                        value_max = UI.gridMaxColsMax(),
                        value_step = 1,
                        ok_always_enabled = true,
                        callback = function(spin)
                            UI.setGridMaxCols(spin.value)
                            desktop._library_state = nil
                            desktop._store_state = nil
                            desktop:rebuild()
                        end,
                    }
                end,
            })
        end,
    }
end

local function placeholderRow()
    return function(iw)
        return SettingRow.build(iw, {
            kind = "action",
            icon = "more_horiz",
            title = _("其他"),
            status = _("敬请期待"),
        })
    end
end

local function lockscreenRows(desktop)
    local mode = LockScreen.mode()
    return {
        function(iw)
            return SettingRow.build(iw, {
                kind = "nav",
                icon = "wallpaper",
                title = _("锁屏显示"),
                status = LockScreen.label(mode),
                status_on = mode ~= "ko",
                callback = function()
                    pickLockScreen(desktop, mode)
                end,
            })
        end,
        placeholderRow(),
    }
end

local function desktopRows(desktop, open_on)
    return {
        function(iw)
            return SettingRow.build(iw, {
                kind = "toggle",
                icon = "visibility",
                title = _("启动打开桌面"),
                status = open_on and _("开") or _("关"),
                status_on = open_on,
                callback = function()
                    if open_on then
                        G_reader_settings:saveSetting("start_with", "filemanager")
                    else
                        G_reader_settings:saveSetting("start_with", Host.OPEN_ON_START_ID)
                    end
                    desktop:rebuild()
                end,
            })
        end,
        placeholderRow(),
    }
end

local function pickLanguage()
    local Language = require("ui/language")
    local items = {}
    for _, item in ipairs(Language:getLangMenuTable().sub_item_table or {}) do
        items[#items + 1] = {
            text = item.text,
            checked = item.checked_func and item.checked_func(),
            callback = item.callback,
        }
    end
    Popup.list{
        title = _("语言"),
        items = items,
    }
end

local function downloadPinyin(desktop)
    if require("pinyin.download").downloading() then
        return
    end
    local dialog
    local function closeDialog()
        if dialog then
            dialog:close()
            dialog = nil
        end
    end
    Pinyin.downloadDict(function(ok, err)
        closeDialog()
        UIManager:show(InfoMessage:new{
            text = ok and _("拼音词库已就绪")
                or T(_("下载失败: %1"), tostring(err or "")),
            timeout = 2,
        })
        desktop:rebuild()
    end, function(stage, done_bytes, total, _idx, count)
        if stage == "part" and total and total > 0 then
            if not dialog then
                local ok_dlg, ProgressbarDialog = pcall(require, "ui/widget/progressbardialog")
                if not ok_dlg then
                    return
                end
                dialog = ProgressbarDialog:new{
                    title = _("正在下载拼音词库…"),
                    subtitle = T(_("共 %1 片"), count)
                        .. string.format(" · %.1f MB", total / 1048576),
                    progress_max = total,
                    refresh_time_seconds = 1,
                    dismissable = false,
                }
                dialog:show()
            else
                dialog:reportProgress(done_bytes)
            end
        elseif stage == "manifest" then
            UIManager:show(InfoMessage:new{
                text = _("获取词库信息…"),
                timeout = 2,
            })
        elseif stage == "assemble" then
            closeDialog()
            UIManager:show(InfoMessage:new{
                text = _("解压校验词库…"),
                timeout = 2,
            })
        end
    end)
end

local function languageRows(desktop)
    local Language = require("ui/language")
    local lang = G_reader_settings:readSetting("language") or "C"
    return {
        function(iw)
            return SettingRow.build(iw, {
                kind = "nav",
                icon = "language",
                title = _("语言"),
                status = Language:getLanguageName(lang),
                status_on = true,
                callback = pickLanguage,
            })
        end,
        function(iw)
            return SettingRow.build(iw, {
                kind = "toggle",
                icon = "translate",
                title = _("中文键盘"),
                status = Pinyin.isEnabled() and _("开") or _("关"),
                status_on = Pinyin.isEnabled(),
                callback = function()
                    local on = Pinyin.setEnabled(not Pinyin.isEnabled())
                    UIManager:show(InfoMessage:new{
                        text = on and _("中文键盘已启用，点键盘上的 🌐 键切换中英文")
                            or _("中文键盘已停用"),
                        timeout = 3,
                    })
                    desktop:rebuild()
                end,
            })
        end,
        function(iw)
            return SettingRow.build(iw, {
                kind = "nav",
                icon = "spellcheck",
                title = _("拼音词库"),
                status = Pinyin.dictStatus(),
                status_on = require("pinyin.dictionary").isAvailable(),
                callback = function()
                    downloadPinyin(desktop)
                end,
            })
        end,
    }
end

local function cacheRow(desktop)
    return function(iw)
            local cache_size = desktop._cache_size_label or _("计算中…")
            -- 扫完就置 label；只认 job 会让回调里的 rebuild 再次开扫，死循环
            if desktop._cache_size_label == nil and not desktop._cache_size_job then
                desktop._cache_size_job = Cache.sizeLabelAsync(function(label)
                    desktop._cache_size_job = nil
                    if desktop._closed then
                        return
                    end
                    desktop._cache_size_label = label
                    if desktop.tab == "settings" then
                        desktop:rebuild()
                    end
                end)
            end
            return SettingRow.build(iw, {
                kind = "action",
                icon = "delete",
                title = _("清理缓存"),
                status = cache_size,
                status_on = true,
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = T(_("删除 .moon/cache（%1）？"), cache_size),
                        ok_text = _("清理"),
                        ok_callback = function()
                            if desktop._cache_clear_job then
                                return
                            end
                            UIManager:show(InfoMessage:new{
                                text = _("正在清理缓存…"),
                                timeout = 1,
                            })
                            desktop._cache_clear_job = Cache.clearAsync(function(ok)
                                desktop._cache_clear_job = nil
                                if desktop._closed then
                                    return
                                end
                                if ok then
                                    desktop._cache_size_label = "0"
                                    desktop._home_state = nil
                                    desktop._home_loaded = false
                                    desktop._library_state = nil
                                    desktop:rebuild()
                                end
                                UIManager:show(InfoMessage:new{
                                    text = ok and _("已清理") or _("清理失败"),
                                    timeout = 2,
                                })
                            end)
                        end,
                    })
                end,
            })
        end
end

local function aboutRow()
    return function(iw)
            return SettingRow.build(iw, {
                kind = "nav",
                icon = "info",
                title = _("关于"),
                status = pluginVersion(),
                status_on = true,
                callback = showAbout,
            })
        end
end

local function closeRow(desktop)
    return function(iw)
            return SettingRow.build(iw, {
                kind = "action",
                icon = "close",
                title = _("关闭桌面"),
                callback = function()
                    desktop:onClose()
                end,
            })
        end
end

local function updateRow()
    return function(iw)
        return SettingRow.build(iw, {
            kind = "action",
            icon = "system_update",
            title = _("检查更新"),
            status = pluginVersion(),
            status_on = true,
            callback = function()
                local url = REPO_URL .. "/releases/latest"
                if Device:canOpenLink() then
                    Device:openLink(url)
                else
                    UIManager:show(InfoMessage:new{ text = url })
                end
            end,
        })
    end
end

--- 构建设置页（十项主菜单 + 六个分类子页，分页）。
---@param desktop table
---@return table
function Settings.build(desktop)
    local h = desktop:contentHeight()
    local w = desktop.dimen.w
    local plugin = desktop.plugin
    local open_on = G_reader_settings:readSetting("start_with") == Host.OPEN_ON_START_ID
    local scale = UI.getScale()
    local grid_max_cols = UI.getGridMaxCols()
    local font_name = MoonFont.currentName()
    local page_pad = UI.pagePad()
    local card_w = math.max(UI.sz(100), w - page_pad * 2)
    local band_h = Pager.bandH()
    local body_h = math.max(1, h - band_h)

    local active_id = MoonSettings.activeSourceId()
    local active_name = active_id
    for _, meta in ipairs(SourceRegistry.list()) do
        if meta.id == active_id then
            active_name = meta.name or meta.id
            break
        end
    end

    local packed = {}
    local sub = desktop._settings_sub
    local valid_sub = {
        sources = true,
        display = true,
        lockscreen = true,
        desktop = true,
        language = true,
        remote = true,
    }
    if sub ~= nil and not valid_sub[sub] then
        -- 未知子页（状态损坏）：归一化回主菜单
        sub = nil
        desktop._settings_sub = nil
    end
    if sub == nil then
        appendRowList(packed, card_w, {
            function(iw)
                return SettingRow.build(iw, {
                    kind = "nav",
                    icon = "source",
                    title = _("数据源"),
                    status = active_name,
                    status_on = true,
                    callback = function()
                        gotoSub(desktop, "sources")
                    end,
                })
            end,
            function(iw)
                return SettingRow.build(iw, {
                    kind = "nav",
                    icon = "display_settings",
                    title = _("显示"),
                    status = string.format("%d%%", scale),
                    status_on = true,
                    callback = function()
                        gotoSub(desktop, "display")
                    end,
                })
            end,
            function(iw)
                return SettingRow.build(iw, {
                    kind = "nav",
                    icon = "wallpaper",
                    title = _("锁屏"),
                    status = LockScreen.label(LockScreen.mode()),
                    status_on = LockScreen.mode() ~= "ko",
                    callback = function()
                        gotoSub(desktop, "lockscreen")
                    end,
                })
            end,
            function(iw)
                return SettingRow.build(iw, {
                    kind = "nav",
                    icon = "desktop_windows",
                    title = _("桌面"),
                    status = open_on and _("开") or _("关"),
                    status_on = open_on,
                    callback = function()
                        gotoSub(desktop, "desktop")
                    end,
                })
            end,
            function(iw)
                return SettingRow.build(iw, {
                    kind = "nav",
                    icon = "language",
                    title = _("语言与输入"),
                    status = require("ui/language"):getLanguageName(
                        G_reader_settings:readSetting("language") or "C"),
                    status_on = true,
                    callback = function()
                        gotoSub(desktop, "language")
                    end,
                })
            end,
            function(iw)
                return SettingRow.build(iw, {
                    kind = "nav",
                    icon = "folder",
                    title = _("远程管理"),
                    status = Remote.isRunning() and _("运行中") or nil,
                    status_on = Remote.isRunning(),
                    callback = function()
                        gotoSub(desktop, "remote")
                    end,
                })
            end,
            cacheRow(desktop),
            aboutRow(),
            closeRow(desktop),
            updateRow(),
        })
    else
        table.insert(packed, backRow(desktop)(card_w))
        if sub == "sources" then
            for _, section in ipairs(sourceSections(desktop, plugin, active_id, active_name)) do
                appendSection(packed, card_w, section.title, section.rows)
            end
        elseif sub == "display" then
            appendSection(packed, card_w, _("显示"),
                displayRows(desktop, font_name, scale, grid_max_cols))
        elseif sub == "lockscreen" then
            appendSection(packed, card_w, _("锁屏"), lockscreenRows(desktop))
        elseif sub == "desktop" then
            appendSection(packed, card_w, _("桌面"), desktopRows(desktop, open_on))
        elseif sub == "language" then
            appendSection(packed, card_w, _("语言与输入"), languageRows(desktop))
        elseif sub == "remote" then
            appendSection(packed, card_w, _("远程管理"), Remote.menuRows(desktop))
        end
    end

    local pages_kids = Pager.pack(packed, body_h)
    local pages = #pages_kids
    local page = Pager.clamp(desktop._settings_page, pages)
    desktop._settings_page = page

    local page_body = FrameContainer:new{
        bordersize = 0,
        padding = page_pad,
        padding_bottom = UI.sz(4),
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = body_h },
        VerticalGroup:new(pages_kids[page]),
    }

    return (select(1, Pager.frame(w, h, {
        body = page_body,
        page = page,
        pages = pages,
        handlers = {
            on_prev = function()
                desktop._settings_page = page - 1
                desktop:rebuild()
            end,
            on_next = function()
                desktop._settings_page = page + 1
                desktop:rebuild()
            end,
            on_first = function()
                desktop._settings_page = 1
                desktop:rebuild()
            end,
            on_last = function()
                desktop._settings_page = pages
                desktop:rebuild()
            end,
        },
    })))
end

return Settings
