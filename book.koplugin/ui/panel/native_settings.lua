--[[--
阅读页原生菜单设置项注入。

@module koplugin.book.ui.panel.native_settings
--]]

require("l10n").apply()

local UIManager = require("ui/uimanager")
local Menu = require("ui.panel.menu")
local _ = require("gettext")

---@class BookQuickPanelNativeSettings
---@field inject fun(menu: table): void

local NativeSettings = {}

--- 刷新阅读视图并在后台更新锁屏。
---@param ui table|nil
---@return nil
local function refreshReader(ui)
    if ui then UIManager:setDirty(ui.dialog, "ui") end
    require("lockscreen.init").refreshInBackground()
end

--- 写入并保存 Book 阅读显示设置，随后刷新阅读视图与菜单。
---@param ui table|nil
---@param key string
---@param value any
---@param menu table|nil
---@return nil
local function setDisplay(ui, key, value, menu)
    local MoonSettings = require("utils.settings")
    local settings = MoonSettings.get()
    settings[key] = value
    MoonSettings.save(settings)
    if key == "book_xray_show_marks" then
        require("xray.marks").invalidate()
    end
    require("ui.reader.bars").applyInsets(ui)
    if ui and ui.handleEvent then
        ui:handleEvent(require("ui/event"):new("UpdatePos"))
    end
    refreshReader(ui)
    Menu.refresh(menu)
end

--- 保存当前文档配置为默认并刷新。
---@param ui table|nil
---@param menu table|nil
---@return nil
local function saveDefault(ui, menu)
    Menu.close(menu)
    if ui and ui.menu and ui.menu.saveDocumentSettingsAsDefault then
        ui.menu:saveDocumentSettingsAsDefault()
    end
    require("utils.settings").save(require("utils.settings").get())
    UIManager:show(require("ui/widget/infomessage"):new{
        text = _("默认配置已保存"), timeout = 2,
    })
    refreshReader(ui)
end

--- 递归查找指定 id 的菜单项。
---@param items table[]|nil
---@param id string
---@return table|nil
local function findItem(items, id)
    for _i, item in ipairs(items or {}) do
        if type(item) == "table" then
            if item.id == id then return item end
            local children = item.sub_item_table or (#item > 0 and item or nil)
            local found = findItem(children, id)
            if found then return found end
        end
    end
end

--- 递归删除指定 id 的菜单项。
---@param items table[]|nil
---@param id string
---@return nil
local function removeItem(items, id)
    if type(items) ~= "table" then return end
    for i = #items, 1, -1 do
        local item = items[i]
        if type(item) == "table" and item.id == id then
            table.remove(items, i)
        elseif type(item) == "table" then
            removeItem(item.sub_item_table or (#item > 0 and item or nil), id)
        end
    end
end

--- KOReader 设置 Tab 是 tab_item_table 里的一项数组，不是 id=setting 的节点。
---@param menu table
---@return table|nil
local function settingTab(menu)
    for _, tab in ipairs(menu.tab_item_table or {}) do
        if type(tab) == "table" and findItem(tab, "night_mode") then
            return tab
        end
    end
    for _, tab in ipairs(menu.tab_item_table or {}) do
        if type(tab) == "table" and findItem(tab, "screen") then
            return tab
        end
    end
end

--- 生成一个切换 Book 阅读显示开关的菜单项。
---@param ui table|nil
---@param id string
---@param text string
---@param key string
---@return table
local function toggleItem(ui, id, text, key)
    return {
        id = id,
        text = text,
        checked_func = function()
            return require("utils.settings").get()[key] ~= false
        end,
        callback = function(menu)
            local settings = require("utils.settings").get()
            setDisplay(ui, key, settings[key] == false, menu)
        end,
        keep_menu_open = true,
    }
end

--- 生成 Book 阅读显示设置菜单项列表。
---@param ui table|nil
---@return table[]
local function settingsItems(ui)
    return {
        toggleItem(ui, "book_reader_top_status", _("顶部状态栏"), "book_reader_show_top_time"),
        toggleItem(ui, "book_reader_bottom_progress", _("底部进度栏"), "book_reader_show_bottom_progress"),
        toggleItem(ui, "book_xray_show_marks", _("页内实体标记"), "book_xray_show_marks"),
        {
            id = "book_reader_save_default",
            text = _("保存当前配置为默认配置"),
            separator = true,
            callback = function(menu) saveDefault(ui, menu) end,
        },
    }
end

--- 清理冲突的原生状态栏项，并把 Book 阅读显示设置注入设置 Tab。
---@param menu table
function NativeSettings.inject(menu)
    local tab = settingTab(menu)
    if not tab then return end
    removeItem(tab, "status_bar")
    local items = settingsItems(menu.ui)
    for i = #items, 1, -1 do
        local item = items[i]
        if not findItem(tab, item.id) then
            table.insert(tab, 1, item)
        end
    end
end

---@type BookQuickPanelNativeSettings
return NativeSettings
