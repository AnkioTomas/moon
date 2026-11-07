--[[--
快看微信扫码窗口。关闭取消在飞请求和轮询；确认后仅通过官方回调兑换会话。

@module source.kuaikan.qrlogin
--]]

require("l10n").apply()
local Text = require("utils.text")
local _ = require("gettext")

---@class KuaikanQRLogin
---@field generation integer
---@field session KuaikanLogin|nil
---@field poll function|nil
---@field waiting table|nil
---@field dialog table|nil
---@field deadline number
---@field on_user fun()
local QRLogin = {}
QRLogin.__index = QRLogin

function QRLogin.new(on_user)
    return setmetatable({ on_user = on_user, generation = 0 }, QRLogin)
end

function QRLogin:cancel()
    self.generation = self.generation + 1
    if self.session then self.session:cancel() end
    if self.poll then require("ui/uimanager"):unschedule(self.poll); self.poll = nil end
    if self.waiting then self.waiting:close(); self.waiting = nil end
    if self.dialog then
        local dialog = self.dialog
        self.dialog = nil
        dialog:close()
    end
end

function QRLogin:retry(text)
    self:cancel()
    require("ui.themes.widgets.confirm"):new{
        text = text, ok_text = _("重新获取二维码"), ok_callback = function() self:start() end,
    }:show()
end

function QRLogin:pollAsync(gen, uuid, last)
    if gen ~= self.generation then return end
    if not require("ui/network/manager"):isConnected() then self:retry(_("网络不可用，请先连接 Wi-Fi")); return end
    if os.time() >= self.deadline then self:retry(_("二维码已过期")); return end
    self.session:qrPollAsync(uuid, last, function(status, code, err)
        if gen ~= self.generation then return end
        if status == 405 then
            self.session:exchangeAsync(code, function(account, reason)
                if gen ~= self.generation then return end
                if not account then self:retry(reason or _("登录失败")); return end
                self:cancel()
                self.on_user()
            end)
            return
        end
        if status ~= 404 and status ~= 408 then
            self:retry(err or (status == 403 and _("已在微信中拒绝登录") or _("二维码已过期")))
            return
        end
        if status == 404 and last ~= 404 then
            require("ui.themes.widgets.toast"):new{ text = _("已扫码，请在手机上确认") }:show()
        end
        self.poll = require("ui.guard").wrap("kuaikan QR poll", function()
            self.poll = nil
            self:pollAsync(gen, uuid, status)
        end)
        require("ui/uimanager"):scheduleIn(1, self.poll)
    end)
end

function QRLogin:start()
    self:cancel()
    if not require("ui/network/manager"):isConnected() then
        require("ui.themes.widgets.toast"):new{ text = _("网络不可用，请先连接 Wi-Fi") }:show()
        return
    end
    local gen = self.generation
    self.session = require("source.kuaikan.login").new()
    self.deadline = os.time() + 300
    self.waiting = require("ui.themes.widgets.progress_dialog"):new{
        title = _("微信扫码登录"), text = _("正在获取二维码…"),
        on_cancel = function() self:cancel() end,
    }
    self.waiting:show()
    self.session:qrCreateAsync(function(uuid, err)
        if gen ~= self.generation then return end
        self.waiting:close()
        self.waiting = nil
        if not uuid then self:retry(err or _("获取二维码失败")); return end
        self.dialog = require("ui.themes.widgets.qr"):new{
            title = _("微信扫码登录"), caption = _("用微信扫一扫"),
            text = "https://open.weixin.qq.com/connect/confirm?uuid=" .. Text.urlEncode(uuid),
            actions = { { text = _("重新获取二维码"), callback = function() self:start() end } },
            close_callback = function() if gen == self.generation then self:cancel() end end,
        }
        self.dialog:show()
        self:pollAsync(gen, uuid)
    end)
end

return QRLogin
