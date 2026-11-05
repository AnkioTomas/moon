--[[--
长佩滑块验证：一次开章拥有一个会话，票据仅能提交验证，不能访问远程管理的其它接口。
五分钟后、关窗或取消开书即销毁；Cookie 留在设备，不发送到网页。

@module koplugin.book.source.changpei.verify
--]]

require("l10n").apply()

local Ext = require("utils.extension")
local Random = require("utils.random")
local Client = require("source.changpei.client")
local _ = require("gettext")

---@class ChangpeiVerification
---@field ticket string
---@field cookie string|nil
---@field callback fun(ok: boolean, err: string|nil)
---@field expires integer
---@field dialog BookThemeQR|nil
---@field pending table|nil
---@field timeout function
---@field done boolean|nil
local Verification = {}
Verification.__index = Verification

---@type table<string, ChangpeiVerification>
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

---@param cb fun(ok: boolean, err: string|nil)
---@return ChangpeiVerification
function Verification.new(cb)
    local self = setmetatable({
        ticket = Random.hex(24), cookie = Client.cookie(), callback = cb, expires = os.time() + 300,
    }, Verification)
    self.timeout = require("ui.guard").wrap("source verification timeout", function()
        self:finish(false, _("验证已过期，请重新发起验证"))
    end)
    sessions[self.ticket] = self
    require("ui/uimanager"):scheduleIn(300, self.timeout)
    self.dialog = Ext.call("web.open_page", "/changpei_verify.html#" .. self.ticket,
        _("长佩滑块验证"), _("用同一 Wi-Fi 下的手机扫码，在网页完成滑块验证后自动继续阅读。无需重新登录或安装浏览器扩展。"), {
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
    if not session or os.time() >= session.expires or session.cookie ~= Client.cookie() then
        return reply(403, { error = _("验证已过期，请重新发起验证") })
    end
    if action == "config" then
        return reply(200, {
            title = _("长佩滑块验证"), instruction = _("请按住滑块，拖动到最右边"),
            pending = _("正在提交验证…"),
            success = _("验证成功，已在设备上继续打开章节。"),
            failure = _("验证失败，请重新滑动验证"),
            load_error = _("滑块加载失败，请检查网络后刷新网页"),
            retry = _("重试"),
        })
    end
    if type(params.token) ~= "string" or params.token == "" or #params.token > 16384 then
        return reply(400, { error = _("验证凭据无效") })
    end
    if session.pending then return reply(409, { error = _("正在提交验证…") }) end
    local operation = {}
    session.pending = operation
    operation.job = Client.readCheckAsync(params.token, function(ok, message)
        if session.done then return reply(403, { error = _("验证已过期，请重新发起验证") }) end
        if session.pending ~= operation then return end
        if os.time() >= session.expires or session.cookie ~= Client.cookie() then
            session:finish(false, _("验证已过期，请重新发起验证"))
            return reply(403, { error = _("验证已过期，请重新发起验证") })
        end
        session.pending = nil
        if not ok then return reply(400, { error = message or _("验证失败，请重新滑动验证") }) end
        reply(200, { ok = true })
        session:finish(true)
    end)
end

local dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
Ext.add("web.routes", {
    name = "changpei_verify", dir = dir .. "web",
    assets = { "changpei_verify.html", "changpei_verify.js" },
    public = { config = true, verify = true },
    handle = handle,
})

return Verification
