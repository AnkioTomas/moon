--[[--
远程管理设置入口。页内容仍由 features.remote.ui 画。

@module koplugin.book.features.remote.setting
--]]

local _ = require("gettext")

local Setting = {}

Setting.defaults = { remote_port = 9528, remote_autostart = false, remote_idle_stop = true }

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    local Remote = require("features.remote")
    local running = Remote.isRunning()
    return {
        {
            id = "main",
            group = "system",
            order = 110,
            icon = "dns",
            title = _("远程管理"),
            subtitle = _("浏览器管理文件、输入"),
            status = running and _("运行中") or nil,
            status_on = running,
            page = {
                title = _("远程管理"),
                sections = function()
                    return { { title = _("远程"), rows = require("features.remote.ui").menuRows(desktop) } }
                end,
            },
        },
    }
end

return Setting
