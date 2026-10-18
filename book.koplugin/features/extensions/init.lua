--[[--
拓展：桌面底栏「拓展」格，点开贴在格子上方的弹层，列出其它 KOReader 插件的主菜单入口。

入口取自插件在文件管理器里的实例（`ui[插件名]`）：调它的 addToMainMenu 往空表里登记，
收集有文案、能点的项，id = `<插件名>:<菜单键>`（菜单键是插件自己定的稳定标识，可持久化）。
固定入口 `pinned`（最多 MAX_PINNED 个、受屏宽限制）会替换「拓展」格，每个一格，点一下直接执行。
显示哪些由设置 `shown[id]` 决定；没选过的按默认：第三方显示，KOReader 自带插件隐藏
（名单抄自 frontend/pluginloader.lua 的 BUILTIN_PLUGINS，那张表是局部变量，取不到）。

弹层是主题 List（遮罩、分页、贴着底栏格），直接承载原生菜单项表：子菜单在弹层里逐层进入（首行「返回」），
叶子项按 TouchMenu:onMenuSelect 的规则执行。原生菜单调回调时会把自己传进去，插件常调它的
closeMenu / updateItems / backToUpperMenu，这里传弹层自己的同名实现。不支持长按（hold_callback）与 tap_input。

@module koplugin.book.features.extensions
--]]

require("l10n").apply()

local MoonSettings = require("utils.settings")
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

local Extensions = {}

--- 把一个插件实例登记的主菜单项收进 out。
---@param name string 插件名
---@param inst table 插件实例
---@param out BookExtensionEntry[]
local function collect(name, inst, out)
    local items = {}
    inst:addToMainMenu(items)
    for key, item in pairs(items) do
        local text = item.text or (item.text_func and item.text_func())
        if text and (item.callback or item.sub_item_table or item.sub_item_table_func) then
            out[#out + 1] = { id = name .. ":" .. key, text = text, builtin = BUILTIN[name] == true, item = item }
        end
    end
end

--- 全部插件（不含本插件）的主菜单入口，第三方在前，各自按文案排序。
---@param plugin BookPlugin 文件管理器侧的本插件实例：插件实例挂在 plugin.ui 上，plugin.path 用来排除自己
---@return BookExtensionEntry[]
function Extensions.entries(plugin)
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

--- 入口是否显示在弹层里：开了固定模式后，固定的入口不进弹层（二选一）；否则用户选过以选择为准，第三方显示、自带隐藏。
---@param entry BookExtensionEntry
---@return boolean
function Extensions.isShown(entry)
    if Extensions.pinMode() and Extensions.isPinned(entry) then return false end
    local chosen = MoonSettings.get("features.extensions").shown[entry.id]
    if chosen == nil then return not entry.builtin end
    return chosen
end

--- 切换入口的显示并落盘。
---@param entry BookExtensionEntry
function Extensions.toggle(entry)
    local settings = MoonSettings.get("features.extensions")
    settings.shown[entry.id] = not Extensions.isShown(entry)
    MoonSettings.save("features.extensions")
end

--- 固定到底栏的入口最多几个（实际还受屏宽限制，见 Extensions.cells）。
Extensions.MAX_PINNED = 2

--- 固定模式：开了底栏只显示固定入口（替换「拓展」格），关了只有「拓展」格、固定设置不生效。
---@return boolean
function Extensions.pinMode()
    return MoonSettings.get("features.extensions").pin_mode == true
end

---@param id string
---@return integer|nil 在固定列表里的位置
local function pinnedIndex(id)
    for i, pin in ipairs(MoonSettings.get("features.extensions").pinned) do
        if pin.id == id then return i end
    end
end

---@param entry BookExtensionEntry
---@return boolean
function Extensions.isPinned(entry)
    return pinnedIndex(entry.id) ~= nil
end

--- 固定 / 取消固定入口并落盘；固定满了返回 false。
---@param entry BookExtensionEntry
---@return boolean ok
function Extensions.togglePin(entry)
    local settings = MoonSettings.get("features.extensions")
    local at = pinnedIndex(entry.id)
    if at then
        table.remove(settings.pinned, at)
    elseif #settings.pinned >= Extensions.MAX_PINNED then
        return false
    else
        settings.pinned[#settings.pinned + 1] = { id = entry.id, text = entry.text, icon = "extension" }
    end
    MoonSettings.save("features.extensions")
    return true
end

---@param entry BookExtensionEntry
---@return string 固定入口的图标名，未固定返回默认图标
function Extensions.pinIcon(entry)
    local at = pinnedIndex(entry.id)
    return at and MoonSettings.get("features.extensions").pinned[at].icon or "extension"
end

--- 给已固定的入口换底栏图标并落盘。
---@param entry BookExtensionEntry
---@param icon string
function Extensions.setPinIcon(entry, icon)
    local settings = MoonSettings.get("features.extensions")
    settings.pinned[pinnedIndex(entry.id)].icon = icon
    MoonSettings.save("features.extensions")
end

--- 底栏格：有固定入口时替换「拓展」格，每个固定入口一格（点一下直接执行）。
--- room = 屏宽还能多放几格；没开固定模式返回 nil（仍是「拓展」一格），开了但没固定入口则底栏不放格子。
---@param room integer
---@return { id: string, text: string, icon: string }[]|nil
function Extensions.cells(room)
    if not Extensions.pinMode() then return nil end
    local out = {}
    for i, pin in ipairs(MoonSettings.get("features.extensions").pinned) do
        if i > room + 1 then break end
        out[#out + 1] = { id = "extensions:" .. pin.id, text = pin.text, icon = pin.icon or "extension" }
    end
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
---@param anchor table {x,y,w,h}
local function popup(title, items, anchor)
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

--- 在锚点（底栏格）上方弹出入口列表。
---@param plugin BookPlugin
---@param anchor table 底栏格矩形 {x,y,w,h}
function Extensions.show(plugin, anchor)
    local items = {}
    for _idx, entry in ipairs(Extensions.entries(plugin)) do
        if Extensions.isShown(entry) then items[#items + 1] = entry.item end
    end
    if #items == 0 then
        items[1] = { text = _("没有可显示的入口，可在设置里选择") }
    end
    popup(_("拓展"), items, anchor)
end

--- 点固定格：子菜单入口弹层逐层进入，叶子入口直接执行；插件已卸载则退回完整弹层。
---@param plugin BookPlugin
---@param id string 入口 id
---@param anchor table
function Extensions.run(plugin, id, anchor)
    for _idx, entry in ipairs(Extensions.entries(plugin)) do
        if entry.id == id then
            local item = entry.item
            local sub = item.sub_item_table_func and item.sub_item_table_func() or item.sub_item_table
            if sub then return popup(entry.text, sub, anchor) end
            local menu = { closeMenu = function() end, updateItems = function() end, backToUpperMenu = function() end }
            local callback = item.callback_func and item.callback_func() or item.callback
            return callback(menu)
        end
    end
    Extensions.show(plugin, anchor)
end

-- 扩展点登记（features 加载器 require 本模块时执行一次；见 utils/extension.lua）。
require("utils.extension").add("desktop.tabs", {
    id = "extensions", text = _("拓展"), icon = "extension", after = "insight",
    enabled = function() return MoonSettings.get("features.extensions").enabled and true or false end,
    -- 不是页：点格子在上方弹出第三方插件入口。
    tap = function(desk, rect, cell_id)
        if cell_id then return Extensions.run(desk.plugin, cell_id:sub(#"extensions:" + 1), rect) end
        Extensions.show(desk.plugin, rect)
    end,
    cells = Extensions.cells,
})

return Extensions
