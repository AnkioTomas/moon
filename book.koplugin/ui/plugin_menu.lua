--[[--
KOReader 插件主菜单入口：收集、分页展示与执行，供底栏与快捷面板共用。

入口取自插件在文件管理器里的实例（`ui[插件名]`）：调它的 addToMainMenu 往空表里登记，
收集有文案、能点的项，id = `<插件名>:<菜单键>`（菜单键是插件自己定的稳定标识，可持久化）。
自带插件名单抄自 frontend/pluginloader.lua 的 BUILTIN_PLUGINS（局部变量，取不到）。

弹层是主题 List（遮罩、分页、贴着底栏格），直接承载原生菜单项表：子菜单在弹层里逐层进入（首行「返回」），
叶子项按 TouchMenu:onMenuSelect 的规则执行。原生菜单调回调时会把自己传进去，插件常调它的
closeMenu / updateItems / backToUpperMenu，这里传弹层自己的同名实现。不支持长按（hold_callback）与 tap_input。

@module koplugin.book.ui.plugin_menu
--]]

require("l10n").apply()

local logger = require("utils.log")
local _ = require("gettext")

local BUILTIN = {
    archiveviewer = true, autodim = true, autostandby = true, autosuspend = true, autoturn = true,
    autowarmth = true, batterystat = true, bookshortcuts = true, calibre = true, cloudstorage = true,
    coverbrowser = true, coverimage = true, docsettingtweak = true, exporter = true,
    externalkeyboard = true, gestures = true, hello = true, hotkeys = true, httpinspector = true,
    japanese = true, keepalive = true, kosync = true, movetoarchive = true, newsdownloader = true,
    opds = true, perceptionexpander = true, profiles = true, qrclipboard = true, readtimer = true,
    SSH = true, statistics = true, systemstat = true, terminal = true, texteditor = true,
    timesync = true, vocabbuilder = true, wallabag = true,
}

---@class BookExtensionEntry
---@field id string `<插件名>:<菜单键>`
---@field text string
---@field builtin boolean KOReader 自带插件
---@field item table 插件登记的原生菜单项

local Menu = {}

--- 把一个插件实例登记的主菜单项收进 out。
---@param name string 插件名
---@param inst table 插件实例
---@param out BookExtensionEntry[]
local function collect(name, inst, out)
    local items = {}
    inst:addToMainMenu(items)
    for key, item in pairs(items) do
        local text = item.text or (item.text_func and item.text_func())
        if text and (item.callback or item.callback_func or item.sub_item_table or item.sub_item_table_func) then
            out[#out + 1] = { id = name .. ":" .. key, text = text, builtin = BUILTIN[name] == true, item = item }
        end
    end
end

--- 全部插件（不含本插件）的主菜单入口，第三方在前，各自按文案排序。
---@param plugin BookPlugin 文件管理器侧的本插件实例：插件实例挂在 plugin.ui 上，plugin.path 用来排除自己
---@return BookExtensionEntry[]
function Menu.entries(plugin)
    local out = {}
    for _idx, module in ipairs(require("pluginloader"):loadPlugins()) do
        local inst = plugin.ui[module.name]
        if inst and inst.addToMainMenu and module.path ~= plugin.path then
            -- 第三方代码：坏插件只跳过自己，同 KOReader 建主菜单时的处理。
            local ok, err = pcall(collect, module.name, inst, out)
            if not ok then logger.warn("extensions menu", module.name, err) end
        end
    end
    table.sort(out, function(a, b)
        if a.builtin ~= b.builtin then return b.builtin end
        return a.text < b.text
    end)
    return out
end

--- 原生菜单项的勾选标记；不是勾选项返回 nil。
---@param item table
---@return string|nil
local function markIcon(item)
    if not item.checked_func and item.checked == nil then return nil end
    local on = item.checked_func and item.checked_func() or item.checked
    if item.radio then return on and "radio_button_checked" or "radio_button_unchecked" end
    return on and "check_box" or "check_box_outline_blank"
end

--- 在锚点（底栏格）旁弹出主题列表，承载原生菜单项表：子菜单逐层进入，
--- 执行规则同 TouchMenu:onMenuSelect，回调拿到的 touchmenu_instance 是本弹层（closeMenu / updateItems / backToUpperMenu）。
---@param title string
---@param items table[] 原生菜单项（addToMainMenu / sub_item_table 的格式）
---@param anchor table|nil {x,y,w,h}；nil 时居中
function Menu.show(title, items, anchor)
    local Theme = require("ui.themes")
    local stack = { { title = title, items = items } }
    local list, closed
    local menu = {}
    local rows

    local function render()
        if closed then return end
        local level = stack[#stack]
        list.title = level.title
        list:setItems(rows(level.items))
    end

    function menu:closeMenu()
        if not closed then list:close() end
    end

    function menu:updateItems()
        render()
    end

    function menu:backToUpperMenu()
        if #stack == 1 then return self:closeMenu() end
        table.remove(stack)
        list.page = 1
        render()
    end

    local function select(item, text)
        local sub = item.sub_item_table_func and item.sub_item_table_func() or item.sub_item_table
        if sub then
            if #sub > 0 then
                stack[#stack + 1] = { title = text, items = sub }
                list.page = 1
                render()
            end
            return
        end
        local callback = item.callback_func and item.callback_func() or item.callback
        if not callback then return end
        callback(menu)
        if item.checked or item.checked_func then
            if not (item.check_callback_updates_menu or item.check_callback_closes_menu) then render() end
        elseif not item.keep_menu_open then
            menu:closeMenu()
        end
    end

    rows = function(native)
        local out = {}
        if #stack > 1 then
            out[1] = { text = _("返回"), icon = "arrow_back", keep_open = true,
                callback = function() menu:backToUpperMenu() end }
        end
        for _idx, item in ipairs(native) do
            local text = item.text or (item.text_func and item.text_func())
            if text then
                local sub = item.sub_item_table or item.sub_item_table_func
                local actionable = (sub or item.callback or item.callback_func) ~= nil
                out[#out + 1] = {
                    text = text,
                    icon = markIcon(item),
                    mandatory = item.mandatory or (item.mandatory_func and item.mandatory_func()),
                    chevron = sub ~= nil,
                    enabled = actionable and item.enabled ~= false and (not item.enabled_func or item.enabled_func()),
                    keep_open = true,
                    callback = function() select(item, text) end,
                }
            end
        end
        return out
    end

    list = require("ui.themes.widgets.list"):new{
        title = title,
        items = rows(items),
        centered = true,
        anchor = anchor,
        inner_width = Theme.px(240),
        close_callback = function() closed = true end,
    }
    list:show()
end

--- 子菜单逐层进入，叶子入口直接执行；已卸载 / 当前不可用返回 false。
---@param plugin BookPlugin
---@param id string 入口 id
---@param anchor table|nil
---@return boolean
function Menu.run(plugin, id, anchor)
    for _idx, entry in ipairs(Menu.entries(plugin)) do
        if entry.id == id then
            local item = entry.item
            if item.enabled == false or item.enabled_func and not item.enabled_func() then return false end
            local sub = item.sub_item_table_func and item.sub_item_table_func() or item.sub_item_table
            if sub then
                Menu.show(entry.text, sub, anchor)
                return true
            end
            local menu = { closeMenu = function() end, updateItems = function() end, backToUpperMenu = function() end }
            local callback = item.callback_func and item.callback_func() or item.callback
            if not callback then return false end
            callback(menu)
            return true
        end
    end
    return false
end

return Menu
