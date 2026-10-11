--[[--
京东读书源设置。

@module koplugin.book.source.jdread.setting
--]]

require("l10n").apply()
local _ = require("gettext")

local Setting = {}

---@return string, boolean
function Setting.rowStatus()
    local Auth = require("source.jdread.auth")
    return Auth.hasSession() and (Auth.userLabel() or _("已登录")) or _("未登录 · 点此扫码"),
        Auth.hasSession()
end

local function showQrLogin()
    local Auth = require("source.jdread.auth")
    local NetworkMgr = require("ui/network/manager")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Geom = require("ui/geometry")
    local Screen = require("device").screen
    local Image = require("ui.themes.widgets.image")
    local Sheet = require("ui.themes.widgets.sheet")
    local Text = require("ui.themes.widgets.text")
    local Toast = require("ui.themes.widgets.toast")

    NetworkMgr:runWhenOnline(function()
        local cancelled = false
        local dialog, begin_job, wait_job
        local qr_size = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.55)

        --- 代码主动关窗：先摘掉引用，close_callback 就不会当成用户取消。
        local function closeDialog()
            local d = dialog
            dialog = nil
            if d then d:close() end
        end

        -- 取消按钮、点框外、返回键都走这里，否则后台轮询会一直跑到超时。
        local function cancel()
            cancelled = true
            if begin_job then
                begin_job.cancel()
                begin_job = nil
            end
            if wait_job then
                wait_job.cancel()
                wait_job = nil
            end
        end

        ---@param content fun(): table
        local function showDialog(content)
            closeDialog()
            local d
            d = Sheet:new{
                title = _("京东扫码登录"),
                items = {
                    { widget = function(width)
                        return CenterContainer:new{ dimen = Geom:new{ w = width, h = qr_size }, content() }
                    end },
                    { text = _("取消") },
                },
                close_callback = function()
                    if dialog ~= d then return end
                    dialog = nil
                    cancel()
                end,
            }
            dialog = d
            d:show()
        end

        local function startLogin()
            -- 点击即出框盖住入口：二维码要等一次网络往返，没有反馈用户会连点出多个登录流程。
            showDialog(function() return Text.line("body", _("正在获取二维码…")) end)
            begin_job = Auth.beginQrLoginAsync(function(started, err)
                begin_job = nil
                if cancelled then return end
                if not started then
                    closeDialog()
                    Toast:new{ text = err or _("获取京东登录二维码失败") }:show()
                    return
                end

                Image.invalidate(started.qr_path)
                showDialog(function()
                    return Image.widget({ src = started.qr_path, width = qr_size, height = qr_size })
                end)

                wait_job = Auth.waitQrLoginAsync(started, function(info, wait_err, status)
                    wait_job = nil
                    if cancelled then return end
                    if status ~= "ok" or not info then
                        closeDialog()
                        Toast:new{ text = wait_err or _("二维码已失效，请重新登录") }:show()
                        return
                    end
                    Auth.completeQrLoginAsync(info, function(user, complete_err)
                        if cancelled then return end
                        closeDialog()
                        if not user then
                            Toast:new{ text = complete_err or _("京东登录校验失败") }:show()
                            -- 这张码的 ticket 已经用过，关框后立刻换新码，别让用户扫废码。
                            startLogin()
                            return
                        end
                        Toast:new{ text = _("登录成功"), timeout = 2 }:show()
                        require("source.registry").reload()
                    end)
                end)
            end)
        end
        startLogin()
    end)
end

--- 设置页行：账号（扫码）；已登录时追加退出。
---@return table[]
function Setting.rows()
    local Row = require("ui.themes.widgets.row")
    local Auth = require("source.jdread.auth")
    local rows = {
        function(iw)
            local status, status_on = Setting.rowStatus()
            return Row.widget({ width = iw, chevron = true, kind = "nav", icon = "account_circle", title = _("京东读书账号"),
                status = status, status_on = status_on,
                callback = function() showQrLogin() end })
        end,
    }
    if not Auth.hasSession() then return rows end
    rows[#rows + 1] = function(iw)
        return Row.widget({ width = iw, chevron = false, kind = "action", icon = "logout", title = _("退出登录"),
            callback = function()
                require("ui.themes.widgets.confirm"):new{
                    text = _("确定退出京东读书账号？"),
                    ok_text = _("退出登录"),
                    ok_callback = function()
                        Auth.clearSession()
                        require("source.registry").reload()
                    end,
                }:show()
            end })
    end
    return rows
end

return Setting
