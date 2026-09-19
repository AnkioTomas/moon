--[[--
番茄小说扫码登录。

流程：
  1. GET 登录页预热 cookie (passport_csrf_token)
  2. GET /passport/web/get_qrcode/ 获取二维码 token + qrcode_index_url
  3. 轮询 GET /passport/web/check_qrconnect/?token=... 直到 jar 出现 sessionid

网络只走 http.request；cookie jar 本地维护，登录成功后才写 settings。
allow_redirects=false，手动跟跳以保留中间 Set-Cookie。

@module koplugin.book.source.fanqie.qrlogin
--]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local QRMessage = require("ui/widget/qrmessage")
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local Request = require("http.request")

local Cookie = require("source.fanqie.cookie")
local H = require("source.fanqie.helper")
local Log = require("source.fanqie.logger")
local JSON = require("json")
local _ = require("gettext")

local QRLogin = {}
QRLogin.__index = QRLogin

local LOGIN_PAGE = "https://fanqienovel.com/main/writer/login"
local GET_QRCODE_URL = "https://fanqienovel.com/passport/web/get_qrcode/"
local CHECK_QR_URL = "https://fanqienovel.com/passport/web/check_qrconnect/"
local FANQIE_LOGIN_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    .. "(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0"

local POLL_INTERVAL = 2
local QR_TIMEOUT = 300

local COMMON_PARAMS = {
    passport_jssdk_version = "3.0.16",
    passport_jssdk_type = "normal",
    aid = "2503",
    language = "zh",
    account_sdk_source = "web",
}

local function build_query(params)
    local parts = {}
    for k, v in pairs(params) do
        parts[#parts + 1] = tostring(k) .. "=" .. H.url_encode(tostring(v))
    end
    table.sort(parts)
    return table.concat(parts, "&")
end

local function extract_csrf(jar)
    if not jar then return "" end
    return jar["passport_csrf_token"] or ""
end

local function absolute_url(base, location)
    if not location or location == "" then return nil end
    if location:match("^https?://") then return location end
    local scheme, host = tostring(base or ""):match("^(https?)://([^/]+)")
    if not scheme then return location end
    if location:sub(1, 1) == "/" then
        return scheme .. "://" .. host .. location
    end
    local prefix = tostring(base):match("^(https?://.*/)") or (scheme .. "://" .. host .. "/")
    return prefix .. location
end

--- @param client  source.fanqie.client（保留签名兼容，HTTP 不经它，避免扫码中途污染 settings）
--- @param settings source.fanqie.settings
--- @param plugin   提供 showBusy/closeBusy
function QRLogin:new(client, settings, plugin)
    local self = setmetatable({}, QRLogin)
    self.client = client
    self.settings = settings
    self.plugin = plugin
    self.generation = 0
    self.jar = {}
    self.dialog = nil
    self.retry_dialog = nil
    self.started = 0
    self.poll_failures = 0
    self.login_completed = false
    self._job = nil
    return self
end

function QRLogin:toast(text)
    UIManager:show(InfoMessage:new{ text = tostring(text) })
end

function QRLogin:_close_dialog()
    if self.dialog then
        local d = self.dialog
        self.dialog = nil
        UIManager:close(d)
    end
end

function QRLogin:_close_retry_dialog()
    if self.retry_dialog then
        local d = self.retry_dialog
        self.retry_dialog = nil
        UIManager:close(d)
    end
end

function QRLogin:_cancel_job()
    if self._job and self._job.cancel then
        self._job.cancel()
    end
    self._job = nil
end

function QRLogin:cancel()
    self.generation = self.generation + 1
    self.login_completed = false
    self:_cancel_job()
    self:_close_dialog()
    self:_close_retry_dialog()
    self.jar = {}
    self.started = 0
    self.poll_failures = 0
    self.plugin:closeBusy()
end

function QRLogin:start()
    self:_begin()
end

--- 底层 GET：allow_redirects=false；2xx/3xx 都算成功。
---@param url string
---@param jar table|nil
---@param csrf string|nil
---@param cb fun(res: table|nil, err: string|nil)
---@return { cancel: fun() }
function QRLogin:_http_get(url, jar, csrf, cb)
    local headers = {
        ["User-Agent"] = FANQIE_LOGIN_UA,
        ["Accept"] = "application/json, text/javascript, text/html, */*",
        ["Accept-Language"] = "zh-CN,zh;q=0.9",
        ["Referer"] = LOGIN_PAGE,
        ["sec-fetch-dest"] = "empty",
        ["sec-fetch-mode"] = "cors",
        ["sec-fetch-site"] = "same-origin",
    }
    if jar and next(jar) ~= nil then
        headers["Cookie"] = Cookie.to_header(jar)
    end
    if csrf and csrf ~= "" then
        headers["x-tt-passport-csrf-token"] = csrf
    end
    return Request.request({
        url = url,
        method = "GET",
        headers = headers,
        timeout = 15,
        allow_redirects = false,
    }, function(res, err)
        if err then
            cb(nil, tostring(err))
            return
        end
        local code = tonumber(res and res.code)
        if not code then
            cb(nil, "HTTP 无响应码")
            return
        end
        if code < 200 or code >= 400 then
            cb(nil, "HTTP " .. tostring(code))
            return
        end
        cb(res)
    end)
end

function QRLogin:_begin()
    self:cancel()
    local gen = self.generation
    self.started = os.time()
    self.plugin:showBusy(_("获取二维码中..."))
    Log.info("[FanQieQR] 开始获取二维码")

    self._job = self:_http_get(LOGIN_PAGE, nil, nil, function(login_res, login_err)
        if gen ~= self.generation then return end
        if not login_res then
            self.plugin:closeBusy()
            Log.warn("[FanQieQR] 预热失败:", login_err)
            self:show_retry(_("获取二维码失败:") .. "\n" .. tostring(login_err))
            return
        end
        local jar = Cookie.merge_set_cookie({}, Request.header(login_res, "Set-Cookie"))
        local csrf = extract_csrf(jar)

        local params = {}
        for k, v in pairs(COMMON_PARAMS) do params[k] = v end
        params["need_logo"] = "true"
        params["next"] = LOGIN_PAGE
        local qr_url = GET_QRCODE_URL .. "?" .. build_query(params)

        self._job = self:_http_get(qr_url, jar, csrf, function(qr_res, qr_err)
            self.plugin:closeBusy()
            if gen ~= self.generation then return end
            if not qr_res then
                Log.warn("[FanQieQR] 获取二维码失败:", qr_err)
                self:show_retry(_("获取二维码失败:") .. "\n" .. tostring(qr_err))
                return
            end
            jar = Cookie.merge_set_cookie(jar, Request.header(qr_res, "Set-Cookie"))
            csrf = extract_csrf(jar)

            local ok, data = pcall(JSON.decode, qr_res.body or "")
            if not ok or type(data) ~= "table" then
                self:show_retry(_("获取二维码失败:") .. "\n二维码响应非 JSON")
                return
            end
            if data.message ~= "success" then
                self:show_retry(_("获取二维码失败:") .. "\n接口返回: " .. tostring(data.message))
                return
            end
            local d = data.data or {}
            local token = d.token or ""
            local qr_index_url = d.qrcode_index_url or ""
            if token == "" or qr_index_url == "" then
                self:show_retry(_("获取二维码失败:") .. "\n二维码数据不完整")
                return
            end

            self.jar = jar
            local size = math.floor(math.min(Device.screen:getWidth(), Device.screen:getHeight()) * 0.72)
            local dialog
            dialog = QRMessage:new{
                text = qr_index_url,
                width = size,
                height = size,
                scale_factor = 0.9,
                dismiss_callback = function()
                    if self.dialog == dialog then self.dialog = nil end
                    if gen == self.generation and not self.login_completed then
                        self:cancel()
                        self:toast(_("已取消登录"))
                    end
                end,
            }
            self.dialog = dialog
            UIManager:show(dialog)
            Log.info("[FanQieQR] 二维码已显示，开始轮询 token=", tostring(token):sub(1, 12))
            self:_schedule(gen, token, csrf, tonumber(d.expire_time) or 0)
        end)
    end)
end

function QRLogin:_schedule(gen, token, csrf, expire_time)
    if gen ~= self.generation then return end
    if os.time() - self.started > QR_TIMEOUT then
        self:show_retry(_("二维码已过期"))
        return
    end
    if expire_time and expire_time > 0 and os.time() > expire_time then
        self:show_retry(_("二维码已过期"))
        return
    end

    local params = {}
    for k, v in pairs(COMMON_PARAMS) do params[k] = v end
    params["token"] = token
    params["next"] = "/"
    local url = CHECK_QR_URL .. "?" .. build_query(params)

    -- 禁用自动重定向：302 + Set-Cookie(sessionid) 必须自己吃。
    self._job = self:_http_get(url, self.jar, csrf, function(res, err)
        if gen ~= self.generation then return end
        if not res then
            self.poll_failures = (self.poll_failures or 0) + 1
            if self.poll_failures == 1 or self.poll_failures % 5 == 0 then
                Log.warn("[FanQieQR] 轮询失败 #" .. self.poll_failures .. ":", err)
            end
            UIManager:scheduleIn(POLL_INTERVAL, function()
                self:_schedule(gen, token, csrf, expire_time)
            end)
            return
        end
        self.poll_failures = 0

        local raw_set_cookie = Request.header(res, "Set-Cookie") or ""
        local new_jar = Cookie.merge_set_cookie(self.jar, raw_set_cookie)
        self.jar = new_jar
        local has_sessionid = new_jar.sessionid and new_jar.sessionid ~= ""

        Log.debug("[FanQieQR] 轮询 Set-Cookie(前300): " .. tostring(raw_set_cookie):sub(1, 300))
        Log.debug("[FanQieQR] has_sessionid=" .. tostring(has_sessionid))

        if has_sessionid then
            self:_finish_login_success(gen)
            return
        end

        local data
        local text = res.body
        if text and #text > 0 then
            local ok, parsed = pcall(JSON.decode, text)
            if ok and type(parsed) == "table" then
                data = parsed
            end
        end

        if not data then
            local location = Request.header(res, "Location") or ""
            Log.debug("[FanQieQR] 非JSON响应, location=" .. tostring(location):sub(1, 100))
            UIManager:scheduleIn(POLL_INTERVAL, function()
                self:_schedule(gen, token, csrf, expire_time)
            end)
            return
        end

        local d = data.data or {}
        local status = d.status or ""
        if status == "confirmed" or status == "success" then
            Log.info("[FanQieQR] 确认状态 data=" .. tostring(text):sub(1, 500))
        end

        if status == "success" or status == "confirmed" then
            Log.info("[FanQieQR] 用户已确认 status=" .. status)
            if d.redirect_url and d.redirect_url ~= "" then
                self:_finish_with_redirect(gen, d.redirect_url, csrf)
            else
                Log.warn("[FanQieQR] " .. status .. " 但无 redirect_url")
                self:_finish_login_success(gen)
            end
        elseif status == "expired" then
            self:show_retry(_("二维码已过期"))
        else
            if status == "scanned" or status == "confirming" or status == "confirm" then
                Log.info("[FanQieQR] 用户已扫码/确认中 status=", status)
            else
                Log.debug("[FanQieQR] 轮询中 status=", status)
            end
            UIManager:scheduleIn(POLL_INTERVAL, function()
                self:_schedule(gen, token, csrf, expire_time)
            end)
        end
    end)
end

function QRLogin:_finish_with_redirect(gen, redirect_url, csrf)
    if gen ~= self.generation then return end
    self.plugin:showBusy(_("正在完成登录..."))
    Log.info("[FanQieQR] 访问 redirect_url:", tostring(redirect_url):sub(1, 80))

    local max_redirects = 5
    local hop = 0
    local url = redirect_url

    local function step()
        if gen ~= self.generation then return end
        hop = hop + 1
        if hop > max_redirects + 1 then
            self.plugin:closeBusy()
            self:show_retry(_("完成登录失败:") .. "\n重定向次数超限，未获取到 sessionid")
            return
        end
        self._job = self:_http_get(url, self.jar, csrf, function(res, err)
            if gen ~= self.generation then return end
            if not res then
                self.plugin:closeBusy()
                Log.warn("[FanQieQR] 访问 redirect_url 失败:", err)
                self:show_retry(_("完成登录失败:") .. "\n" .. tostring(err))
                return
            end
            self.jar = Cookie.merge_set_cookie(self.jar, Request.header(res, "Set-Cookie"))
            if self.jar.sessionid and self.jar.sessionid ~= "" then
                Log.info("[FanQieQR] 第" .. hop .. "跳获取到 sessionid")
                self.plugin:closeBusy()
                self:_finish_login_success(gen)
                return
            end
            local location = absolute_url(url, Request.header(res, "Location"))
            if not location then
                self.plugin:closeBusy()
                local keys = {}
                for k in pairs(self.jar) do keys[#keys + 1] = k end
                Log.warn("[FanQieQR] redirect 后仍无 sessionid, jar keys=" .. table.concat(keys, ","))
                self:show_retry(_("登录失败：未获取到 sessionid"))
                return
            end
            Log.debug("[FanQieQR] 重定向第" .. hop .. "跳 -> " .. tostring(location):sub(1, 80))
            url = location
            step()
        end)
    end
    step()
end

function QRLogin:_finish_login_success(gen)
    if gen ~= self.generation then return end
    local jar = {}
    for k, v in pairs(self.jar) do jar[k] = v end
    self.login_completed = true
    self.generation = self.generation + 1
    self:_cancel_job()
    self:_close_dialog()
    local keys = {}
    local count = 0
    for k in pairs(jar) do
        keys[#keys + 1] = k
        count = count + 1
    end
    table.sort(keys)
    Log.info("[FanQieQR] 登录成功，扫码获取到 " .. count .. " 个 cookie: " .. table.concat(keys, ", "))
    self.settings:set("cookies", jar)
    self.settings:flush()
    self.jar = jar
    self:toast(_("登录成功"))
end

function QRLogin:show_retry(msg)
    self.generation = self.generation + 1
    self:_cancel_job()
    self:_close_dialog()
    local dialog
    dialog = ButtonDialog:new{
        title = tostring(msg),
        title_align = "center",
        buttons = {
            {
                {
                    text = _("重新获取"),
                    callback = function()
                        if self.retry_dialog == dialog then self.retry_dialog = nil end
                        UIManager:close(dialog)
                        self:_begin()
                    end,
                },
                {
                    text = _("取消"),
                    callback = function()
                        if self.retry_dialog == dialog then self.retry_dialog = nil end
                        UIManager:close(dialog)
                        self:cancel()
                    end,
                },
            },
        },
    }
    self.retry_dialog = dialog
    UIManager:show(dialog)
end

return QRLogin
