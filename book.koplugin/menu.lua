--[[--
KOReader 外壳接线：主菜单「月读」项、设置菜单置顶、系统「启动时打开」插入月读、「打开月读」手势、首装种启动项。

@module koplugin.book.menu
--]]

local Desktop = require("desktop")
local Settings = require("utils.settings")
local T = require("ffi/util").template
local _ = require("gettext")

local Menu = {}

local MENU_ITEM_ID = "book_library"

--- 设置菜单里把「月读」置顶。
local function pinSettingsMenu()
    for _idx, modname in ipairs({ "ui/elements/filemanager_menu_order", "ui/elements/reader_menu_order" }) do
        local order = require(modname).setting
        for i = #order, 1, -1 do
            if order[i] == MENU_ITEM_ID then table.remove(order, i) end
        end
        table.insert(order, 1, MENU_ITEM_ID)
    end
end

--- 系统「启动时打开」插入月读，并修补 text_func（否则选中后标题为 nil）。
local function patchStartWithMenu()
    local FMMenu = require("apps/filemanager/filemanagermenu")
    if FMMenu._book_startwith_patched then return end
    FMMenu._book_startwith_patched = true

    local book_label = _("月读")
    local orig = FMMenu.getStartWithMenuTable
    FMMenu.getStartWithMenuTable = function(menu)
        local item = orig(menu)
        table.insert(item.sub_item_table, 1, {
            text = book_label,
            checked_func = Settings.openOnStart,
            callback = function() Settings.setOpenOnStart(true) end,
            radio = true,
        })
        -- 原 text_func 只扫系统 id；选月读时对不上 → 返回 nil
        local orig_text_func = item.text_func
        item.text_func = function()
            if Settings.openOnStart() then
                return T(_("Start with: %1"), book_label)
            end
            return orig_text_func()
        end
        return item
    end
end

--- 首次安装（尚未种过）时强制启动项为月读，不跟系统默认 filemanager。
--- 只跑一次；之后设置里「启动打开桌面」或系统启动项由用户自己改。
local function seedStartWithOnInstall()
    if Settings.get().start_with_seeded then return end
    require("utils.log").info("book seed start_with on install")
    Settings.setOpenOnStart(true)
    Settings.save({ start_with_seeded = true })
end

--- 插件 onCreate：挂主菜单、置顶、修补启动项菜单、登记「打开月读」手势、首装种启动项
--- （FM / Reader 两个实例都会调，均幂等）。feature 的手势在各自 onCreate 里登记。
---@param plugin BookPlugin
function Menu.onCreate(plugin)
    plugin.ui.menu:registerToMainMenu(plugin)
    pinSettingsMenu()
    patchStartWithMenu()
    require("dispatcher"):registerAction("book_open_shelf", {
        category = "none",
        event = "BookOpenShelf",
        title = _("打开月读"),
        general = true,
        filemanager = true,
    })
    seedStartWithOnInstall()
end

--- KOReader 主菜单回调，签名同 `plugin:addToMainMenu(menu_items)`，由 main 直接挂到插件上。
---@param plugin BookPlugin
---@param menu_items table KOReader 主菜单项表（就地写入）
function Menu.addToMainMenu(plugin, menu_items)
    menu_items[MENU_ITEM_ID] = {
        text = _("月读"),
        sorting_hint = "setting",
        callback = function() Desktop.open(plugin) end,
    }
    if require("libs/libkoreader-lfs").attributes(plugin.path .. "/demo", "mode") == "directory" then
        require("demo").addToMainMenu(menu_items)
    end
end

return Menu
