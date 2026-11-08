--[[--
书旗发送短信前的阿里云滑块：浏览器只交滑块参数，手机号与短信码留在设备。
一次发送拥有一张五分钟票据。

@module koplugin.book.source.shuqi.verify
--]]


local Ext = require("utils.extension")
local Client = require("source.shuqi.client")
local _ = require("l10n").get("source.shuqi")

---@class ShuqiVerification
---@field ticket string
---@field phone string
---@field callback fun(ok: boolean, err: string|nil)
---@field expires integer
---@field dialog BookThemeQR|nil
---@field pending table|nil
---@field timeout function
---@field done boolean|nil
---@field browser table|nil
local Verification = {}
Verification.__index = Verification

---@type table<string, ShuqiVerification>
local sessions = {}

function Verification:cancel()
    if self.done then return end
    self.done = true
    sessions[self.ticket] = nil
    require("ui/uimanager"):unschedule(self.timeout)
    if self.pending and self.pending.job and self.pending.job.cancel then self.pending.job.cancel() end
    if self.dialog then self.dialog:close() end
end

function Verification:finish(ok, err)
    if self.done then return end
    self:cancel()
    self.callback(ok, err)
end

---@param phone string
---@param cb fun(ok: boolean, err: string|nil)
---@return ShuqiVerification
function Verification.new(phone, cb)
    local self = setmetatable({
        ticket = require("utils.random").hex(24), phone = phone,
        callback = cb, expires = os.time() + 300,
    }, Verification)
    self.timeout = require("ui.guard").wrap("shuqi verification timeout", function()
        self:finish(false, _("验证已过期，请重新发起验证"))
    end)
    sessions[self.ticket] = self
    require("ui/uimanager"):scheduleIn(300, self.timeout)
    self.dialog = Ext.call("web.open_page", "/shuqi_verify.html#" .. self.ticket,
        _("书旗滑块验证"), _("用同一 Wi-Fi 下的手机扫码，只完成滑块；短信验证码请回到设备填写。"), {
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
    if value == nil then return "" end
    if type(value) ~= "string" or #value > limit then return nil end
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
    if not session or os.time() >= session.expires then
        return reply(403, { error = _("验证已过期，请重新发起验证") })
    end
    if action == "config" then
        return reply(200, {
            title = _("书旗滑块验证"),
            instruction = _("拖动下方滑块完成验证"),
            pending = _("正在发送短信…"),
            success = _("验证通过，短信已发送，请回到设备填写验证码。"),
            failure = _("验证失败，请重新滑动"),
            load_error = _("登录验证脚本加载失败，可能被广告拦截插件阻止。请检查插件设置或网络，也可改用 Cookie 登录。"),
            load_timeout = _("登录验证脚本加载超时，可能被广告拦截插件阻止。请检查插件设置或网络后重试，也可改用 Cookie 登录。"),
            environment_error = _("登录环境初始化失败，请刷新重试"),
            retry = _("重试"),
        })
    end
    local captcha = bounded(params.captcha, 8192)
    local fingerprint = bounded(params.fingerprint, 256)
    local umidtoken = bounded(params.umidtoken, 4096)
    local wua = bounded(params.wua, 8192)
    local user_agent = bounded(params.user_agent, 512)
    if not captcha or captcha == "" or not fingerprint or not umidtoken or not wua then
        return reply(400, { error = _("验证凭据无效") })
    end
    if not user_agent or user_agent:find("[\r\n]") then return reply(400, { error = _("验证凭据无效") }) end
    if session.pending then return reply(409, { error = _("正在发送短信…") }) end
    local browser = { fingerprint = fingerprint, umidtoken = umidtoken, wua = wua, user_agent = user_agent }
    local operation = {}
    session.pending = operation
    operation.job = Client.sendCodeAsync(session.phone, captcha, function(ok, err)
        if session.done then return reply(403, { error = _("验证已过期，请重新发起验证") }) end
        if session.pending ~= operation then return end
        if os.time() >= session.expires then
            session:finish(false, _("验证已过期，请重新发起验证"))
            return reply(403, { error = _("验证已过期，请重新发起验证") })
        end
        session.pending = nil
        if not ok then return reply(400, { error = err or _("验证失败，请重新滑动") }) end
        session.browser = browser
        reply(200, { ok = true })
        session:finish(true)
    end, browser)
end

local dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
Ext.add("web.routes", {
    name = "shuqi_verify", dir = dir .. "web",
    assets = { "shuqi_verify.html", "shuqi_verify.js" },
    public = { config = true, verify = true }, handle = handle,
})

return Verification
