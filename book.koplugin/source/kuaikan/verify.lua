--[[--
快看腾讯滑块。浏览器只交验证凭据，手机号、密码、短信码和候选 Cookie 留在设备。
临时票据绑定本次输入与候选会话，五分钟截止，提交一次即收回。

@module source.kuaikan.verify
--]]

local Ext = require("utils.extension")
local _ = require("l10n").get("source.kuaikan")

---@class KuaikanVerification
---@field ticket string
---@field session KuaikanLogin
---@field submit (fun(captcha: table, cb: function))|nil
---@field callback fun(result: any, err: string|nil)
---@field expires integer
---@field dialog BookThemeQR|nil
---@field timeout function
---@field pending boolean|nil
---@field done boolean|nil
local Verification = {}
Verification.__index = Verification
---@type table<string, KuaikanVerification>
local sessions = {}

function Verification:cancel()
    if self.done then return end
    self.done = true
    sessions[self.ticket] = nil
    require("ui/uimanager"):unschedule(self.timeout)
    self.session:cancel()
    local dialog = self.dialog
    self.dialog = nil
    if dialog then dialog:close() end
    self.submit = nil
end

function Verification:finish(result, err)
    if self.done then return end
    self:cancel()
    self.callback(result, err)
end

---@param session KuaikanLogin
---@param submit fun(captcha: table, cb: function)
---@param cb fun(result: any, err: string|nil)
---@return KuaikanVerification
function Verification.new(session, submit, cb)
    local self = setmetatable({
        session = session, submit = submit, callback = cb,
        ticket = require("utils.random").hex(24), expires = os.time() + 300,
    }, Verification)
    self.timeout = require("ui.guard").wrap("kuaikan verification timeout", function()
        self:finish(nil, _("验证已过期，请重新发起验证"))
    end)
    sessions[self.ticket] = self
    require("ui/uimanager"):scheduleIn(300, self.timeout)
    self.dialog = Ext.call("web.open_page", "/kuaikan_verify.html#" .. self.ticket,
        _("快看安全验证"), _("用同一 Wi-Fi 下的手机扫码完成安全验证；手机号、密码和短信码只在设备填写。"), {
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
            appid = "2034681882", title = _("快看安全验证"), instruction = _("请完成下方安全验证"),
            pending = _("正在提交验证…"), success = _("验证已提交，请回到设备查看结果。"),
            failure = _("验证失败，请重新验证"), load_error = _("滑块加载失败，请检查网络后刷新网页"),
            cancelled = _("验证已取消"), retry = _("重试"),
        })
    end
    if type(params.captcha_ticket) ~= "string" or params.captcha_ticket == "" or #params.captcha_ticket > 4096
        or params.captcha_ticket:match("^trerror_") or type(params.randstr) ~= "string"
        or params.randstr == "" or #params.randstr > 256 then
        return reply(400, { error = _("验证凭据无效") })
    end
    if self.pending then return reply(409, { error = _("正在提交验证…") }) end
    self.pending = true
    local submit = assert(self.submit, "active verification has no submission")
    submit({ ticket = params.captcha_ticket, random = params.randstr }, function(result, err)
        if self.done then return reply(403, { error = _("验证已过期，请重新发起验证") }) end
        if os.time() >= self.expires then
            self:finish(nil, _("验证已过期，请重新发起验证"))
            return reply(403, { error = _("验证已过期，请重新发起验证") })
        end
        if result then reply(200, { ok = true })
        else reply(400, { error = _("验证或登录失败，请回到设备查看并重试") }) end
        self:finish(result, err)
    end)
end

local dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
Ext.add("web.routes", {
    name = "kuaikan_verify", dir = dir .. "web",
    assets = { "kuaikan_verify.html", "kuaikan_verify.js" },
    public = { config = true, verify = true }, handle = handle,
})

return Verification
