--[[-- 阅读方向快捷动作。
@module koplugin.book.ui.panel.actions.reader.direction
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local DIRECTIONS = {
    { value = 0, title = _("横排（从左到右）") },
    { value = 1, title = _("横排（从右到左）") },
    { value = 2, title = _("竖排（从右到左、从上到下）") },
}

---@param ui table|nil
---@return boolean
local function available(ui)
    if ui == nil then return true end
    return ui.document ~= nil
        and ui.document.configurable ~= nil
        and ui.document.configurable.text_wrap == 1
end

---@param ui table
local function showMenu(ui)
    local current = ui.document.configurable.writing_direction or 0
    local dialog
    local buttons = {}
    for _, direction in ipairs(DIRECTIONS) do
        buttons[#buttons + 1] = {
            text = (direction.value == current and "✓ " or "") .. direction.title,
            callback = function()
                UIManager:close(dialog)
                if direction.value ~= current then
                    ui:handleEvent(Event:new("ConfigChange", "writing_direction", direction.value))
                end
            end,
        }
    end
    buttons[#buttons + 1] = {
        text = _("取消"),
        callback = function() UIManager:close(dialog) end,
    }
    dialog = ButtonDialog:new{
        title = _("阅读方向"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

---@type BookQuickPanelAction
return {
    id = "direction",
    title = _("阅读方向"),
    icon = "article",
    scope = "reader",
    keep_open = true,
    available = function(ctx)
        return available(ctx and ctx.ui)
    end,
    active = function(ctx)
        return (ctx.ui.document.configurable.writing_direction or 0) == 2
    end,
    run = function(ctx)
        showMenu(ctx.ui)
    end,
}
