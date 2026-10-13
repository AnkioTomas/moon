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
    if Auth.hasSession() then
        return Auth.userLabel() or _("已登录"), true
    end
    return _("未登录 · 点此扫码"), false
end

--- 展示扫码登录流程（Eink 扫码；换到的 accessToken 同时是网页会话，再经网页接口补拉昵称）。
local function showQrLogin()
    local Auth = require("source.wechat.auth")
    local Eink = require("source.wechat.eink")
    local NetworkMgr = require("ui/network/manager")
    local QR = require("ui.themes.widgets.qr")
    local Toast = require("ui.themes.widgets.toast")

    NetworkMgr:runWhenOnline(function()
        local cancelled = false
        local dialog
        local begin_job, wait_job

        --- 代码主动关窗：先摘掉引用，close_callback 就不会当成用户取消。
        local function closeDialog()
            local d = dialog
            dialog = nil
            if d then d:close() end
        end

        -- 点框内外、返回键都走这里，否则后台轮询会一直跑到超时。
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

        --- 换上新的登录窗；用户关掉它即取消整个登录。
        ---@param d table 未显示的主题弹窗
        local function showDialog(d)
            closeDialog()
            d.close_callback = function()
                if dialog ~= d then return end
                dialog = nil
                cancel()
            end
            dialog = d
            d:show()
        end

        showDialog(Toast:new{ text = _("正在获取二维码…") })

        --- 展示二维码并长连接等待扫码结果。
        ---@param uid string
        ---@param qr_payload string
        local function startWait(uid, qr_payload)
            showDialog(QR:new{ title = _("微信扫码登录"), text = qr_payload })
            wait_job = Eink.waitQrLoginAsync(uid, function(info, err, status)
                wait_job = nil
                if cancelled then
                    return
                end
                closeDialog()
                if status ~= "ok" or not info then
                    Toast:new{ text = err or _("二维码已失效，请重新登录") }:show()
                    return
                end
                Eink.completeQrLoginAsync(info, function(ok, e2)
                    if cancelled then
                        return
                    end
                    if not ok then
                        Toast:new{ text = e2 or _("登录失败") }:show()
                        return
                    end
                    Auth.fetchUserAsync(function(user)
                        Toast:new{
                            text = T(_("已登录：%1"), user.user_name ~= "" and user.user_name or user.user_id),
                            timeout = 2,
                        }:show()
                        require("source.registry").reload()
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
            Toast:new{ text = err or _("无法开始登录") }:show()
        end)
    end)
end

--- 设置页行：账号（扫码）/ 同步阅读时间；已登录时追加续期、退出。
---@param plugin table|nil
---@return table[]
function Setting.rows(plugin)
    local Row = require("ui.themes.widgets.row")
    local Auth = require("source.wechat.auth")
    local Toast = require("ui.themes.widgets.toast")
    local rows = {
        function(iw)
            local status, status_on = Setting.rowStatus()
            return Row.widget({ width = iw, chevron = true, kind = "nav", icon = "account_circle", title = _("微信读书账号"),
                status = status, status_on = status_on,
                callback = showQrLogin })
        end,
    }
    local Settings = require("utils.settings")
    --- 布尔开关行；default 为未设置时的取值。
    local function toggle(key, default, icon, title, subtitle)
        rows[#rows + 1] = function(iw)
            local cfg = Settings.getSource(SOURCE_ID)
            local on = cfg[key] == nil and default or cfg[key] == true
            return Row.widget({ width = iw, chevron = false, kind = "toggle", icon = icon, title = title,
                subtitle = subtitle, status = on and _("开") or _("关"), status_on = on,
                callback = function()
                    cfg[key] = not on
                    Settings.saveSource(SOURCE_ID, cfg)
                    if plugin and plugin.desktop then plugin.desktop:updateView() end
                end })
        end
    end
    toggle("sync_reading_time", true, "timer", _("同步阅读时间"), _("阅读时必须联网，微信读书才会计入时长"))
    toggle("merge_local_stats", false, "history", _("合并本地阅读时长"),
        _("关闭时以云端为准；打开后每天取云端与本地中较大的，补上离线阅读。只影响月读里的统计"))
    toggle("show_paragraph_reviews", false, "forum", _("显示段评"), _("阅读时给有他人段评的句子画线，点按查看；需联网"))
    if not Auth.hasSession() then return rows end
    rows[#rows + 1] = function(iw)
        return Row.widget({ width = iw, chevron = false, kind = "action", icon = "autorenew", title = _("续期会话"),
            callback = function()
                require("ui/network/manager"):runWhenOnline(function()
                    require("source.wechat.eink").refreshAsync(function(ok, err)
                        Toast:new{ text = ok and _("已续期") or (err or _("续期失败")), timeout = 2 }:show()
                    end)
                end)
            end })
    end
    rows[#rows + 1] = function(iw)
        return Row.widget({ width = iw, chevron = false, kind = "action", icon = "logout", title = _("退出登录"),
            callback = function()
                require("ui.themes.widgets.confirm"):new{
                    text = _("确定退出微信读书账号？"),
                    ok_text = _("退出登录"),
                    ok_callback = function()
                        Auth.clearSession()
                        Toast:new{ text = _("已退出"), timeout = 2 }:show()
                        require("source.registry").reload()
                    end,
                }:show()
            end })
    end
    return rows
end

return Setting
