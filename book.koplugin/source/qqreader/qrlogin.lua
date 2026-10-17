--[[--
QQ阅读扫码登录。

阅文自己的码，用 QQ阅读或起点 App 扫，不是手机 QQ。
GET /login/qrcode 拿 sessionKey，二维码内容是固定的 scanlogin URL。
轮询 /login/qrcodelogin。scanStatus 5 时取 ywguid / ywkey；只有 302url 时跟跳收 Set-Cookie。
拿到 Cookie 交给 on_cookie，由设置页走现有账号校验再保存。

@module koplugin.book.source.qqreader.qrlogin
--]]

require("l10n").apply()
local JSON = require("json")
local Request = require("http.request")
local Text = require("utils.text")
local logger = require("utils.log")
local _ = require("gettext")

local QRLogin = {}
QRLogin.__index = QRLogin

local APP_ID = "1450000220"
local AREA_ID = "1"
local BASE = "https://ptlogin.yuewen.com"
local RETURN_URL = "https://book.qq.com/"
local POLL_INTERVAL = 3
local POLL_MAX = 40
local DEADLINE = 180
local MAX_HOPS = 5
local UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    .. "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

local KEEP = { ywguid = true, ywkey = true, ywopenid = true }

---@param value any
---@return string|nil
local function text(value)
    if type(value) == "string" and value ~= "" then return value end
    if type(value) == "number" then return tostring(value) end
end

---@param params table
---@return string
local function query(params)
    return Text.formEncode(params)
end

---@return table
local function baseParams()
    return {
        appId = APP_ID,
        areaId = AREA_ID,
        format = "json",
        returnurl = RETURN_URL,
        target = "top",
        ticket = "0",
        autotime = "14",
        auto = "0",
    }
end

--- 二维码内容。和官方图里的 URL 同一组参数，顺序无所谓。
---@param session_key string
---@return string
function QRLogin.scanUrl(session_key)
    return BASE .. "/mobile/scanlogin?" .. query({
        sessionkey = session_key,
        appid = APP_ID,
        areaid = AREA_ID,
        bookId = "0",
        chapterId = "0",
    })
end

---@param jar table
---@return string
local function cookieHeader(jar)
    local keys = {}
    for key, value in pairs(jar) do
        if KEEP[key] and value ~= "" then keys[#keys + 1] = key end
    end
    table.sort(keys)
    local parts = {}
    for i, key in ipairs(keys) do parts[i] = key .. "=" .. jar[key] end
    return table.concat(parts, "; ")
end

---@param jar table
---@param set_cookie string|table|nil
local function takeCookies(jar, set_cookie)
    if type(set_cookie) == "table" then
        for _key, value in pairs(set_cookie) do takeCookies(jar, value) end
        return
    end
    if type(set_cookie) ~= "string" or set_cookie == "" then return end
    for name, value in set_cookie:gmatch("([%w_]+)=([^;,]*)") do
        name = name:lower()
        value = value:match("^(.-)%s*$")
        if KEEP[name] and value ~= "" then jar[name] = value end
    end
end

---@param data table|nil
---@param jar table
local function takeJson(data, jar)
    if type(data) ~= "table" then return end
    local guid = text(data.ywGuid or data.ywguid)
    local key = text(data.ywKey or data.ywkey)
    local openid = text(data.ywOpenId or data.ywopenid)
    if guid then jar.ywguid = guid end
    if key then jar.ywkey = key end
    if openid then jar.ywopenid = openid end
    if type(data.data) == "table" then takeJson(data.data, jar) end
end

---@param jar table
---@return boolean
local function ready(jar)
    return jar.ywguid ~= nil and jar.ywguid ~= "" and jar.ywkey ~= nil and jar.ywkey ~= ""
end

---@param on_cookie fun(cookie: string)
function QRLogin.new(_class, on_cookie)
    local self = setmetatable({}, QRLogin)
    self.on_cookie = on_cookie
    self.generation = 0
    self.jar = {}
    self.dialog = nil
    self.retry_dialog = nil
    self.busy = nil
    self.job = nil
    self.started = 0
    self.polls = 0
    self.session = nil
    self.login_completed = false
    self.scanned_notified = false
    return self
end

function QRLogin:toast(text_msg)
    require("ui.themes.widgets.toast"):new{ text = tostring(text_msg), timeout = 2 }:show()
end

function QRLogin:closeBusy()
    if self.busy then
        self.busy:close()
        self.busy = nil
    end
end

function QRLogin:showBusy(text_msg)
    self:closeBusy()
    self.busy = require("ui.themes.widgets.progress_dialog"):new{
        title = _("QQ阅读扫码登录"), text = text_msg, dismissable = false,
    }
    self.busy:show()
end

function QRLogin:_close_dialog()
    if self.dialog then
        local dialog = self.dialog
        self.dialog = nil
        dialog:close()
    end
end

function QRLogin:_close_retry()
    if self.retry_dialog then
        local dialog = self.retry_dialog
        self.retry_dialog = nil
        dialog:close()
    end
end

function QRLogin:_cancel_job()
    if self.job and self.job.cancel then self.job.cancel() end
    self.job = nil
end

function QRLogin:cancel()
    self.generation = self.generation + 1
    self.login_completed = false
    self:_cancel_job()
    self:_close_dialog()
    self:_close_retry()
    self:closeBusy()
    self.jar = {}
    self.session = nil
    self.polls = 0
    self.scanned_notified = false
end

---@param url string
---@param cb fun(res: table|nil, err: string|nil)
function QRLogin:_get(url, cb)
    local headers = {
        ["User-Agent"] = UA,
        Accept = "application/json, text/javascript, */*",
        Referer = "https://login.book.qq.com/login.html",
    }
    local cookie = cookieHeader(self.jar)
    if cookie ~= "" then headers.Cookie = cookie end
    self.job = Request.request({
        url = url,
        method = "GET",
        headers = headers,
        timeout = require("http.timeout").net(0.5),
        allow_redirects = false,
    }, function(res, err)
        self.job = nil
        if err or not res then
            cb(nil, err and tostring(err) or _("请求失败"))
            return
        end
        local code = tonumber(res.code)
        if not code or code < 200 or code >= 400 then
            cb(nil, "HTTP " .. tostring(res.code))
            return
        end
        cb(res)
    end)
end

---@param res table|nil
---@return table|nil
local function decode(res)
    local body = res and res.body
    if type(body) ~= "string" or body == "" then return nil end
    local ok, wire = pcall(JSON.decode, body)
    if not ok or type(wire) ~= "table" then return nil end
    return wire
end

function QRLogin:_expired()
    return self.polls >= POLL_MAX or os.time() - self.started > DEADLINE
end

---@param gen integer
---@param session string
function QRLogin:_later(gen, session)
    require("ui/uimanager"):scheduleIn(POLL_INTERVAL, function()
        self:_poll(gen, session)
    end)
end

---@param gen integer
function QRLogin:_show(gen, session)
    if gen ~= self.generation then return end
    self:closeBusy()
    self.session = session
    self.polls = 0
    local dialog
    dialog = require("ui.themes.widgets.qr"):new{
        title = _("QQ阅读扫码登录"),
        text = QRLogin.scanUrl(session),
        caption = _("用 QQ阅读或起点 App 扫一扫"),
        close_callback = function()
            if self.dialog == dialog then self.dialog = nil end
            if gen == self.generation and not self.login_completed then
                self:cancel()
                self:toast(_("已取消登录"))
            end
        end,
    }
    self.dialog = dialog
    dialog:show()
    logger.info("[QQReaderQR] 二维码已显示")
    self:_later(gen, session)
end

function QRLogin:start()
    self:cancel()
    local gen = self.generation
    self.started = os.time()
    self.jar = {}
    self:showBusy(_("获取二维码中..."))
    local params = baseParams()
    self:_get(BASE .. "/login/qrcode?" .. query(params), function(res, err)
        if gen ~= self.generation then return end
        local wire = decode(res)
        local session = wire and type(wire.data) == "table" and text(wire.data.sessionKey)
        if not session or tonumber(wire.code) ~= 0 then
            self:closeBusy()
            logger.warn("[QQReaderQR] 获取二维码失败:", err or (wire and wire.message))
            self:show_retry(_("获取二维码失败"))
            return
        end
        self:_show(gen, session)
    end)
end

---@param gen integer
---@param jar table
function QRLogin:_done(gen, jar)
    if gen ~= self.generation or self.login_completed then return end
    if not ready(jar) then
        self:show_retry(_("登录失败：未获取到登录态"))
        return
    end
    self.login_completed = true
    self.generation = self.generation + 1
    self:_cancel_job()
    self:_close_dialog()
    self:_close_retry()
    self:closeBusy()
    local cookie = cookieHeader(jar)
    logger.info("[QQReaderQR] 登录态已拿到")
    if self.on_cookie then self.on_cookie(cookie) end
end

---@param gen integer
---@param url string
---@param hop integer
function QRLogin:_follow(gen, url, hop)
    if gen ~= self.generation then return end
    if type(url) ~= "string" or not url:match("^https://") or hop > MAX_HOPS then
        self:show_retry(_("登录失败：未获取到登录态"))
        return
    end
    self:showBusy(_("正在完成登录..."))
    self:_get(url, function(res, err)
        if gen ~= self.generation then return end
        if not res then
            logger.warn("[QQReaderQR] 跟跳失败:", err)
            self:show_retry(_("登录失败：未获取到登录态"))
            return
        end
        takeCookies(self.jar, Request.header(res, "Set-Cookie"))
        if ready(self.jar) then
            self:_done(gen, self.jar)
            return
        end
        local location = Text.absoluteUrl(url, Request.header(res, "Location"))
        if not location then
            self:show_retry(_("登录失败：未获取到登录态"))
            return
        end
        self:_follow(gen, location, hop + 1)
    end)
end

---@param gen integer
---@param session string
---@param wire table
---@param res table
function QRLogin:_on_poll(gen, session, wire, res)
    takeCookies(self.jar, Request.header(res, "Set-Cookie"))
    local data = type(wire.data) == "table" and wire.data or {}
    takeJson(data, self.jar)
    takeJson(wire, self.jar)
    local status = tonumber(wire.scanStatus)
    local code = tonumber(wire.code)
    if code == -11033 then
        self:show_retry(text(wire.message) or _("登录失败"))
        return
    end
    if status == 5 and code == 0 then
        if ready(self.jar) then
            self:_done(gen, self.jar)
            return
        end
        local jump = text(data["302url"]) or text(wire["302url"])
        if jump then
            self:_follow(gen, jump, 1)
            return
        end
        self:show_retry(_("登录失败：未获取到登录态"))
        return
    end
    if status == 3 then
        logger.info("[QQReaderQR] 手机取消，刷新二维码")
        self.generation = self.generation + 1
        self:_close_dialog()
        self:start()
        return
    end
    if status == 4 or self:_expired() then
        self:show_retry(_("二维码已过期"))
        return
    end
    if status == 1 and not self.scanned_notified then
        self.scanned_notified = true
        self.polls = 0
        self.started = os.time()
        self:toast(_("已扫码，请在手机上确认"))
    end
    self:_later(gen, session)
end

---@param gen integer
---@param session string
function QRLogin:_poll(gen, session)
    if gen ~= self.generation or session ~= self.session then return end
    if self:_expired() then
        self:show_retry(_("二维码已过期"))
        return
    end
    self.polls = self.polls + 1
    local params = baseParams()
    params.qrcode = session
    self:_get(BASE .. "/login/qrcodelogin?" .. query(params), function(res, err)
        if gen ~= self.generation or session ~= self.session then return end
        local wire = decode(res)
        if not wire then
            if self.polls == 1 or self.polls % 5 == 0 then
                logger.warn("[QQReaderQR] 轮询失败:", err)
            end
            if self:_expired() then
                self:show_retry(_("二维码已过期"))
                return
            end
            self:_later(gen, session)
            return
        end
        self:_on_poll(gen, session, wire, res)
    end)
end

function QRLogin:show_retry(msg)
    self.generation = self.generation + 1
    self:_cancel_job()
    self:_close_dialog()
    self:_close_retry()
    self:closeBusy()
    local dialog
    dialog = require("ui.themes.widgets.confirm"):new{
        text = tostring(msg),
        ok_text = _("重新获取"),
        ok_callback = function()
            if self.retry_dialog == dialog then self.retry_dialog = nil end
            self:start()
        end,
        cancel_callback = function()
            if self.retry_dialog == dialog then self.retry_dialog = nil end
            self:cancel()
        end,
    }
    self.retry_dialog = dialog
    dialog:show()
end

return QRLogin
