--[[--
京东读书源设置。

@module koplugin.book.source.jdread.setting
--]]

require("l10n").apply()
local _ = require("gettext")

local SOURCE_ID = "jdread"
local Setting = {}

---@return string, boolean
function Setting.rowStatus()
    local Auth = require("source.jdread.auth")
    return Auth.hasSession() and (Auth.userLabel() or _("已登录")) or _("未登录 · 点此扫码"),
        Auth.hasSession()
end

---@return string
function Setting.rowTitle()
    return _("京东读书账号")
end

---@param plugin table|nil
local function afterAuthChanged(plugin)
    require("source.registry").invalidate()
    if plugin and plugin.onSourceChanged then plugin:onSourceChanged() end
end

---@param plugin table|nil
local function showQrLogin(plugin)
    local Auth = require("source.jdread.auth")
    local NetworkMgr = require("ui/network/manager")
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local ButtonDialog = require("ui/widget/buttondialog")
    local ImageWidget = require("ui/widget/imagewidget")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Geom = require("ui/geometry")
    local Screen = require("device").screen

    NetworkMgr:runWhenOnline(function()
        local cancelled = false
        local dialog, begin_job, wait_job
        local qr_size = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.55)

        local function closeDialog()
            if dialog then
                UIManager:close(dialog)
                dialog = nil
            end
        end

        begin_job = Auth.beginQrLoginAsync(function(started, err)
            begin_job = nil
            if cancelled then return end
            if not started then
                UIManager:show(InfoMessage:new{ text = err or _("获取京东登录二维码失败") })
                return
            end

            local image = ImageWidget:new{
                file = started.qr_path,
                width = qr_size,
                height = qr_size,
                scale_factor = 0,
            }
            dialog = ButtonDialog:new{
                title = _("京东扫码登录"),
                buttons = {{
                    {
                        text = _("取消"),
                        callback = function()
                            cancelled = true
                            if wait_job then wait_job.cancel() end
                            closeDialog()
                        end,
                    },
                }},
            }
            if dialog.addWidget then
                dialog:addWidget(CenterContainer:new{
                    dimen = Geom:new{ w = Screen:getWidth() * 0.9, h = qr_size },
                    image,
                })
            end
            UIManager:show(dialog)

            wait_job = Auth.waitQrLoginAsync(started.token, function(info, wait_err, status)
                wait_job = nil
                if cancelled then return end
                if status ~= "ok" or not info then
                    closeDialog()
                    UIManager:show(InfoMessage:new{
                        text = wait_err or _("二维码已失效，请重新登录"),
                    })
                    return
                end
                Auth.completeQrLoginAsync(info, function(user, complete_err)
                    if cancelled then return end
                    closeDialog()
                    if not user then
                        UIManager:show(InfoMessage:new{
                            text = complete_err or _("京东登录校验失败"),
                        })
                        return
                    end
                    UIManager:show(InfoMessage:new{ text = _("登录成功"), timeout = 2 })
                    afterAuthChanged(plugin)
                end)
            end)
        end)
    end)
end

---@param plugin table|nil
function Setting.open(plugin)
    local Auth = require("source.jdread.auth")
    if not Auth.hasSession() then
        showQrLogin(plugin)
        return
    end

    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        title = _("京东读书账号"),
        buttons = {
            {
                {
                    text = _("重新扫码登录"),
                    callback = function()
                        UIManager:close(dialog)
                        showQrLogin(plugin)
                    end,
                },
            },
            {
                {
                    text = _("退出登录"),
                    callback = function()
                        Auth.clearSession()
                        UIManager:close(dialog)
                        afterAuthChanged(plugin)
                    end,
                },
            },
            {
                { text = _("取消"), id = "close" },
            },
        },
    }
    UIManager:show(dialog)
end

return Setting
