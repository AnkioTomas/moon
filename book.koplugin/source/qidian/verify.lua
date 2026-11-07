--[[--
起点图形 / 腾讯验证码桥。浏览器只提交验证码凭据，匿名会话、手机号、短信码留在设备。

@module source.qidian.verify
--]]

require("l10n").apply()
local Ext = require("utils.extension")
local _ = require("gettext")
---@class QidianVerification
---@field session QidianLogin
---@field challenge table
---@field submit fun(proof: string, cb: fun(data: table|nil, err: string|nil))
---@field callback fun(data: table|nil, err: string|nil)
---@field ticket string
---@field expires integer
---@field timeout function
---@field dialog BookThemeQR|nil
---@field done boolean|nil
---@field pending boolean|nil
local Verification = {}
Verification.__index = Verification
local sessions = {}

function Verification:finish(result, err)
    if self.done then return end
    self.done = true
    sessions[self.ticket] = nil
    require("ui/uimanager"):unschedule(self.timeout)
    local dialog = self.dialog
    self.dialog = nil
    if dialog then dialog:close() end
    self.callback(result, err)
end

function Verification:cancel()
    if self.done then return end
    self.session:interrupt()
    self:finish(nil, _("验证已取消"))
end

function Verification.new(session, challenge, submit, cb)
    local self = setmetatable({
        session = session, challenge = challenge, submit = submit, callback = cb,
        ticket = require("utils.random").hex(24), expires = os.time() + 300,
    }, Verification)
    self.timeout = require("ui.guard").wrap("qidian verification timeout", function()
        self.session:interrupt()
        self:finish(nil, _("验证已过期，请重新发起验证"))
    end)
    sessions[self.ticket] = self
    require("ui/uimanager"):scheduleIn(300, self.timeout)
    self.dialog = Ext.call("web.open_page", "/qidian_verify.html#" .. self.ticket,
        _("起点安全验证"), _("用同一 Wi-Fi 下的手机扫码完成安全验证；手机号、密码和短信码只在设备填写。"), {
            close_callback = function() self:cancel() end,
        })
    if not self.dialog then self:finish(nil, _("无法打开远程验证，请先连接 Wi-Fi 并启用远程管理功能")) end
    return self
end

local function handle(method, action, params, cb)
    local function reply(status, body) cb(status, body, { "Cache-Control: no-store" }) end
    if method ~= "POST" then reply(405, { error = "Method Not Allowed" }); return end
    local self = type(params.ticket) == "string" and sessions[params.ticket]
    if not self or os.time() >= self.expires then
        reply(403, { error = _("验证已过期，请重新发起验证") }); return
    end
    if self.pending then reply(409, { error = _("正在提交验证…") }); return end
    if action == "config" or action == "refresh" then
        local function config(challenge, err)
            if self.done or os.time() >= self.expires then reply(403, { error = _("验证已过期，请重新发起验证") }); return end
            if not challenge then reply(400, { error = err }); return end
            local mode = tonumber(challenge.nextAction) == 11 and "tencent" or "image"
            local function ready(image, reason)
                self.pending = false
                if self.done then reply(403, { error = _("验证已取消") }); return end
                if mode == "image" and not image then reply(400, { error = reason }); return end
                reply(200, {
                    mode = mode, image = image,
                    appid = challenge.imgSrc:match("[?&]aid=(%d+)") or "1600000770",
                    title = _("起点安全验证"), instruction = _("请完成下方安全验证"),
                    pending = _("正在提交验证…"), success = _("验证已提交，请回到设备查看结果。"),
                    failure = _("验证失败，请重新验证"), retry = _("刷新验证码"), submit = _("提交"),
                })
            end
            if mode == "tencent" then
                if not challenge.imgSrc:find("TCaptcha.js", 1, true) then
                    self.pending = false
                    reply(400, { error = _("起点登录需要未支持的验证") }); return
                end
                ready(nil)
            else
                self.pending = true
                self.session:imageAsync(challenge.imgSrc, ready)
            end
        end
        if action == "refresh" then
            self.pending = true
            self.session:beginAsync(function(data, err)
                self.pending = false
                if not data or type(data.imgSrc) ~= "string" or data.imgSrc == "" then
                    config(nil, err or _("起点验证码刷新失败")); return
                end
                data.nextAction = data.imgSrc:find("TCaptcha.js", 1, true) and 11 or 8
                self.challenge = data
                config(data)
            end)
        else config(self.challenge) end
        return
    end
    if action ~= "verify" then reply(404, { error = "Not Found" }); return end
    local proof
    if tonumber(self.challenge.nextAction) == 11 then
        if type(params.captcha_ticket) ~= "string" or params.captcha_ticket == "" or #params.captcha_ticket > 4096
            or params.captcha_ticket:match("^trerror_") or type(params.randstr) ~= "string"
            or params.randstr == "" or #params.randstr > 256 then
            reply(400, { error = _("验证凭据无效") }); return
        end
        proof = params.randstr .. ";" .. params.captcha_ticket
    else
        if type(params.code) ~= "string" or params.code == "" or #params.code > 32 then
            reply(400, { error = _("请输入验证码") }); return
        end
        proof = params.code
    end
    self.pending = true
    self.submit(proof, function(data, err)
        if self.done then reply(403, { error = _("验证已取消") }); return end
        if os.time() >= self.expires then
            self:cancel()
            reply(403, { error = _("验证已过期，请重新发起验证") }); return
        end
        if data and tonumber(data.nextAction) == 0 then reply(200, { ok = true })
        else reply(400, { error = err or _("验证失败，请重新验证") }) end
        self:finish(data, err)
    end)
end

Ext.add("web.routes", {
    name = "qidian_verify", dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") .. "web",
    assets = { "qidian_verify.html", "qidian_verify.js" },
    public = { config = true, refresh = true, verify = true }, handle = handle,
})

return Verification
