--[[--
塔读微信扫码登录。

打开微信扫 confirm 链接。长轮询本身会挂住，扫上之后再隔 0.2 秒问下一次。
五分钟还没确认就当二维码过期。

@module source.tadu.qrlogin
--]]

require("l10n").apply()
local Client = require("source.tadu.client")
local Mapper = require("source.tadu.mapper")
local _ = require("gettext")

local QRLogin = {}
QRLogin.__index = QRLogin

local POLL_INTERVAL = 0.2
local DEADLINE = 5 * 60

---@param on_user fun(user: { name: string })
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
---@param uuid string
---@param last integer|nil
function QRLogin:_poll(gen, uuid, last)
    if gen ~= self.generation then return end
    if os.time() > self.deadline then
        self:_retry(_("二维码已过期"))
        return
    end
    self.job = Client.qrPollAsync(uuid, last, function(kind, wx_code, errcode)
        if gen ~= self.generation then return end
        self.job = nil
        if kind == "ok" then
            self.job = Client.exchangeAsync(wx_code, function(user, err)
                if gen ~= self.generation then return end
                self.job = nil
                if not user then
                    self:_retry(err or _("未登录塔读"))
                    return
                end
                self:cancel()
                if self.dialog then
                    self.dialog:close()
                    self.dialog = nil
                end
                self.on_user(user)
            end)
            return
        end
        if kind == "wait" then
            require("ui/uimanager"):scheduleIn(POLL_INTERVAL, function()
                if gen == self.generation then self:_poll(gen, uuid, errcode) end
            end)
            return
        end
        if kind == "fail" then
            self:_retry(_("已在微信中拒绝登录"))
            return
        end
        self:_retry(_("二维码已过期"))
    end)
end

function QRLogin:start()
    self:cancel()
    local gen = self.generation
    self.deadline = os.time() + DEADLINE
    self.job = Client.qrCreateAsync(function(uuid, err)
        if gen ~= self.generation then return end
        self.job = nil
        if not uuid then
            self:_retry(err or _("获取二维码失败"))
            return
        end
        local QR = require("ui.themes.widgets.qr")
        self.dialog = QR:new{
            title = _("塔读扫码登录"),
            caption = _("用微信扫一扫"),
            text = Mapper.qrText(uuid),
            close_callback = function()
                if gen == self.generation then self:cancel() end
            end,
        }
        self.dialog:show()
        self:_poll(gen, uuid, nil)
    end)
end

return QRLogin
