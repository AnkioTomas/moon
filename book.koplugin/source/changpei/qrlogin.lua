--[[--
长佩扫码登录。

官网登录页的扫码走 gRPC-web（POST /cp.UserExternal/<方法>，请求头 version / imei 必带，否则回「系统繁忙」）：
get_qrcode_token(scene="Login") → { token, uid }，二维码内容是固定的 transfer/login/middleware URL，用长佩 App 扫；
qrcode_polling(token) → { status, login_res, token }，status 1 待扫 / 2 已扫待确认 / 3 拒绝 / 4 通过 / 5 失效，
二维码过期时 grpc-status 非 0。登录态挂在服务端会话（PHPSESSID）上：先请求 webapi 拿到 PHPSESSID，
轮询带着它，通过后这个会话即已登录。设备号 `_c_n_` 是网页端随机生成的 MD5（同时作 imei 请求头），这里照做。
Cookie 交给 on_cookie，由设置页走账号校验再保存。

@module koplugin.book.source.changpei.qrlogin
--]]

require("l10n").apply()
local Request = require("http.request")
local _ = require("gettext")

local QRLogin = {}
QRLogin.__index = QRLogin

local ORIGIN = "https://www.gongzicp.com"
local POLL_INTERVAL = 2
local DEADLINE = 180

local STATUS_WAITING_AUTH, STATUS_REJECT, STATUS_APPROVED = 2, 3, 4

--- 一帧 gRPC-web：0x00 + 4 字节长度 + protobuf。只有一个字符串字段（默认 1，字段号 < 16、值 < 128 字节）。
---@param value string
---@param field? integer
---@return string
function QRLogin.frame(value, field)
    local msg = string.char((field or 1) * 8 + 2, #value) .. value
    local n = #msg
    return string.char(0, 0, 0, math.floor(n / 256), n % 256) .. msg
end

--- 解一帧里的顶层 protobuf 字段：varint → 数字，其余 → 字符串；同号取首个。
---@param body string
---@return table<integer, number|string>
function QRLogin.decode(body)
    return QRLogin.fields(#body < 5 and "" or body:sub(6))
end

--- 解一段裸 protobuf（不带 gRPC 帧头）。
---@param data string
---@return table<integer, number|string>
function QRLogin.fields(data)
    local out, pos = {}, 1
    local function varint()
        local value, shift = 0, 1
        while pos <= #data do
            local byte = data:byte(pos)
            pos = pos + 1
            value = value + (byte % 128) * shift
            if byte < 128 then return value end
            shift = shift * 128
        end
        return value
    end
    while pos <= #data do
        local tag = varint()
        local field, wire = math.floor(tag / 8), tag % 8
        local value
        if wire == 0 then
            value = varint()
        elseif wire == 2 then
            local len = varint()
            value = data:sub(pos, pos + len - 1)
            pos = pos + len
        else
            break
        end
        if out[field] == nil then out[field] = value end
    end
    return out
end

--- 回包 Set-Cookie 里的 name=value 收进 jar。
---@param jar table<string, string>
---@param res table
local function takeCookies(jar, res)
    for _idx, line in ipairs(Request.headerAll(res, "Set-Cookie")) do
        local name, value = line:match("^%s*([^=;%s]+)=([^;]*)")
        if name and value ~= "" and value ~= "deleted" then jar[name] = value end
    end
end

---@param jar table<string, string>
---@return string
local function cookieHeader(jar)
    local names = {}
    for name in pairs(jar) do names[#names + 1] = name end
    table.sort(names)
    for i, name in ipairs(names) do names[i] = name .. "=" .. jar[name] end
    return table.concat(names, "; ")
end

---@param on_cookie fun(cookie: string)
function QRLogin.new(_class, on_cookie)
    return setmetatable({ on_cookie = on_cookie, generation = 0, jar = {} }, QRLogin)
end

function QRLogin:toast(text)
    require("ui.themes.widgets.toast"):new{ text = text, timeout = 2 }:show()
end

---@param method string
---@param value string
---@param cb fun(fields: table|nil, res: table|nil, err: string|nil)
function QRLogin:_call(method, value, cb)
    local headers = {
        ["Content-Type"] = "application/grpc-web+proto",
        ["X-Grpc-Web"] = "1",
        ["Client"] = "pc",
        ["version"] = "1",
        ["imei"] = self.jar._c_n_,
        ["Referer"] = ORIGIN .. "/",
        ["User-Agent"] = require("source.changpei.client").USER_AGENT,
    }
    local cookie = cookieHeader(self.jar)
    if cookie ~= "" then headers["Cookie"] = cookie end
    self.job = Request.post(ORIGIN .. "/cp.UserExternal/" .. method, QRLogin.frame(value), {
        headers = headers,
        content_type = "application/grpc-web+proto",
        timeout = require("http.timeout").net(0.5),
    }, function(body, err, res)
        self.job = nil
        if not body then cb(nil, res, err and tostring(err) or _("请求失败")); return end
        takeCookies(self.jar, res)
        local status = tonumber(Request.header(res, "grpc-status")) or 0
        if status ~= 0 then cb(nil, res, "grpc " .. status); return end
        cb(QRLogin.decode(body), res)
    end)
end

function QRLogin:_closeDialog()
    local dialog = self.dialog
    self.dialog = nil
    if dialog then dialog:close() end
end

function QRLogin:cancel()
    self.generation = self.generation + 1
    if self.job then self.job.cancel(); self.job = nil end
    self:_closeDialog()
end

function QRLogin:_retry(text)
    self:cancel()
    require("ui.themes.widgets.confirm"):new{
        text = text,
        ok_text = _("重新获取"),
        ok_callback = function() self:start() end,
    }:show()
end

---@param gen integer
---@param token string
---@param started integer
function QRLogin:_poll(gen, token, started)
    self:_call("qrcode_polling", token, function(fields)
        if gen ~= self.generation then return end
        if not fields then
            -- grpc-status 非 0：二维码失效；网络错误同样重新获取，比无声地一直轮询好
            self:_retry(_("二维码已过期"))
            return
        end
        local status = fields[1]
        if status == STATUS_APPROVED then
            local cookie = self.jar.PHPSESSID and cookieHeader(self.jar)
            -- login_res(2).web_data(4).token(1)：网页端后续请求靠它认人；refresh_token(2) 在 token 失效时换新的
            local login = type(fields[2]) == "string" and QRLogin.fields(fields[2]) or {}
            local web = type(login[4]) == "string" and QRLogin.fields(login[4] --[[@as string]]) or {}
            require("utils.log").info("changpei qr approved", "login_status", login[1], "token", web[1] and #web[1] or 0,
                "refresh", type(web[2]) == "string" and #web[2] or 0)
            if cookie and type(web[1]) == "string" and web[1] ~= "" then
                cookie = cookie .. "; moon_token=" .. web[1]
                if type(web[2]) == "string" and web[2] ~= "" then cookie = cookie .. "; moon_refresh=" .. web[2] end
            end
            self:cancel()
            if not cookie then self:toast(_("登录失败：未获取到登录态")); return end
            self.on_cookie(cookie)
        elseif status == STATUS_REJECT then
            self:_retry(_("已在手机上拒绝登录"))
        elseif os.time() - started > DEADLINE then
            self:_retry(_("二维码已过期"))
        else
            if status == STATUS_WAITING_AUTH and not self.scanned then
                self.scanned = true
                self:toast(_("已扫码，请在手机上确认"))
            end
            require("ui/uimanager"):scheduleIn(POLL_INTERVAL, function()
                if gen == self.generation then self:_poll(gen, token, started) end
            end)
        end
    end)
end

function QRLogin:start()
    self:cancel()
    local gen = self.generation
    local device = ""
    for _i = 1, 32 do device = device .. string.format("%x", math.random(0, 15)) end
    self.jar, self.scanned = { _c_n_ = device, _c_n_n_ = device }, false
    self:_session(function(ok)
        if gen ~= self.generation then return end
        if not ok then
            self:toast(_("获取二维码失败"))
            return
        end
        self:_call("get_qrcode_token", "Login", function(fields)
            if gen ~= self.generation then return end
            self:_show(gen, fields)
        end)
    end)
end

--- webapi 的任何接口都会下发 PHPSESSID。
---@param cb fun(ok: boolean)
function QRLogin:_session(cb)
    local client = require("source.changpei.client")
    self.job = Request.get(ORIGIN .. "/webapi/system/init", {
        headers = { ["Client"] = "pc", ["User-Agent"] = client.USER_AGENT, ["Cookie"] = cookieHeader(self.jar) },
        timeout = require("http.timeout").net(0.5),
    }, function(_body, _err, res)
        self.job = nil
        if res then takeCookies(self.jar, res) end
        cb(self.jar.PHPSESSID ~= nil)
    end)
end

---@param gen integer
---@param fields table|nil
function QRLogin:_show(gen, fields)
    local token, uid = fields and fields[1], fields and fields[2]
    if type(token) ~= "string" or token == "" then
        self:toast(_("获取二维码失败"))
        return
    end
    local dialog
    dialog = require("ui.themes.widgets.qr"):new{
        title = _("长佩扫码登录"),
        text = ORIGIN .. "/transfer/login/middleware?token=" .. token .. "&uid=" .. tostring(uid or 0)
            .. "&pageType=app_qr_code_login",
        caption = _("用长佩 App 扫一扫"),
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
    self:_poll(gen, token, os.time())
end

return QRLogin
