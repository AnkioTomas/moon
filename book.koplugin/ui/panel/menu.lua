--[[-- 原生 TouchMenu 关闭与刷新。
@module koplugin.book.ui.panel.menu
--]]

---@class BookQuickPanelMenu
---@field close fun(menu: table|nil): void
---@field refresh fun(menu: table|nil): void

local Menu = {}

--- 关闭原生菜单。
---@param menu table|nil
function Menu.close(menu)
    if menu and menu.closeMenu then menu:closeMenu() end
end

--- 刷新原生菜单内容。
---@param menu table|nil
function Menu.refresh(menu)
    if menu and menu.updateItems then menu:updateItems(1) end
end

---@type BookQuickPanelMenu
return Menu
