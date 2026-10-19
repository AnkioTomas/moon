--[[--
远程管理设置入口与设置页。服务生命周期和文件 IO 在 features.remote。

@module koplugin.book.features.remote.setting
--]]

local _ = require("gettext")

local Setting = {}

Setting.defaults = { remote_port = 9528, remote_autostart = false, remote_idle_stop = true, remote_delete_after_share = false }

---@param desktop BookDesktop
---@return function[]
local function rows(desktop)
    local Remote = require("features.remote")
    local Toast = require("ui.themes.widgets.toast")
    local Row = require("ui.themes.widgets.row")
    local T = require("ffi/util").template

    local function rebuild()
        if not desktop.closed then
            desktop:updateView()
        end
    end

    --- 起服并提示结果（失败给原因，成功给访问地址）。
    local function start()
        require("ui/network/manager"):runWhenConnected(function()
            local ok, err = Remote.start()
            if ok then
                Toast:new{ text = T(_("服务已启动：%1"), Remote.status()), timeout = 4 }:show()
            else
                Toast:new{ text = T(_("启动失败：%1"), tostring(err)), timeout = 3 }:show()
            end
            rebuild()
        end)
    end

    return {
        function(iw)
            local status, running = Remote.status()
            return Row.widget({
                width = iw, kind = "toggle", chevron = false, icon = "folder", title = _("远程管理服务"),
                status = status, status_on = running,
                callback = function()
                    if Remote.isRunning() then
                        Remote.stop()
                    else
                        start()
                    end
                    rebuild()
                end,
            })
        end,
        function(iw)
            return Row.widget({
                width = iw, kind = "nav", chevron = true, icon = "dns", title = _("端口"),
                status = tostring(Remote.port()), status_on = true,
                callback = function()
                    require("ui.themes.widgets.input"):new{
                        title = _("端口"),
                        fields = { { text = tostring(Remote.port()), input_type = "number" } },
                        ok_text = _("保存"),
                        callback = function(text)
                            local port = tonumber(text)
                            if not (port and port >= 1 and port <= 65535) then return end
                            Remote.setPort(math.floor(port))
                            -- 新端口可能被占：重启失败要说出来，不能让服务悄悄停掉。
                            if Remote.isRunning() then
                                Remote.stop()
                                start()
                            end
                            rebuild()
                        end,
                    }:show()
                end,
            })
        end,
        function(iw)
            local on = Remote.autostartOn()
            return Row.widget({
                width = iw, kind = "toggle", chevron = false, icon = "power", title = _("开机自启"),
                status = on and _("开") or _("关"), status_on = on,
                callback = function()
                    Remote.setAutostart(not on)
                    rebuild()
                end,
            })
        end,
        function(iw)
            local on = Remote.idleStopOn()
            return Row.widget({
                width = iw, kind = "toggle", chevron = false, icon = "schedule", title = _("空闲自动关闭"),
                status = on and _("开") or _("关"), status_on = on,
                callback = function()
                    Remote.setIdleStop(not on)
                    rebuild()
                end,
            })
        end,
        function(iw)
            local on = Remote.deleteAfterShareOn()
            return Row.widget({
                width = iw, kind = "toggle", chevron = false, icon = "delete", title = _("截图分享后自动删除"),
                status = on and _("开") or _("关"), status_on = on,
                callback = function()
                    Remote.setDeleteAfterShare(not on)
                    rebuild()
                end,
            })
        end,
    }
end

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    local Remote = require("features.remote")
    local running = Remote.isRunning()
    return {
        {
            id = "main",
            group = "system",
            order = 60,
            icon = "dns",
            title = _("远程管理"),
            subtitle = _("浏览器管理文件、输入"),
            status = running and _("运行中") or nil,
            status_on = running,
            page = {
                title = _("远程管理"),
                sections = function()
                    return { { title = _("远程"), rows = rows(desktop) } }
                end,
            },
        },
    }
end

return Setting
