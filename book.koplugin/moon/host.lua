--[[--
KOReader 宿主钩子：启动项菜单 + 桌面接管。

对外：
  attach(plugin)         — init（菜单 + 启动项 + 可选自动开桌面）
  onShow(plugin)         — FM 显示且 want 则开桌面
  requestDesktop(plugin) — 要开桌面（能开就开，否则 want=true）

状态只要 want：nil 未见过 FM / true 待开 / false 不自动开

菜单挂钩：
  registerMenu        — Dispatcher 手势 + 主菜单入口
  pinSettingsMenu     — 设置里「Book 桌面」置顶
  patchStartWithMenu  — 系统启动项插入 Book 书库

@module koplugin.book.moon.host
--]]

local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Host = {}

--- G_reader_settings.start_with 的 Book 书库取值
Host.OPEN_ON_START_ID = "bookshelf_book"

local MENU_ITEM_ID = "book_library"
--- nil=未见过 FM；true=待开桌面；false=本次不自动开
local want = nil
local dispatcher_registered = false

--- 是否 FileManager 上下文（非 Reader）
local function isFileManager(plugin)
    return plugin and plugin.ui and not plugin.ui.document
end

--- 启动项是否选中 Book 书库
local function isOpenOnStart()
    return G_reader_settings:readSetting("start_with", "filemanager") == Host.OPEN_ON_START_ID
end

--- 立刻开桌面；成功则 want=false
-- @return boolean
local function openNow(plugin)
    if not isFileManager(plugin) or not plugin.openDesktop or plugin.desktop then
        logger.dbg("book.host openNow skip",
            isFileManager(plugin),
            plugin and plugin.desktop ~= nil)
        return false
    end
    want = false
    logger.info("book.host openDesktop")
    plugin:openDesktop()
    return true
end

--- Dispatcher 全局注册一次；主菜单按 FM/Reader 实例各挂一次
-- 回调仍走 plugin:addToMainMenu / plugin:onBookOpenShelf
local function registerMenu(plugin)
    if not dispatcher_registered then
        dispatcher_registered = true
        Dispatcher:registerAction("book_open_shelf", {
            category = "none",
            event = "BookOpenShelf",
            title = _("打开 Book 桌面"),
            general = true,
            filemanager = true,
        })
        logger.dbg("book.host dispatcher registered")
    end
    if plugin.ui and plugin.ui.menu and plugin.ui.menu.registerToMainMenu then
        plugin.ui.menu:registerToMainMenu(plugin)
        logger.dbg("book.host registerToMainMenu", isFileManager(plugin) and "fm" or "reader")
    end
end

--- 设置菜单里把「Book 桌面」置顶（只做一次）
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
            logger.dbg("book.host pinSettingsMenu", modname)
        end
    end
end

--- 系统「启动时打开」插入 Book 书库，并修补 text_func（否则选中后标题为 nil）
local function patchStartWithMenu()
    local ok, FMMenu = pcall(require, "apps/filemanager/filemanagermenu")
    if not ok or not FMMenu or not FMMenu.getStartWithMenuTable then
        logger.warn("book.host patchStartWithMenu unavailable")
        return
    end
    if FMMenu._book_startwith_patched then
        return
    end
    FMMenu._book_startwith_patched = true

    local book_label = _("Book 书库")
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
            text = book_label,
            checked_func = isOpenOnStart,
            callback = function()
                logger.info("book.host start_with", Host.OPEN_ON_START_ID)
                G_reader_settings:saveSetting("start_with", Host.OPEN_ON_START_ID)
            end,
            radio = true,
        })
        -- 原 text_func 只扫系统 id；选 Book 时对不上 → 返回 nil
        local orig_text_func = item.text_func
        item.text_func = function()
            if isOpenOnStart() then
                return T(_("Start with: %1"), book_label)
            end
            if orig_text_func then
                return orig_text_func()
            end
        end
        return item
    end
    logger.dbg("book.host patchStartWithMenu ok")
end

--- 插件 init：挂钩菜单；FM 侧按 start_with 决定是否自动开桌面
function Host.attach(plugin)
    pcall(function()
        require("moon.font").applyCurrent()
    end)
    registerMenu(plugin)
    pinSettingsMenu()
    patchStartWithMenu()
    if not isFileManager(plugin) then
        logger.dbg("book.host attach reader skip auto-open")
        return
    end
    if want == nil then
        want = isOpenOnStart()
        logger.dbg("book.host attach want", want)
    end
    UIManager:nextTick(function()
        Host.onShow(plugin)
    end)
end

--- FM onShow：want==true 时开桌面
-- @return boolean
function Host.onShow(plugin)
    if want ~= true then
        return false
    end
    logger.dbg("book.host onShow try open")
    return openNow(plugin)
end

--- 请求开桌面；当前开不了则标记 want，等下次 FM onShow
-- @return boolean 是否已打开
function Host.requestDesktop(plugin)
    if openNow(plugin) then
        return true
    end
    want = true
    logger.dbg("book.host requestDesktop deferred")
    return false
end

return Host
