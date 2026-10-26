--[[-- 后台任务快捷动作：打开后台任务列表。
@module koplugin.book.features.panel.actions.desktop.tasks
--]]

local _ = require("gettext")

---@type BookQuickPanelAction
return {
    id = "tasks",
    title = _("后台任务"),
    icon = "download",
    scope = "desktop",
    --- 有未结束任务时高亮，点开前先有个信号。
    ---@return boolean
    active = function()
        return #require("workers.tasks").tasks() > 0
    end,
    run = function()
        require("workers.ui.task_dialog"):new{}:show()
    end,
}
