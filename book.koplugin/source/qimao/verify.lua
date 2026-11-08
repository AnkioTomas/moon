--[[--
七猫发送短信前的数美滑块：浏览器只交 rid，手机号与短信码留在设备。
一次发送拥有一张五分钟票据，关闭输入窗或二维码即取消；成功发送后票据作废。

@module koplugin.book.source.qimao.verify
--]]


local Ext = require("utils.extension")
local Client = require("source.qimao.client")
local _ = require("l10n").get("source.qimao")

---@class QimaoVerification
---@field ticket string
---@field phone string
---@field token string|nil
---@field callback fun(ok: boolean, err: string|nil)
---@field expires integer
---@field dialog BookThemeQR|nil
---@field pending table|nil
---@field timeout function
---@field done boolean|nil
local Verification = {}
Verification.__index = Verification

---@type table<string, QimaoVerification>
local sessions = {}

function Verification:cancel()
    if self.done then return end
    self.done = true
    sessions[self.ticket] = nil
    require("ui/uimanager"):unschedule(self.timeout)
    if self.pending and self.pending.job then self.pending.job:cancel() end
    if self.dialog then self.dialog:close() end
end

function Verification:finish(ok, err)
    if self.done then return end
    self:cancel()
    self.callback(ok, err)
end

---@param phone string
---@param cb fun(ok: boolean, err: string|nil)
---@return QimaoVerification
function Verification.new(phone, cb)
    local self = setmetatable({
        ticket = require("utils.random").hex(24), phone = phone, token = Client.token(),
        callback = cb, expires = os.time() + 300,
    }, Verification)
    self.timeout = require("ui.guard").wrap("qimao verification timeout", function()
        self:finish(false, _("验证已过期，请重新发起验证"))
    end)
    sessions[self.ticket] = self
    require("ui/uimanager"):scheduleIn(300, self.timeout)
    self.dialog = Ext.call("web.open_page", "/qimao_verify.html#" .. self.ticket,
        _("七猫滑块验证"), _("用同一 Wi-Fi 下的手机扫码，只完成滑块；短信验证码请回到设备填写。"), {
            close_callback = function() self:finish(false, _("验证已取消")) end,
        })
    if not self.dialog then
        self:finish(false, _("无法打开远程验证，请先连接 Wi-Fi 并启用远程管理功能"))
    end
    return self
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
    if not session or os.time() >= session.expires or session.token ~= Client.token() then
        return reply(403, { error = _("验证已过期，请重新发起验证") })
    end
    if action == "config" then
        return reply(200, {
            title = _("七猫滑块验证"), instruction = _("拖动下方滑块完成拼图"),
            pending = _("正在提交验证…"),
            success = _("验证通过，短信已发送，请回到设备填写验证码。"),
            failure = _("验证失败，请重新滑动验证"),
            load_error = _("滑块加载失败，请检查网络后刷新网页"), retry = _("重试"),
        })
    end
    if type(params.rid) ~= "string" or params.rid == "" or #params.rid > 1024 then
        return reply(400, { error = _("验证凭据无效") })
    end
    if session.pending then return reply(409, { error = _("正在提交验证…") }) end
    local operation = {}
    session.pending = operation
    operation.job = Client.sendCodeAsync(session.phone, params.rid, function(ok, err)
        if session.done then return reply(403, { error = _("验证已过期，请重新发起验证") }) end
        if session.pending ~= operation then return end
        if os.time() >= session.expires or session.token ~= Client.token() then
            session:finish(false, _("验证已过期，请重新发起验证"))
            return reply(403, { error = _("验证已过期，请重新发起验证") })
        end
        session.pending = nil
        if not ok then return reply(400, { error = err or _("验证失败，请重新滑动验证") }) end
        reply(200, { ok = true })
        session:finish(true)
    end)
end

local dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
Ext.add("web.routes", {
    name = "qimao_verify", dir = dir .. "web",
    assets = { "qimao_verify.html", "qimao_verify.js" },
    public = { config = true, verify = true }, handle = handle,
})

return Verification
