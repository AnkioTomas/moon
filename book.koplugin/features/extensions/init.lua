--[[--
桌面底栏拓展入口：显示选择、固定入口与图标；原生插件菜单交给 ui.plugin_menu。

@module koplugin.book.features.extensions
--]]

require("l10n").apply()

local MoonSettings = require("utils.settings")
local Menu = require("ui.plugin_menu")
local _ = require("gettext")

local Extensions = { MAX_PINNED = 2, entries = Menu.entries }

---@return boolean
function Extensions.pinMode()
    return MoonSettings.get("features.extensions").pin_mode == true
end

---@param id string
---@return integer|nil
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

---@param entry BookExtensionEntry
---@return boolean
function Extensions.isShown(entry)
    if Extensions.pinMode() and Extensions.isPinned(entry) then return false end
    local chosen = MoonSettings.get("features.extensions").shown[entry.id]
    if chosen == nil then return not entry.builtin end
    return chosen
end

---@param entry BookExtensionEntry
function Extensions.toggle(entry)
    local settings = MoonSettings.get("features.extensions")
    settings.shown[entry.id] = not Extensions.isShown(entry)
    MoonSettings.save("features.extensions")
end

---@param entry BookExtensionEntry
---@param limit integer|nil
---@return boolean
function Extensions.togglePin(entry, limit)
    local settings = MoonSettings.get("features.extensions")
    local at = pinnedIndex(entry.id)
    if at then
        table.remove(settings.pinned, at)
    elseif #settings.pinned >= math.min(Extensions.MAX_PINNED, limit or Extensions.MAX_PINNED) then
        return false
    else
        settings.pinned[#settings.pinned + 1] = { id = entry.id, text = entry.text, icon = "extension" }
    end
    MoonSettings.save("features.extensions")
    return true
end

---@param entry BookExtensionEntry
---@return string
function Extensions.pinIcon(entry)
    local at = pinnedIndex(entry.id)
    return at and MoonSettings.get("features.extensions").pinned[at].icon or "extension"
end

---@param entry BookExtensionEntry
---@param icon string
function Extensions.setPinIcon(entry, icon)
    local settings = MoonSettings.get("features.extensions")
    settings.pinned[pinnedIndex(entry.id)].icon = icon
    MoonSettings.save("features.extensions")
end

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

---@param plugin BookPlugin
---@param anchor table
function Extensions.show(plugin, anchor)
    local items = {}
    for _idx, entry in ipairs(Extensions.entries(plugin)) do
        if Extensions.isShown(entry) then items[#items + 1] = entry.item end
    end
    if #items == 0 then items[1] = { text = _("没有可显示的入口，可在设置里选择") } end
    Menu.show(_("拓展"), items, anchor)
end

---@param plugin BookPlugin
---@param id string
---@param anchor table
function Extensions.run(plugin, id, anchor)
    if not Menu.run(plugin, id, anchor) then Extensions.show(plugin, anchor) end
end

require("utils.extension").add("desktop.tabs", {
    id = "extensions", text = _("拓展"), icon = "extension", after = "insight",
    enabled = function() return MoonSettings.get("features.extensions").enabled and true or false end,
    tap = function(desk, rect, cell_id)
        if cell_id then return Extensions.run(desk.plugin, cell_id:sub(#"extensions:" + 1), rect) end
        Extensions.show(desk.plugin, rect)
    end,
    cells = Extensions.cells,
})

return Extensions
