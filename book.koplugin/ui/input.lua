--[[-- 窗口输入归属：只允许最上层非提示窗口及其子控件响应用户输入。
@module koplugin.book.ui.input
--]]

local UIManager = require("ui/uimanager")
local Settings = require("utils.settings")
local Input = {}

--- 只有越过边界才循环；页数尚不完整时 cycle=false，保留向前加载语义。
---@param page integer
---@param pages integer
---@param cycle boolean|nil
---@return integer
function Input.page(page, pages, cycle)
    pages = math.max(1, pages)
    if cycle ~= false and Settings.get("ui").pager_cycle and pages > 1 then
        return (page - 1) % pages + 1
    end
    return math.max(1, math.min(pages, page))
end

---@param widget table
---@return boolean
function Input.isTop(widget)
    for i = #UIManager._window_stack, 1, -1 do
        local top = UIManager._window_stack[i].widget
        if not top.toast then
            -- 虚拟键盘独立上屏，未消费的输入仍需交给它所属的输入弹窗。
            if top.inputbox and top.inputbox.keyboard == top and top.inputbox.parent == widget then
                return true
            end
            if top == widget then return true end
            if widget.book_window and not widget.show_parent then return false end
            local shown, _depth, window = UIManager:isSubwidgetShown(widget)
            return shown and window == top or false
        end
    end
    return false
end

return Input
