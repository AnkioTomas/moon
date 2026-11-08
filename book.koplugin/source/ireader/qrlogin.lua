--[[--
掌阅扫码登录。

GET /bookstore/open/user/qrcode/get 的 body 是登录码，二维码内容是 web_login:<码>。
每 1.5 秒轮询 /bookstore/open/user/qrcode/result，和 PC 站一样最多 160 次。
30059 继续等；code 0 时 body.name 是账号、body.session_id 是后续请求的 zysid。

@module source.ireader.qrlogin
--]]

local Client = require("source.ireader.client")
local Mapper = require("source.ireader.mapper")
local _ = require("l10n").get("source.ireader")

local QRLogin = {}
QRLogin.__index = QRLogin

local POLL_INTERVAL = 1.5
local POLL_LIMIT = 160

---@param on_user fun(user: table)
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
        local previous = self.dialog
        self.dialog = nil
        previous:close()
    end
    require("ui.themes.widgets.confirm"):new{
        text = text,
        ok_text = _("重新获取"),
        ok_callback = function() self:start() end,
    }:show()
end

---@param gen integer
---@param code string
---@param polls integer
function QRLogin:_poll(gen, code, polls)
    if gen ~= self.generation then return end
    if not require("ui/network/manager"):isConnected() then
        self:_retry(_("网络不可用，请先连接 Wi-Fi"))
        return
    end
    if polls > POLL_LIMIT or os.time() >= self.deadline then
        self:_retry(_("二维码已过期"))
        return
    end
    local pending = true
    local job = Client.qrPollAsync(code, function(wire, err)
        pending = false
        if gen ~= self.generation then return end
        self.job = nil
        if not wire then
            self:_retry(err or _("请求失败"))
            return
        end
        local user, kind = Mapper.login(wire)
        if user then
            local checking = true
            local check = Client.checkSessionAsync(user, function(ok, reason)
                checking = false
                if gen ~= self.generation then return end
                if not ok then self:_retry(reason or _("登录失败")); return end
                self:cancel()
                if self.dialog then
                    local previous = self.dialog
                    self.dialog = nil
                    previous:close()
                end
                self.on_user(user)
            end)
            if checking then self.job = check end
            return
        end
        if kind ~= "wait" then
            self:_retry(type(wire.msg) == "string" and wire.msg ~= "" and wire.msg or _("登录失败"))
            return
        end
        require("ui/uimanager"):scheduleIn(POLL_INTERVAL, function()
            if gen == self.generation then self:_poll(gen, code, polls + 1) end
        end)
    end)
    if pending then self.job = job end
end

function QRLogin:start()
    self:cancel()
    if self.dialog then
        local previous = self.dialog
        self.dialog = nil
        previous:close()
    end
    if not require("ui/network/manager"):isConnected() then
        self:toast(_("网络不可用，请先连接 Wi-Fi"))
        return
    end
    local gen = self.generation
    self.deadline = os.time() + POLL_INTERVAL * POLL_LIMIT
    local pending = true
    local job = Client.qrCreateAsync(function(code, err)
        pending = false
        if gen ~= self.generation then return end
        self.job = nil
        if not code then
            self:toast(err or _("获取二维码失败"))
            return
        end
        local dialog
        dialog = require("ui.themes.widgets.qr"):new{
            title = _("掌阅扫码登录"),
            text = "web_login:" .. code,
            caption = _("用掌阅 App 扫一扫"),
            actions = { { text = _("重新获取"), callback = function() self:start() end } },
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
        self:_poll(gen, code, 1)
    end)
    if pending then self.job = job end
end

return QRLogin
