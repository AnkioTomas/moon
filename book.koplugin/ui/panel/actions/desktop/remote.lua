--[[-- 远程管理快捷动作。
@module koplugin.book.ui.panel.actions.desktop.remote
--]]

local _ = require("gettext")

---@type BookQuickPanelAction
return {
    id = "remote",
    title = _("远程管理"),
    icon = "dns",
    scope = "desktop",
    keep_open = true,
    ---@return boolean
    active = function()
        return require("remote.init").isRunning()
    end,
    --- 切换远程管理服务，并给出启动地址或失败原因。
    ---@param _ctx BookQuickPanelContext|nil
    ---@return void
    run = function(_ctx)
        local Remote = require("remote.init")
        local UIManager = require("ui/uimanager")
        local InfoMessage = require("ui/widget/infomessage")
        local T = require("ffi/util").template
        if Remote.isRunning() then
            Remote.stop()
            UIManager:show(InfoMessage:new{ text = _("远程管理已关闭"), timeout = 2 })
            return
        end
        local ok, err = Remote.start()
        if not ok then
            UIManager:show(InfoMessage:new{ text = T(_("启动失败：%1"), tostring(err)), timeout = 3 })
            return
        end
        UIManager:show(InfoMessage:new{ text = T(_("服务已启动：%1"), Remote.status()), timeout = 4 })
    end,
}
