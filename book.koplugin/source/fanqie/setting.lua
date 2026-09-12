--[[--
番茄小说源设置：官方 Web 二维码扫码登录。

@module koplugin.book.source.fanqie.setting
--]]

require("l10n").apply()
local _ = require("gettext")

local Setting = {}

---@return string, boolean
function Setting.rowStatus()
    local Auth = require("source.fanqie.auth")
    local logged_in = Auth.hasSession()
    return logged_in and _("已登录") or _("未登录 · 点此扫码"), logged_in
end

---@return string
function Setting.rowTitle()
    return _("番茄小说账号")
end

---@param plugin table|nil
local function afterAuthChanged(plugin)
    require("source.registry").invalidate()
    if plugin and plugin.onSourceChanged then plugin:onSourceChanged() end
end

---@param plugin table|nil
local function showQrLogin(plugin)
    local Auth = require("source.fanqie.auth")
    local NetworkMgr = require("ui/network/manager")
    local UIManager = require("ui/uimanager")
    local QRMessage = require("ui/widget/qrmessage")
    local InfoMessage = require("ui/widget/infomessage")
    local Screen = require("device").screen
    local qr_size = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.55)

    NetworkMgr:runWhenOnline(function()
        local cancelled, finished = false, false
        local dialog, begin_job, poll_job
        local started_at

        local function closeDialog()
            if dialog then
                UIManager:close(dialog)
                dialog = nil
            end
        end

        local function cancelJobs()
            if begin_job and begin_job.cancel then begin_job:cancel() end
            if poll_job and poll_job.cancel then poll_job:cancel() end
            begin_job, poll_job = nil, nil
        end

        local function fail(message)
            if finished then return end
            finished = true
            cancelled = true
            cancelJobs()
            closeDialog()
            UIManager:show(InfoMessage:new{ text = message })
        end

        local function finish(cookies)
            if finished then return end
            finished = true
            cancelled = true
            cancelJobs()
            closeDialog()
            Auth.saveCookies(cookies)
            UIManager:show(InfoMessage:new{ text = _("登录成功"), timeout = 2 })
            afterAuthChanged(plugin)
        end

        local function poll(started)
            if cancelled then return end
            if os.time() - started_at >= 300
                or (started.expire_time > 0 and os.time() >= started.expire_time) then
                fail(_("二维码已过期，请重新登录"))
                return
            end
            poll_job = Auth.pollQrLoginAsync(started, function(result, err)
                if cancelled then return end
                poll_job = nil
                if err then
                    -- 网络短暂失败不摧毁二维码，下一轮继续请求。
                    UIManager:scheduleIn(2, function() poll(started) end)
                    return
                end
                started.cookies = result.cookies
                started.csrf = result.csrf
                if result.cookies.sessionid and result.cookies.sessionid ~= "" then
                    finish(result.cookies)
                    return
                end
                if result.status == "expired" then
                    fail(_("二维码已过期，请重新登录"))
                    return
                end
                if (result.status == "success" or result.status == "confirmed")
                    and result.redirect_url and result.redirect_url ~= "" then
                    poll_job = Auth.followRedirectAsync(result, result.redirect_url, function(cookies, redirect_err)
                        if cancelled then return end
                        poll_job = nil
                        if cookies then finish(cookies)
                        else fail(redirect_err or _("番茄登录校验失败")) end
                    end)
                    return
                end
                UIManager:scheduleIn(2, function() poll(started) end)
            end)
        end

        begin_job = Auth.beginQrLoginAsync(function(started, err)
            begin_job = nil
            if cancelled then return end
            if not started then
                UIManager:show(InfoMessage:new{ text = err or _("获取番茄登录二维码失败") })
                return
            end
            started_at = os.time()
            dialog = QRMessage:new{
                text = started.qr_url,
                width = qr_size,
                height = qr_size,
                dismiss_callback = function()
                    if not finished then
                        cancelled = true
                        cancelJobs()
                    end
                    dialog = nil
                end,
            }
            UIManager:show(dialog)
            poll(started)
        end)
    end)
end

---@param plugin table|nil
function Setting.open(plugin)
    local Auth = require("source.fanqie.auth")
    if not Auth.hasSession() then
        showQrLogin(plugin)
        return
    end

    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        title = _("番茄小说账号"),
        buttons = {
            {{ text = _("重新扫码登录"), callback = function()
                UIManager:close(dialog)
                showQrLogin(plugin)
            end }},
            {{ text = _("退出登录"), callback = function()
                Auth.clearSession()
                UIManager:close(dialog)
                afterAuthChanged(plugin)
            end }},
            {{ text = _("取消"), id = "close" }},
        },
    }
    UIManager:show(dialog)
end

return Setting
