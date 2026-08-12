--[[--
KOReader 宿主钩子：FileManager + 启动项 + 设置菜单置顶。

@module koplugin.book.moon.host
--]]

local UIManager = require("ui/uimanager")
local MoonSettings = require("moon.settings")
local _ = require("gettext")

local Host = {}

Host.OPEN_ON_START_ID = "bookshelf_book"

local MENU_ITEM_ID = "book_library"

-- ── 模块状态 ─────────────────────────────────────────
local _plugin = nil    -- install() 保存的插件引用
local _pending = false -- 待打开桌面标记

--- 消费 _pending：清标记，下一帧打开桌面。
local function consumePending()
    if not _pending then return end
    _pending = false
    UIManager:nextTick(function()
        local p = _plugin
        if not p or not p.openDesktop or p.desktop then return end
        local ok, FM = pcall(require, "apps/filemanager/filemanager")
        if (p.ui and p.ui.file_chooser) or (ok and FM and FM.instance) then
            p:openDesktop()
        end
    end)
end

--- 标记"FM 重建后打开桌面"，由 install → consumePending 消费。
function Host.scheduleDesktopOpen()
    _pending = true
end

-- ── 启动项 ───────────────────────────────────────────

--- 把插件「启动打开桌面」同步进 KOReader 的 start_with。
function Host.syncOpenOnStart()
    local s = MoonSettings.get()
    if s.open_on_start == false then return false end
    if G_reader_settings:readSetting("start_with") ~= Host.OPEN_ON_START_ID then
        G_reader_settings:saveSetting("start_with", Host.OPEN_ON_START_ID)
    end
    return true
end

function Host.isOpenOnStart()
    local s = MoonSettings.get()
    if s.open_on_start == false then return false end
    return G_reader_settings:readSetting("start_with", "filemanager") == Host.OPEN_ON_START_ID
end

-- ── 打开桌面 ─────────────────────────────────────────

function Host.openFromFileManager(fallback_plugin)
    local p = _plugin
    if p and p.openDesktop and not p.desktop then
        p:openDesktop()
        return true
    end
    -- _plugin 可能在 FM 重建后过期，尝试调用方传入的引用
    if fallback_plugin and fallback_plugin.openDesktop
        and fallback_plugin.ui and fallback_plugin.ui.file_chooser then
        fallback_plugin:openDesktop()
        return true
    end
    return false
end

-- ── FM onShow 钩子 ───────────────────────────────────

local function wrapOnShow(fm)
    if not fm or fm._book_onshow_wrapped then return end
    fm._book_onshow_wrapped = true
    local orig = fm.onShow
    fm.onShow = function(this)
        if orig then orig(this) end
        consumePending()
    end
end

-- ── FileManager 补丁 ────────────────────────────────

local function patchFileManager()
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok or not FileManager then return end

    if not FileManager._book_patched then
        FileManager._book_patched = true

        local orig_setup = FileManager.setupLayout
        FileManager.setupLayout = function(fm_self)
            orig_setup(fm_self)
            wrapOnShow(fm_self)
        end

        if FileManager.getPlusDialogButtons then
            local orig_plus = FileManager.getPlusDialogButtons
            FileManager.getPlusDialogButtons = function(fm)
                local title, buttons = orig_plus(fm)
                table.insert(buttons, 1, {{
                    text = _("Book 桌面"),
                    callback = function()
                        UIManager:close(fm.plus_dialog)
                        if _plugin and _plugin.openDesktop then
                            _plugin:openDesktop()
                        end
                    end,
                }})
                return title, buttons
            end
        end
    end

    wrapOnShow(FileManager.instance)

    -- 首次启动且配置为 Book 启动项
    if not FileManager._book_boot_done then
        FileManager._book_boot_done = true
        if Host.isOpenOnStart() then
            _pending = true
        end
    end

    consumePending()
end

-- ── 启动项菜单补丁 ──────────────────────────────────

local function patchStartWithMenu()
    local ok, FMMenu = pcall(require, "apps/filemanager/filemanagermenu")
    if not ok or not FMMenu or not FMMenu.getStartWithMenuTable then return end
    if FMMenu._book_startwith_patched then return end
    FMMenu._book_startwith_patched = true

    local orig = FMMenu.getStartWithMenuTable
    FMMenu.getStartWithMenuTable = function(self)
        local item = orig(self)
        if not (item and item.sub_item_table) then return item end

        -- 菜单表可能被缓存，检查是否已插入
        for _, row in ipairs(item.sub_item_table) do
            if row._book_item then return item end
        end

        table.insert(item.sub_item_table, 1, {
            _book_item = true,
            text = _("Book 书库"),
            checked_func = function()
                return G_reader_settings:readSetting("start_with") == Host.OPEN_ON_START_ID
            end,
            callback = function()
                G_reader_settings:saveSetting("start_with", Host.OPEN_ON_START_ID)
                local s = MoonSettings.get()
                s.open_on_start = true
                MoonSettings.save(s)
            end,
            radio = true,
        })

        -- 其他启动项被选中时，关闭 Book 自动启动
        for _, row in ipairs(item.sub_item_table) do
            if not row._book_item and row.callback and not row._book_wrapped then
                row._book_wrapped = true
                local prev = row.callback
                row.callback = function(...)
                    local s = MoonSettings.get()
                    s.open_on_start = false
                    MoonSettings.save(s)
                    return prev(...)
                end
            end
        end

        return item
    end
end

-- ── 菜单置顶 ────────────────────────────────────────

local function pinBookInSettingsMenu()
    for _, modname in ipairs({
        "ui/elements/filemanager_menu_order",
        "ui/elements/reader_menu_order",
    }) do
        local ok, order = pcall(require, modname)
        if ok and type(order) == "table" and type(order.setting) == "table" then
            for i = #order.setting, 1, -1 do
                if order.setting[i] == MENU_ITEM_ID then
                    table.remove(order.setting, i)
                end
            end
            table.insert(order.setting, 1, MENU_ITEM_ID)
        end
    end
end

-- ── 安装 ─────────────────────────────────────────────

function Host.install(plugin)
    _plugin = plugin
    pinBookInSettingsMenu()
    patchFileManager()
    patchStartWithMenu()
    consumePending()
end

return Host
