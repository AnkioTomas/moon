--[[--
退出兜底：关掉 KOReader 窗口栈上残留的月读窗口（book_window 标记：桌面、Modal 系弹窗）。

普通「退出」要等窗口栈清空才收尾（UIManager:_gated_quit），任何残留窗口都会让
KOReader 假死、只能强制重启；「重启」走 quit(85) 直接清栈，不受影响。
由 BookPlugin:onExit 在各 feature 收尾后调用；正常情况下桌面已自行关窗，这里不做任何事。

@module koplugin.book.ui.exit_windows
--]]

local logger = require("utils.log")

local M = {}

--- 关闭残留的月读窗口
---@return integer 关掉的窗口数
function M.close()
    local UIManager = require("ui/uimanager")
    local stack = UIManager._window_stack or {}
    local leftovers = {}
    for i = #stack, 1, -1 do
        local w = stack[i] and stack[i].widget
        if type(w) == "table" and w.book_window then
            leftovers[#leftovers + 1] = w
        end
    end
    for _idx, w in ipairs(leftovers) do
        if w.name == "book_desktop" and w.onExit then
            w:onExit()
        else
            UIManager:close(w)
        end
    end
    if #leftovers > 0 then
        logger.warn("book exit closed leftover windows", #leftovers)
    end
    return #leftovers
end

return M
