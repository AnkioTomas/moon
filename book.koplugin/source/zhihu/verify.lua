--[[--
知乎人机验证：浏览器只加载官方控件并交回票据，Cookie 与挑战提交留在设备。
每次验证持有原扫码会话，临时访问票据五分钟有效，关闭或取消后立即作废。

@module source.zhihu.verify
--]]


local Client = require("source.zhihu.client")
local Ext = require("utils.extension")
local _ = require("l10n").get("source.zhihu")

---@class ZhihuVerification
---@field ticket string
---@field session ZhihuQRSession
---@field callback fun(ok: boolean, err: string|nil)
---@field expires integer
---@field session_id string|nil
---@field pending table|nil
---@field dialog BookThemeQR|nil
---@field timeout function
---@field done boolean|nil
local Verification = {}
Verification.__index = Verification

---@type table<string, ZhihuVerification>
local sessions = {}

function Verification:cancel()
    if self.done then return end
    self.done = true
    sessions[self.ticket] = nil
    require("ui/uimanager"):unschedule(self.timeout)
    if self.pending and self.pending.job then self.pending.job.cancel() end
    if self.dialog then self.dialog:close() end
end

function Verification:finish(ok, err)
    if self.done then return end
    self:cancel()
    self.callback(ok, err)
end

---@param session ZhihuQRSession
---@param cb fun(ok: boolean, err: string|nil)
---@return ZhihuVerification
function Verification.new(session, cb)
    local self = setmetatable({
        ticket = require("utils.random").hex(24), session = session,
        callback = cb, expires = os.time() + 300,
    }, Verification)
    self.timeout = require("ui.guard").wrap("zhihu verification timeout", function()
        self:finish(false, _("验证已过期，请重新发起验证"))
    end)
    sessions[self.ticket] = self
    require("ui/uimanager"):scheduleIn(300, self.timeout)
    self.dialog = Ext.call("web.open_page", "/zhihu_verify.html#" .. self.ticket,
        _("知乎安全验证"), _("用同一 Wi-Fi 下的手机扫码完成安全验证，或在本机打开。验证后自动重新显示登录二维码。"), {
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
    if not session or os.time() >= session.expires then
        return reply(403, { error = _("验证已过期，请重新发起验证") })
    end
    if session.pending then return reply(409, { error = _("正在提交验证…") }) end
    if action == "verify" and (not session.session_id or type(params.result) ~= "string"
        or params.result == "" or #params.result > 16384) then
        return reply(400, { error = _("验证凭据无效") })
    end
    local operation = {}
    session.pending = operation
    local function completed()
        if session.done or os.time() >= session.expires then
            session:finish(false, _("验证已过期，请重新发起验证"))
            reply(403, { error = _("验证已过期，请重新发起验证") })
            return false
        end
        session.pending = nil
        return true
    end
    if action == "config" then
        session.session_id = nil
        operation.job = Client.qrCaptchaAsync(session.session, function(config, err)
            if not completed() then return end
            if not config then return reply(400, { error = err or _("滑块加载失败，请检查网络后刷新网页") }) end
            session.session_id = config.session_id
            reply(200, {
                scripts = config.scripts,
                title = _("知乎安全验证"), instruction = _("请完成下方安全验证，验证后回到设备用知乎 App 扫码登录。"),
                pending = _("正在提交验证…"), success = _("验证成功，请回到设备继续扫码登录。"),
                failure = _("验证失败，请重新验证"), load_error = _("滑块加载失败，请检查网络后刷新网页"),
                retry = _("重试"),
            })
        end)
    else
        operation.job = Client.qrVerifyAsync(session.session, session.session_id, params.result, function(ok, err)
            if not completed() then return end
            if not ok then return reply(400, { error = err or _("验证失败，请重新验证") }) end
            reply(200, { ok = true })
            session:finish(true)
        end)
    end
end

local dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
Ext.add("web.routes", {
    name = "zhihu_verify", dir = dir .. "web",
    assets = { "zhihu_verify.html", "zhihu_verify.js" },
    public = { config = true, verify = true }, handle = handle,
})

return Verification
