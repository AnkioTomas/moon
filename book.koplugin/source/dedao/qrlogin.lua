--[[--
得到扫码登录。

先要匿名 Cookie 和 /loginapi/getAccessToken。二维码内容是
m.igetget.com 的 authorize 链接，轮询 check_login。status 0 继续等，1 成功，2 过期。

@module source.dedao.qrlogin
--]]

require("l10n").apply()
local Client = require("source.dedao.client")
local Mapper = require("source.dedao.mapper")
local _ = require("gettext")

local QRLogin = {}
QRLogin.__index = QRLogin

local POLL_INTERVAL = 1.5
local POLL_LIMIT = 160

---@param on_user fun()
---@return table
function QRLogin:new(on_user)
    return setmetatable({ on_user = on_user, generation = 0 }, QRLogin)
end

function QRLogin:cancel()
    self.generation = self.generation + 1
    if self.job and self.job.cancel then self.job.cancel() end
    self.job = nil
end

---@param text string
function QRLogin:toast(text)
    require("ui.themes.widgets.toast"):new{ text = text, timeout = 3 }:show()
end

---@param text string
function QRLogin:_retry(text)
    self:cancel()
    if self.dialog then
        self.dialog:close()
        self.dialog = nil
    end
    require("ui.themes.widgets.confirm"):new{
        text = text,
        ok_text = _("重新获取"),
        ok_callback = function() self:start() end,
    }:show()
end

---@param gen integer
---@param oauth string
---@param code string
---@param polls integer
function QRLogin:_poll(gen, oauth, code, polls)
    if gen ~= self.generation then return end
    if polls > POLL_LIMIT then
        self:_retry(_("二维码已过期"))
        return
    end
    self.job = Client.qrPollAsync(oauth, code, function(wire, _err)
        if gen ~= self.generation then return end
        self.job = nil
        if not wire then
            require("ui/uimanager"):scheduleIn(POLL_INTERVAL, function()
                if gen == self.generation then self:_poll(gen, oauth, code, polls + 1) end
            end)
            return
        end
        local kind = Mapper.login(wire)
        if kind == "ok" then
            self:cancel()
            if self.dialog then
                self.dialog:close()
                self.dialog = nil
            end
            self.on_user()
            return
        end
        if kind ~= "wait" then
            self:_retry(_("二维码已过期"))
            return
        end
        require("ui/uimanager"):scheduleIn(POLL_INTERVAL, function()
            if gen == self.generation then self:_poll(gen, oauth, code, polls + 1) end
        end)
    end)
end

function QRLogin:start()
    self:cancel()
    local gen = self.generation
    self.job = Client.accessTokenAsync(function(oauth, err)
        if gen ~= self.generation then return end
        if not oauth then
            self:toast(err or _("获取二维码失败"))
            return
        end
        self.job = Client.qrCreateAsync(oauth, function(code, reason)
            if gen ~= self.generation then return end
            self.job = nil
            if not code then
                self:toast(reason or _("获取二维码失败"))
                return
            end
            local dialog
            dialog = require("ui.themes.widgets.qr"):new{
                title = _("得到扫码登录"),
                text = Mapper.qrText(code),
                caption = _("用得到 App 扫一扫"),
                close_callback = function()
                    if self.dialog == dialog then
                        self.dialog = nil
                        self:cancel()
                        self:toast(_("已取消登录"))
                    end
                end,
            }
            self.dialog = dialog
            dialog:show()
            self:_poll(gen, oauth, code, 1)
        end)
    end)
end

return QRLogin
