--[[--
远程管理的桌面快捷面板开关。

@module koplugin.book.features.remote.panel
--]]

require("l10n").apply()

local _ = require("gettext")

local Panel = {}

---@type BookQuickPanelAction
local ACTION = {
    id = "remote",
    title = _("远程管理"),
    icon = "dns",
    scope = "desktop",
    keep_open = true,
    ---@return boolean
    active = function()
        return require("features.remote").isRunning()
    end,
    --- 切换远程管理服务，并给出启动地址或失败原因。
    ---@param _ctx BookQuickPanelContext|nil
    run = function(_ctx)
        local Remote = require("features.remote")
        local UIManager = require("ui/uimanager")
        local T = require("ffi/util").template
        if Remote.isRunning() then
            Remote.stop()
            require("ui.themes.widgets.toast"):new{ text = _("远程管理已关闭"), timeout = 2 }:show()
            return
        end
        local ok, err = Remote.start()
        if not ok then
            require("ui.themes.widgets.toast"):new{ text = T(_("启动失败：%1"), tostring(err)), timeout = 3 }:show()
            return
        end
        require("ui.themes.widgets.toast"):new{ text = T(_("服务已启动：%1"), Remote.status()), timeout = 4 }:show()
    end,
}

---@return BookQuickPanelAction[]
function Panel.actions()
    return { ACTION }
end

return Panel
