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

--- 展示扫码登录流程（Eink 扫码；换到的 accessToken 同时是网页会话，再经网页接口补拉昵称）。
---@param plugin table|nil
local function showQrLogin(plugin)
    local Auth = require("source.wechat.auth")
    local Eink = require("source.wechat.eink")
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

        ---@return table
        local function newDialog()
            return ButtonDialog:new{
                title = _("微信扫码登录"),
                tap_close_callback = cancel,
                buttons = {{
                    {
                        text = _("取消"),
                        callback = function()
                            cancel()
                            closeDialog()
                        end,
                    },
                }},
            }
        end

        dialog = newDialog()
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
            dialog = newDialog()
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

            wait_job = Eink.waitQrLoginAsync(uid, function(info, err, status)
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
                Eink.completeQrLoginAsync(info, function(ok, e2)
                    if cancelled then
                        return
                    end
                    if not ok then
                        UIManager:show(InfoMessage:new{ text = e2 or _("登录失败") })
                        return
                    end
                    Auth.fetchUserAsync(function(user)
                        UIManager:show(InfoMessage:new{
                            text = T(_("已登录：%1"), user.user_name ~= "" and user.user_name or user.user_id),
                            timeout = 2,
                        })
                        require("source.registry").afterAuthChanged(plugin)
                    end)
                end)
            end)
        end

        begin_job = Eink.beginQrLoginAsync(function(started, err)
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

--- 设置页行：账号（扫码）/ 同步阅读时间；已登录时追加续期、退出。
---@param plugin table|nil
---@return table[]
function Setting.rows(plugin)
    local SettingRow = require("ui.components.settingrow")
    local Auth = require("source.wechat.auth")
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local rows = {
        function(iw)
            local status, status_on = Setting.rowStatus()
            return SettingRow.build(iw, { kind = "nav", icon = "account_circle", title = _("微信读书账号"),
                status = status, status_on = status_on,
                callback = function() showQrLogin(plugin) end })
        end,
        function(iw)
            local Settings = require("utils.settings")
            local on = Settings.getSource(SOURCE_ID).sync_reading_time ~= false
            return SettingRow.build(iw, { kind = "toggle", icon = "timer", title = _("同步阅读时间"),
                subtitle = _("阅读时必须联网，微信读书才会计入时长"),
                status = on and _("开") or _("关"), status_on = on,
                callback = function()
                    local cfg = Settings.getSource(SOURCE_ID)
                    cfg.sync_reading_time = not on
                    Settings.saveSource(SOURCE_ID, cfg)
                    if plugin and plugin.desktop then plugin.desktop:updateView() end
                end })
        end,
    }
    if not Auth.hasSession() then return rows end
    rows[#rows + 1] = function(iw)
        return SettingRow.build(iw, { kind = "action", icon = "autorenew", title = _("续期会话"),
            callback = function()
                require("ui/network/manager"):runWhenOnline(function()
                    Auth.renewCookieAsync(function(ok, err)
                        UIManager:show(InfoMessage:new{
                            text = ok and _("已续期") or (err or _("续期失败")),
                            timeout = 2,
                        })
                    end)
                end)
            end })
    end
    rows[#rows + 1] = function(iw)
        return SettingRow.build(iw, { kind = "action", icon = "logout", title = _("退出登录"),
            callback = function()
                UIManager:show(require("ui/widget/confirmbox"):new{
                    text = _("确定退出微信读书账号？"),
                    ok_text = _("退出登录"),
                    ok_callback = function()
                        Auth.clearSession()
                        UIManager:show(InfoMessage:new{ text = _("已退出"), timeout = 2 })
                        require("source.registry").afterAuthChanged(plugin)
                    end,
                })
            end })
    end
    return rows
end

return Setting
