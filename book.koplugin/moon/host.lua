--[[--
KOReader 宿主钩子：启动项菜单 + 桌面接管。

对外：
  attach(plugin)         — init
  onShow(plugin)         — FM 显示且 want 则开桌面
  requestDesktop(plugin) — 要开桌面（能开就开，否则 want=true）

状态只要 want：nil 未见过 FM / true 待开 / false 不自动开

菜单挂钩：
  pinSettingsMenu     — 设置里「Book 桌面」置顶
  patchStartWithMenu  — 系统启动项插入 Book 书库

@module koplugin.book.moon.host
--]]

local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Host = {}

Host.OPEN_ON_START_ID = "bookshelf_book"

local MENU_ITEM_ID = "book_library"
local want = nil

local function isFileManager(plugin)
    return plugin and plugin.ui and not plugin.ui.document
end

local function isOpenOnStart()
    return G_reader_settings:readSetting("start_with", "filemanager") == Host.OPEN_ON_START_ID
end

local function openNow(plugin)
    if not isFileManager(plugin) or not plugin.openDesktop or plugin.desktop then
        return false
    end
    want = false
    plugin:openDesktop()
    return true
end

-- 设置菜单里把「Book 桌面」置顶（只做一次）
local function pinSettingsMenu()
    for _, modname in ipairs({
        "ui/elements/filemanager_menu_order",
        "ui/elements/reader_menu_order",
    }) do
        local ok, order = pcall(require, modname)
        if ok and type(order) == "table" and type(order.setting) == "table"
            and order.setting[1] ~= MENU_ITEM_ID then
            for i = #order.setting, 1, -1 do
                if order.setting[i] == MENU_ITEM_ID then
                    table.remove(order.setting, i)
                end
            end
            table.insert(order.setting, 1, MENU_ITEM_ID)
        end
    end
end

-- 系统「启动时打开」里插入 Book 书库（只补丁一次）
local function patchStartWithMenu()
    local ok, FMMenu = pcall(require, "apps/filemanager/filemanagermenu")
    if not ok or not FMMenu or not FMMenu.getStartWithMenuTable then
        return
    end
    if FMMenu._book_startwith_patched then
        return
    end
    FMMenu._book_startwith_patched = true

    local orig = FMMenu.getStartWithMenuTable
    FMMenu.getStartWithMenuTable = function(self)
        local item = orig(self)
        if not (item and item.sub_item_table) then
            return item
        end
        for _, row in ipairs(item.sub_item_table) do
            if row._book_item then
                return item
            end
        end
        table.insert(item.sub_item_table, 1, {
            _book_item = true,
            text = _("Book 书库"),
            checked_func = isOpenOnStart,
            callback = function()
                G_reader_settings:saveSetting("start_with", Host.OPEN_ON_START_ID)
            end,
            radio = true,
        })
        return item
    end
end

function Host.attach(plugin)
    pinSettingsMenu()
    patchStartWithMenu()
    if not isFileManager(plugin) then
        return
    end
    if want == nil then
        want = isOpenOnStart()
    end
    UIManager:nextTick(function()
        Host.onShow(plugin)
    end)
end

function Host.onShow(plugin)
    if want ~= true then
        return false
    end
    return openNow(plugin)
end

function Host.requestDesktop(plugin)
    if openNow(plugin) then
        return true
    end
    want = true
    return false
end

return Host
