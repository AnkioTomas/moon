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
        local dialog, begin_job, wait_job, complete_job, showFailure
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
            if complete_job then
                complete_job.cancel()
                complete_job = nil
            end
        end

        ---@param content fun(): table
        ---@param retry fun()|nil 有值时在取消前加「重新获取二维码」
        local function showDialog(content, retry)
            closeDialog()
            local items = {
                { widget = function(width)
                    return CenterContainer:new{ dimen = Geom:new{ w = width, h = qr_size }, content() }
                end },
            }
            if retry then
                items[#items + 1] = { text = _("重新获取二维码"), variant = "primary", callback = retry }
            end
            items[#items + 1] = { text = _("取消") }
            local d
            d = Sheet:new{
                title = _("京东扫码登录"),
                items = items,
                close_callback = function()
                    if dialog ~= d then return end
                    dialog = nil
                    cancel()
                end,
            }
            dialog = d
            d:show()
        end

        local startLogin
        --- 失败留框：显示原因 + 重新获取二维码。按钮会先关框（触发 cancel），再重置 cancelled 重新开始。
        ---@param reason string
        showFailure = function(reason)
            showDialog(function() return Text.line("body", reason) end, function()
                cancelled = false
                startLogin()
            end)
        end

        startLogin = function()
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
                        showFailure(wait_err or _("二维码已失效，请重新登录"))
                        return
                    end
                    complete_job = Auth.completeQrLoginAsync(info, function(user, complete_err)
                        complete_job = nil
                        if cancelled then return end
                        if not user then
                            -- 不自动换码：留在框里讲清原因，由用户点「重新获取二维码」。
                            showFailure(complete_err or _("京东登录校验失败"))
                            return
                        end
                        closeDialog()
                        Toast:new{ text = _("登录成功"), timeout = 2 }:show()
                        require("source.registry").reload()
                    end)
                end)
            end)
        end
        startLogin()
    end)
end

--- 浏览器扩展登录是扫码之外的备用入口；只申请京东站点 Cookie，成功后由 API 验证再保存。
Setting.browser = {
    domain = "e.m.jd.com",
    scope = "cookie",
    login = "https://e.m.jd.com/",
    check = "https://e.m.jd.com/",
    icon = "https://e.m.jd.com/toc-web/ico.png",
    isAuthorized = function()
        return require("source.jdread.auth").hasSession()
            and not require("source.auth").expired("jdread")
    end,
    apply = function(payload, cb)
        require("source.jdread.auth").importBrowserAsync(payload, cb)
    end,
}

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

--- 登录失效提示的「重新登录」直达入口（desktop.sync.promptLogin）。
Setting.login = showQrLogin

return Setting
