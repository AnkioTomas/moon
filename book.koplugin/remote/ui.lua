--[[--
远程管理设置页 UI。服务生命周期和文件 IO 保留在 remote.init。

@module koplugin.book.remote.ui
--]]

require("l10n").apply()

local _ = require("gettext")

local M = {}

---@param desktop table
---@return function[]
function M.menuRows(desktop)
    local Remote = require("remote.init")
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local SettingRow = require("ui.components.settingrow")
    local T = require("ffi/util").template

    local function rebuild()
        if not desktop._closed then
            desktop:rebuild()
        end
    end

    local rows = {}
    rows[#rows + 1] = function(iw)
        local status, running = Remote.status()
        return SettingRow.build(iw, {
            kind = "toggle", icon = "folder", title = _("远程管理服务"),
            status = status, status_on = running,
            callback = function()
                if Remote.isRunning() then
                    Remote.stop()
                    rebuild()
                    return
                end
                local ok, err = Remote.start()
                if not ok then
                    UIManager:show(InfoMessage:new {
                        text = T(_("启动失败：%1"), tostring(err)), timeout = 3,
                    })
                    rebuild()
                    return
                end
                UIManager:show(InfoMessage:new {
                    text = T(_("服务已启动：%1"), Remote.status()), timeout = 4,
                })
                rebuild()
            end,
        })
    end

    rows[#rows + 1] = function(iw)
        return SettingRow.build(iw, {
            kind = "nav", icon = "dns", title = _("端口"),
            status = tostring(Remote.port()), status_on = true,
            callback = function()
                local InputDialog = require("ui/widget/inputdialog")
                local dialog
                dialog = InputDialog:new {
                    title = _("端口"), input = tostring(Remote.port()), input_type = "number",
                    buttons = { {
                        {
                            text = _("取消"), id = "close",
                            callback = function() UIManager:close(dialog) end,
                        },
                        {
                            text = _("保存"), is_enter_default = true,
                            callback = function()
                                local port = tonumber(dialog:getInputValue())
                                if port and port >= 1 and port <= 65535 then
                                    Remote.setPort(math.floor(port))
                                    if Remote.isRunning() then
                                        Remote.stop()
                                        Remote.start()
                                    end
                                    rebuild()
                                end
                                UIManager:close(dialog)
                            end,
                        },
                    } },
                }
                UIManager:show(dialog)
                dialog:onShowKeyboard()
            end,
        })
    end

    rows[#rows + 1] = function(iw)
        local on = Remote.autostartOn()
        return SettingRow.build(iw, {
            kind = "toggle", icon = "power", title = _("开机自启"),
            status = on and _("开") or _("关"), status_on = on,
            callback = function()
                Remote.setAutostart(not on)
                rebuild()
            end,
        })
    end
    return rows
end

return M
