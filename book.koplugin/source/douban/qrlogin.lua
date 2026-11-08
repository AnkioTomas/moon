--[[--
豆瓣阅读 App 扫码登录。

二维码内容是 https://accounts.arkread.com/oidc/qrcode/confirm?code= 。
每 1.5 秒轮询状态，确认后重新打开授权页，跟跳转直到读到登录用户。

@module source.douban.qrlogin
--]]

local Client = require("source.douban.client")
local _ = require("l10n").get("source.douban")

local QRLogin = {}
QRLogin.__index = QRLogin

local POLL_INTERVAL = 1.5
local POLL_LIMIT = 200

---@param on_user fun(user: { id: string, name: string })
---@return table
function QRLogin:new(on_user)
    return setmetatable({ on_user = on_user, generation = 0 }, QRLogin)
end

function QRLogin:cancel()
    self.generation = self.generation + 1
    if self.job and self.job.cancel then self.job.cancel() end
    self.job = nil
    if self.session then self.session:cancel() end
end

function QRLogin:_request(method, callback, ...)
    local args = { ... }
    local count, pending, gen = select("#", ...) + 1, true, self.generation
    args[count] = function(...)
        pending = false
        if gen ~= self.generation then return end
        self.job = nil
        callback(...)
    end
    local job = self.session[method](self.session, unpack(args, 1, count))
    if pending then self.job = job end
end

---@param text string
function QRLogin:toast(text)
    require("ui.themes.widgets.toast"):new{ text = text, timeout = 3 }:show()
end

---@param text string
function QRLogin:_retry(text)
    self:cancel()
    if self.dialog then
        local dialog = self.dialog
        self.dialog = nil
        dialog:close()
    end
    require("ui.themes.widgets.confirm"):new{
        text = text,
        ok_text = _("重新获取"),
        ok_callback = function() self:start() end,
    }:show()
end

---@param gen integer
---@param code string
---@param authorize string
---@param polls integer
function QRLogin:_poll(gen, code, authorize, polls)
    if gen ~= self.generation then return end
    if polls > POLL_LIMIT or os.time() >= self.deadline then
        self:_retry(_("二维码已过期"))
        return
    end
    self:_request("qrStatusAsync", function(kind, err)
        if gen ~= self.generation then return end
        self.job = nil
        if kind == "ok" then
            self:_request("finishQrAsync", function(user, reason)
                if gen ~= self.generation then return end
                self.job = nil
                if not user then
                    self:_retry(reason or _("登录失败"))
                    return
                end
                self:cancel()
                if self.dialog then
                    local dialog = self.dialog
                    self.dialog = nil
                    dialog:close()
                end
                self.on_user(user)
            end, authorize)
            return
        end
        if kind ~= "wait" then
            self:_retry(err or _("登录失败"))
            return
        end
        require("ui/uimanager"):scheduleIn(POLL_INTERVAL, function()
            if gen == self.generation then self:_poll(gen, code, authorize, polls + 1) end
        end)
    end, code)
end

function QRLogin:start()
    self:cancel()
    self.session = Client.newLogin()
    local gen = self.generation
    self:_request("beginQrAsync", function(ticket, err)
        if gen ~= self.generation then return end
        self.job = nil
        if not ticket then
            self:toast(err or _("获取二维码失败"))
            return
        end
        local dialog
        dialog = require("ui.themes.widgets.qr"):new{
            title = _("豆瓣阅读扫码登录"),
            text = ticket.qr,
            caption = _("用豆瓣阅读 App 扫一扫"),
            close_callback = function()
                if self.dialog == dialog then
                    self.dialog = nil
                    self:cancel()
                    self:toast(_("已取消登录"))
                end
            end,
        }
        self.dialog = dialog
        self.deadline = os.time() + ticket.expires_in
        dialog:show()
        self:_poll(gen, ticket.code, ticket.authorize, 1)
    end)
end

return QRLogin
