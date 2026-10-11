--[[--
远程管理设置页 UI。服务生命周期和文件 IO 保留在 features.remote。

@module koplugin.book.features.remote.ui
--]]

require("l10n").apply()

local _ = require("gettext")

local M = {}

---@param desktop table
---@return function[]
function M.menuRows(desktop)
    local Remote = require("features.remote")
    local Toast = require("ui.themes.widgets.toast")
    local Row = require("ui.themes.widgets.row")
    local T = require("ffi/util").template

    local function rebuild()
        if not desktop.closed then
            desktop:updateView()
        end
    end

    local rows = {}
    rows[#rows + 1] = function(iw)
        local status, running = Remote.status()
        return Row.widget({
    width = iw,
    chevron = false,
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
                    Toast:new{ text = T(_("启动失败：%1"), tostring(err)), timeout = 3 }:show()
                    rebuild()
                    return
                end
                Toast:new{ text = T(_("服务已启动：%1"), Remote.status()), timeout = 4 }:show()
                rebuild()
            end,
        })
    end

    rows[#rows + 1] = function(iw)
        return Row.widget({
    width = iw,
    chevron = true,
            kind = "nav", icon = "dns", title = _("端口"),
            status = tostring(Remote.port()), status_on = true,
            callback = function()
                require("ui.themes.widgets.input"):new{
                    title = _("端口"),
                    fields = { { text = tostring(Remote.port()), input_type = "number" } },
                    ok_text = _("保存"),
                    callback = function(text)
                        local port = tonumber(text)
                        if port and port >= 1 and port <= 65535 then
                            Remote.setPort(math.floor(port))
                            if Remote.isRunning() then
                                Remote.stop()
                                Remote.start()
                            end
                            rebuild()
                        end
                    end,
                }:show()
            end,
        })
    end

    rows[#rows + 1] = function(iw)
        local on = Remote.autostartOn()
        return Row.widget({
    width = iw,
    chevron = false,
            kind = "toggle", icon = "power", title = _("开机自启"),
            status = on and _("开") or _("关"), status_on = on,
            callback = function()
                Remote.setAutostart(not on)
                rebuild()
            end,
        })
    end

    rows[#rows + 1] = function(iw)
        local on = Remote.idleStopOn()
        return Row.widget({
    width = iw,
    chevron = false,
            kind = "toggle", icon = "schedule", title = _("空闲自动关闭"),
            status = on and _("开") or _("关"), status_on = on,
            callback = function()
                Remote.setIdleStop(not on)
                rebuild()
            end,
        })
    end
    return rows
end

return M
