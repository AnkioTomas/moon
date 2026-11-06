--[[--
网易云阅读短信前的图形验证码。图由设备按登录会话取回，浏览器只填图上的字。
一次发送拥有一张五分钟票据。

@module koplugin.book.source.netease.verify
--]]

require("l10n").apply()

local Ext = require("utils.extension")
local Client = require("source.netease.client")
local _ = require("gettext")

---@class NeteaseVerification
---@field ticket string
---@field phone string
---@field callback fun(ok: boolean, err: string|nil)
---@field expires integer
---@field dialog BookThemeQR|nil
---@field pending { cancel: fun() }|nil
---@field timeout function
---@field done boolean|nil
local Verification = {}
Verification.__index = Verification

---@type table<string, NeteaseVerification>
local sessions = {}

function Verification:cancel()
    if self.done then return end
    self.done = true
    sessions[self.ticket] = nil
    require("ui/uimanager"):unschedule(self.timeout)
    if self.pending and self.pending.cancel then self.pending.cancel() end
    if self.dialog then self.dialog:close() end
end

function Verification:finish(ok, err)
    if self.done then return end
    self:cancel()
    self.callback(ok, err)
end

---@param phone string
---@param cb fun(ok: boolean, err: string|nil)
---@return NeteaseVerification
function Verification.new(phone, cb)
    local self = setmetatable({
        ticket = require("utils.random").hex(24), phone = phone,
        callback = cb, expires = os.time() + 300,
    }, Verification)
    self.timeout = require("ui.guard").wrap("netease verification timeout", function()
        self:finish(false, _("验证已过期，请重新发起验证"))
    end)
    sessions[self.ticket] = self
    require("ui/uimanager"):scheduleIn(300, self.timeout)
    self.dialog = Ext.call("web.open_page", "/netease_verify.html#" .. self.ticket,
        _("网易云阅读图形验证码"), _("用同一 Wi-Fi 下的手机扫码，只填写图上的字；短信验证码请回到设备填写。"), {
            close_callback = function() self:finish(false, _("验证已取消")) end,
        })
    if not self.dialog then
        self:finish(false, _("无法打开远程验证，请先连接 Wi-Fi 并启用远程管理功能"))
    end
    return self
end

---@param value any
---@param limit integer
---@return string|nil
local function bounded(value, limit)
    if type(value) ~= "string" or #value == 0 or #value > limit then return nil end
    return value
end

---@param method string
---@param action string
---@param params table
---@param cb fun(status: integer, body: table, headers: string[]|nil)
local function handle(method, action, params, cb)
    local function reply(status, body)
        cb(status, body, { "Cache-Control: no-store" })
    end
    if method ~= "POST" then return reply(405, { error = "Method Not Allowed" }) end
    if action ~= "config" and action ~= "verify" then return reply(404, { error = "Not Found" }) end
    local session = type(params.ticket) == "string" and sessions[params.ticket]
    if not session or session.done or os.time() >= session.expires then
        return reply(403, { error = _("验证已过期，请重新发起验证") })
    end
    if action == "config" then
        if session.pending and session.pending.cancel then session.pending.cancel() end
        session.pending = Client.captchaAsync(function(image, mime)
            session.pending = nil
            if session.done then return reply(403, { error = _("验证已过期，请重新发起验证") }) end
            if not image then return reply(400, { error = mime or _("图形验证码加载失败") }) end
            reply(200, {
                title = _("网易云阅读图形验证码"),
                instruction = _("填写图上的字，短信会发到手机"),
                image = image,
                mime = mime,
                button = _("发送短信"),
                pending = _("正在发送短信…"),
                success = _("验证通过，短信已发送，请回到设备填写验证码。"),
            })
        end)
        return
    end
    local image_code = bounded(params.code, 16)
    if not image_code then return reply(400, { error = _("请输入图形码") }) end
    if session.pending then return reply(409, { error = _("正在发送短信…") }) end
    session.pending = Client.sendCodeAsync(session.phone, image_code, function(ok, err)
        session.pending = nil
        if session.done then return reply(403, { error = _("验证已过期，请重新发起验证") }) end
        if not ok then return reply(400, { error = err or _("图形验证码错误") }) end
        reply(200, { ok = true })
        session:finish(true)
    end)
end

local dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
Ext.add("web.routes", {
    name = "netease_verify", dir = dir .. "web",
    assets = { "netease_verify.html", "netease_verify.js" },
    public = { config = true, verify = true }, handle = handle,
})

return Verification
