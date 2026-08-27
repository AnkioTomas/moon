--[[--
微信读书源设置 UI（扫码登录由本模块自绘）。
读写：utils.settings.getSource / saveSource("wechat")

@module koplugin.book.source.wechat.setting
--]]

local _ = require("gettext")
local T = require("ffi/util").template

local SOURCE_ID = "wechat"

local Setting = {}

--- 设置行状态文案与高亮开关。
---@return string status, boolean status_on
function Setting.rowStatus()
    local Auth = require("source.wechat.auth")
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    if Auth.hasSession() then
        return Auth.userLabel() or cfg.user_id or _("已登录"), true
    end
    return _("未登录 · 点此扫码"), false
end

--- 认证状态变更后失效活跃源并通知插件刷新。
---@param plugin table|nil
local function afterAuthChanged(plugin)
    require("source.registry").invalidate()
    if plugin and plugin.onSourceChanged then
        plugin:onSourceChanged()
    end
end

--- 展示微信读书扫码登录流程。
---@param plugin table|nil
local function showQrLogin(plugin)
    local Auth = require("source.wechat.auth")
    local NetworkMgr = require("ui/network/manager")
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local QRWidget = require("ui/widget/qrwidget")
    local Screen = require("device").screen
    local VerticalGroup = require("ui/widget/verticalgroup")
    local TextWidget = require("ui/widget/textwidget")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local ButtonDialog = require("ui/widget/buttondialog")
    local Geom = require("ui/geometry")
    local UI = require("ui.components.bookui")

    NetworkMgr:runWhenOnline(function()
        local cancelled = false
        local dialog
        local begin_job, wait_job
        local qr_size = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.55)

        --- 关闭当前登录对话框。
        local function closeDialog()
            if dialog then
                UIManager:close(dialog)
                dialog = nil
            end
        end

        dialog = ButtonDialog:new{
            title = _("微信扫码登录"),
            buttons = {{
                {
                    text = _("取消"),
                    callback = function()
                        cancelled = true
                        if begin_job then
                            begin_job.cancel()
                            begin_job = nil
                        end
                        if wait_job then
                            wait_job.cancel()
                            wait_job = nil
                        end
                        closeDialog()
                    end,
                },
            }},
        }
        if dialog.addWidget then
            dialog:addWidget(CenterContainer:new{
                dimen = Geom:new{ w = Screen:getWidth() * 0.9, h = qr_size + UI.sz(40) },
                VerticalGroup:new{
                    align = "center",
                    TextWidget:new{
                        text = _("正在获取二维码…"),
                        face = UI.face("xx_smallinfofont", 14),
                    },
                },
            })
        end
        UIManager:show(dialog)

        --- 展示二维码并长连接等待扫码结果。
        ---@param uid string
        ---@param qr_payload string
        local function startWait(uid, qr_payload)
            closeDialog()
            local qr = QRWidget:new{
                text = qr_payload,
                width = qr_size,
                height = qr_size,
            }
            dialog = ButtonDialog:new{
                title = _("微信扫码登录"),
                buttons = {{
                    {
                        text = _("取消"),
                        callback = function()
                            cancelled = true
                            if wait_job then
                                wait_job.cancel()
                                wait_job = nil
                            end
                            closeDialog()
                        end,
                    },
                }},
            }
            if dialog.addWidget then
                dialog:addWidget(CenterContainer:new{
                    dimen = Geom:new{ w = Screen:getWidth() * 0.9, h = qr_size + UI.sz(40) },
                    VerticalGroup:new{
                        align = "center",
                        qr,
                    },
                })
            end
            UIManager:show(dialog)

            wait_job = Auth.waitQrLoginAsync(uid, function(info, err, status)
                wait_job = nil
                if cancelled then
                    return
                end
                if status ~= "ok" or not info then
                    closeDialog()
                    UIManager:show(InfoMessage:new{
                        text = err or _("二维码已失效，请重新登录"),
                    })
                    return
                end
                closeDialog()
                Auth.completeQrLoginAsync(info, function(user, e2)
                    if cancelled then
                        return
                    end
                    if not user then
                        UIManager:show(InfoMessage:new{ text = e2 or _("登录失败") })
                        return
                    end
                    UIManager:show(InfoMessage:new{
                        text = T(_("已登录：%1"), user.user_name ~= "" and user.user_name or user.user_id),
                        timeout = 2,
                    })
                    afterAuthChanged(plugin)
                end)
            end)
        end

        begin_job = Auth.beginQrLoginAsync(function(started, err)
            begin_job = nil
            if cancelled then
                return
            end
            if started then
                startWait(started.uid, started.qr_payload)
                return
            end
            closeDialog()
            UIManager:show(InfoMessage:new{
                text = err or _("无法开始登录"),
            })
        end)
    end)
end

--- 刷新 Skills API Key（Web 会话自动获取）。
---@param plugin table|nil
local function refreshAgentKey(plugin)
    local Auth = require("source.wechat.auth")
    local NetworkMgr = require("ui/network/manager")
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    NetworkMgr:runWhenOnline(function()
        Auth.fetchAgentKeyAsync(function(key, err)
            UIManager:show(InfoMessage:new{
                text = key and _("Skills 密钥已更新") or (err or _("获取失败")),
                timeout = 2,
            })
            if key then
                afterAuthChanged(plugin)
            end
        end)
    end)
end

--- 自绘账号菜单（未登录直接扫码；已登录：扫码 / 续期 / 退出）
---@param plugin table|nil
function Setting.open(plugin)
    local Auth = require("source.wechat.auth")
    if not Auth.hasSession() then
        showQrLogin(plugin)
        return
    end

    local NetworkMgr = require("ui/network/manager")
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    local title = _("微信读书账号") .. " · " .. (Auth.userLabel() or cfg.user_id or "")
    dialog = ButtonDialog:new{
        title = title,
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
                    text = _("刷新 Skills 密钥"),
                    callback = function()
                        UIManager:close(dialog)
                        refreshAgentKey(plugin)
                    end,
                },
            },
            {
                {
                    text = _("续期会话"),
                    callback = function()
                        UIManager:close(dialog)
                        NetworkMgr:runWhenOnline(function()
                            Auth.renewCookieAsync(function(ok, err)
                            UIManager:show(InfoMessage:new{
                                text = ok and _("已续期") or (err or _("续期失败")),
                                timeout = 2,
                            })
                            end)
                        end)
                    end,
                },
            },
            {
                {
                    text = _("退出登录"),
                    callback = function()
                        UIManager:close(dialog)
                        Auth.clearSession()
                        UIManager:show(InfoMessage:new{ text = _("已退出"), timeout = 2 })
                        afterAuthChanged(plugin)
                    end,
                },
            },
            {
                {
                    text = _("取消"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

return Setting
