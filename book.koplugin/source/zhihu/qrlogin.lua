--[[--
知乎 App 扫码登录。

POST /api/v3/account/api/login/qrcode 返回 token 和二维码内容。
每 2 秒轮询 scan_info，手机确认后校验并保存 Cookie。

@module source.zhihu.qrlogin
--]]

local Client = require("source.zhihu.client")
local _ = require("l10n").get("source.zhihu")

local QRLogin = {}
QRLogin.__index = QRLogin

local POLL_INTERVAL = 2
local POLL_LIMIT = 90

---@param on_ok fun()
---@return table
function QRLogin:new(on_ok)
    return setmetatable({ on_ok = on_ok, generation = 0 }, QRLogin)
end

function QRLogin:cancel()
    self.generation = self.generation + 1
    if self.job and self.job.cancel then self.job.cancel() end
    self.job = nil
    if self.verification then
        self.verification:cancel()
        self.verification = nil
    end
    if self.poll_callback then
        require("ui/uimanager"):unschedule(self.poll_callback)
        self.poll_callback = nil
    end
    for _idx, key in ipairs({ "dialog", "busy", "retry_dialog" }) do
        local dialog = self[key]
        self[key] = nil
        if dialog then
            dialog.close_callback = nil
            dialog:close()
        end
    end
end

---@param session ZhihuQRSession
function QRLogin:_verify(session)
    self:cancel()
    local gen = self.generation
    local fired = false
    local verification = require("source.zhihu.verify").new(session, function(ok, err)
        fired = true
        if gen ~= self.generation then return end
        self.verification = nil
        if ok then self:start(session) else self:_retry(err or _("验证失败，请重新验证")) end
    end)
    if not fired then self.verification = verification end
end

---@param text string
function QRLogin:toast(text)
    require("ui.themes.widgets.toast"):new{ text = text, timeout = 3 }:show()
end

---@param text string
function QRLogin:_retry(text)
    self:cancel()
    self.retry_dialog = require("ui.themes.widgets.confirm"):new{
        text = text,
        ok_text = _("重新获取"),
        ok_callback = function() self:start() end,
    }:show()
end

---@param link string
function QRLogin:_show(link)
    local old = self.dialog
    self.dialog = nil
    if old then
        old.close_callback = nil
        old:close()
    end
    local dialog
    dialog = require("ui.themes.widgets.qr"):new{
        title = _("知乎扫码登录"),
        text = link,
        caption = _("用知乎 App 扫一扫"),
        close_callback = function()
            if self.dialog ~= dialog then return end
            self.dialog = nil
            self:cancel()
            self:toast(_("已取消登录"))
        end,
    }
    self.dialog = dialog
    dialog:show()
end

---@param gen integer
---@param session ZhihuQRSession
---@param polls integer
function QRLogin:_poll(gen, session, polls)
    if gen ~= self.generation then return end
    if polls > POLL_LIMIT or (session.expires_at and os.time() >= session.expires_at) then
        self:_retry(_("二维码已过期"))
        return
    end
    local fired = false
    local job = Client.qrPollAsync(session, function(kind, extra, err)
        fired = true
        if gen ~= self.generation then return end
        self.job = nil
        if kind == "ok" then
            self:cancel()
            self.on_ok()
            return
        end
        if kind == "expired" then self:_retry(_("二维码已过期")); return end
        if kind == "verify" and extra then self:_verify(extra); return end
        if kind == "refresh" and extra then
            session, polls = extra, 0
            self.scanned = false
            self:_show(extra.link)
        elseif kind == "scanned" then
            if not self.scanned then
                self.scanned = true
                self:toast(_("已扫码，请在手机上确认"))
            end
        elseif kind ~= "wait" then
            self:_retry(err or _("登录失败"))
            return
        end
        self.poll_callback = function()
            self.poll_callback = nil
            if gen == self.generation then self:_poll(gen, session, polls + 1) end
        end
        require("ui/uimanager"):scheduleIn(POLL_INTERVAL, self.poll_callback)
    end)
    if not fired then self.job = job end
end

---@param session ZhihuQRSession|nil
function QRLogin:start(session)
    self:cancel()
    local gen = self.generation
    self.scanned = false
    self.busy = require("ui.themes.widgets.progress_dialog"):new{
        title = _("知乎扫码登录"),
        text = _("正在获取二维码…"),
        on_cancel = function() self:cancel(); self:toast(_("已取消登录")) end,
        close_callback = function()
            self:cancel()
        end,
    }
    self.busy:show()
    local fired = false
    local job = Client.qrCreateAsync(function(created, err, challenge)
        fired = true
        if gen ~= self.generation then return end
        self.job = nil
        local busy = self.busy
        self.busy = nil
        busy.close_callback = nil
        busy:close()
        if challenge then self:_verify(challenge); return end
        if not created then
            self:_retry(err or _("获取二维码失败"))
            return
        end
        self:_show(created.link)
        self:_poll(gen, created, 1)
    end, session)
    if not fired then self.job = job end
end

return QRLogin
