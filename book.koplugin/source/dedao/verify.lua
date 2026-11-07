--[[--
得到短信易盾验证。浏览器只交验证凭据，手机号、OAuth 与 Cookie 留在设备。
五分钟票据绑定原候选登录会话，验证通过并成功发送短信后才继续登录。

@module source.dedao.verify
--]]

require("l10n").apply()
local Ext = require("utils.extension")
local Client = require("source.dedao.client")
local _ = require("gettext")

---@class DedaoVerification
---@field ticket string
---@field challenge DedaoSMSChallenge
---@field callback fun(session: DedaoSMSLoginSession|nil, err: string|nil)
---@field expires integer
---@field pending table|nil
---@field dialog BookThemeQR|nil
---@field timeout function
---@field done boolean|nil
local Verification = {}
Verification.__index = Verification
---@type table<string, DedaoVerification>
local sessions = {}

function Verification:cancel()
    if self.done then return end
    self.done = true
    sessions[self.ticket] = nil
    require("ui/uimanager"):unschedule(self.timeout)
    if self.pending and self.pending.job then self.pending.job.cancel() end
    local dialog = self.dialog
    self.dialog = nil
    if dialog then dialog:close() end
end

function Verification:finish(session, err)
    if self.done then return end
    self:cancel()
    self.callback(session, err)
end

---@param challenge DedaoSMSChallenge
---@param cb fun(session: DedaoSMSLoginSession|nil, err: string|nil)
---@return DedaoVerification
function Verification.new(challenge, cb)
    local self = setmetatable({
        ticket = require("utils.random").hex(24), challenge = challenge,
        callback = cb, expires = os.time() + 300,
    }, Verification)
    self.timeout = require("ui.guard").wrap("dedao verification timeout", function()
        self:finish(nil, _("验证已过期，请重新发起验证"))
    end)
    sessions[self.ticket] = self
    require("ui/uimanager"):scheduleIn(300, self.timeout)
    self.dialog = Ext.call("web.open_page", "/dedao_verify.html#" .. self.ticket,
        _("得到安全验证"), _("用同一 Wi-Fi 下的手机扫码，只完成滑块；短信验证码请回到设备填写。"), {
            close_callback = function() self:finish(nil, _("验证已取消")) end,
        })
    if not self.dialog then
        self:finish(nil, _("无法打开远程验证，请先连接 Wi-Fi 并启用远程管理功能"))
    end
    return self
end

local function handle(method, action, params, cb)
    local function reply(status, body)
        cb(status, body, { "Cache-Control: no-store" })
    end
    if method ~= "POST" then return reply(405, { error = "Method Not Allowed" }) end
    if action ~= "config" and action ~= "verify" then return reply(404, { error = "Not Found" }) end
    local self = type(params.ticket) == "string" and sessions[params.ticket]
    if not self or os.time() >= self.expires then
        return reply(403, { error = _("验证已过期，请重新发起验证") })
    end
    if action == "config" then
        return reply(200, {
            captcha_id = self.challenge.captcha_id,
            title = _("得到安全验证"), instruction = _("拖动下方滑块完成拼图"),
            pending = _("正在提交验证…"),
            success = _("验证通过，短信已发送，请回到设备填写验证码。"),
            failure = _("验证失败，请重新滑动验证"),
            load_error = _("滑块加载失败，请检查网络后刷新网页"), retry = _("重试"),
        })
    end
    if type(params.validate) ~= "string" or params.validate == "" or #params.validate > 16384 then
        return reply(400, { error = _("验证凭据无效") })
    end
    if self.pending then return reply(409, { error = _("正在提交验证…") }) end
    local operation = {}
    self.pending = operation
    local job = Client.sendSessionCodeAsync(self.challenge.session, {
        captchaId = self.challenge.captcha_id, validate = params.validate,
    }, function(ok, err, captcha_id)
        if self.done then return reply(403, { error = _("验证已过期，请重新发起验证") }) end
        if os.time() >= self.expires then
            self:finish(nil, _("验证已过期，请重新发起验证"))
            return reply(403, { error = _("验证已过期，请重新发起验证") })
        end
        self.pending = nil
        if captcha_id then self.challenge.captcha_id = captcha_id end
        if not ok then return reply(400, { error = err or _("验证失败，请重新滑动验证") }) end
        reply(200, { ok = true })
        self:finish(self.challenge.session)
    end)
    if self.pending == operation then operation.job = job end
end

local dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
Ext.add("web.routes", {
    name = "dedao_verify", dir = dir .. "web",
    assets = { "dedao_verify.html", "dedao_verify.js" },
    public = { config = true, verify = true }, handle = handle,
})

return Verification
