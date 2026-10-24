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

-- KOReader start_with 取这个值即「启动打开月读」；已写进用户的 G_reader_settings，勿改。
local START_WITH = "bookshelf_book"

--- 月读是否为 KOReader 启动项。
---@return boolean
function Menu.openOnStart()
    return G_reader_settings:readSetting("start_with", "filemanager") == START_WITH
end

--- 设置 / 取消月读为 KOReader 启动项；取消即回到文件管理器。
---@param on boolean
function Menu.setOpenOnStart(on)
    G_reader_settings:saveSetting("start_with", on and START_WITH or "filemanager")
end

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
            checked_func = Menu.openOnStart,
            callback = function() Menu.setOpenOnStart(true) end,
            radio = true,
        })
        -- 原 text_func 只扫系统 id；选月读时对不上 → 返回 nil
        local orig_text_func = item.text_func
        item.text_func = function()
            if Menu.openOnStart() then
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
    if Settings.get("desktop").start_with_seeded then return end
    require("utils.log").info("book seed start_with on install")
    Menu.setOpenOnStart(true)
    Settings.get("desktop").start_with_seeded = true
    Settings.get("desktop").docs_prompt_pending = true
    Settings.save("desktop")
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
        callback = require("ui.guard").wrap("open desktop", function() Desktop.open(plugin) end),
    }
    if require("libs/libkoreader-lfs").attributes(plugin.path .. "/demo", "mode") == "directory" then
        require("demo").addToMainMenu(menu_items)
    end
end

return Menu
