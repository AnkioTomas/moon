--[[--
京东账号扫码登录：二维码 PNG → 状态轮询 → ticket 换取 .jd.com 会话。

@module koplugin.book.source.jdread.auth
--]]

local JSON = require("json")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("gettext")

local Auth = {}

local LOGIN_PAGE = "https://passport.jd.com/new/login.aspx?ReturnUrl=https%3A%2F%2Fe.m.jd.com%2F"
local LOGIN_UA = Request.randomUA()
local login_jar = {}

---@return table
local function cfg()
    return require("utils.settings").getSource("jdread")
end

---@param patch table
local function saveCfg(patch)
    local Settings = require("utils.settings")
    local current = Settings.getSource("jdread")
    for key, value in pairs(patch) do current[key] = value end
    Settings.saveSource("jdread", current)
end

---@param res table|nil
local function mergeCookies(res)
    local values = Request.header(res, "Set-Cookie")
    if type(values) == "string" then values = { values } end
    for _, line in ipairs(type(values) == "table" and values or {}) do
        local key, value = line:match("^%s*([^=;]+)=([^;]*)")
        if key then
            if value == "" then login_jar[key] = nil else login_jar[key] = value end
        end
    end
end

---@param jar table
---@return string|nil
local function cookieHeader(jar)
    local keys = {}
    for key, value in pairs(jar) do
        if type(value) == "string" and value ~= "" then keys[#keys + 1] = key end
    end
    table.sort(keys)
    if #keys == 0 then return nil end
    local parts = {}
    for _, key in ipairs(keys) do parts[#parts + 1] = key .. "=" .. jar[key] end
    return table.concat(parts, "; ")
end

---@return table
local function browserHeaders()
    return {
        ["Accept"] = "application/json, text/javascript, */*; q=0.01",
        ["Cookie"] = cookieHeader(login_jar),
        ["Referer"] = LOGIN_PAGE,
        ["User-Agent"] = LOGIN_UA,
    }
end

---@return string
local function timestamp()
    return tostring(os.time() * 1000 + math.random(0, 999))
end

---@return string
local function qrPath()
    local Paths = require("utils.paths")
    Paths.ensureLayout("jdread")
    return Paths.imageDir("jdread") .. "/login-qr.png"
end

---@return boolean
function Auth.hasSession()
    local cookie = cfg().cookie
    return type(cookie) == "string" and cookie ~= ""
end

---@return string|nil
function Auth.userLabel()
    local current = cfg()
    if type(current.user_name) == "string" and current.user_name ~= "" then
        return current.user_name
    end
    return nil
end

--- 清除账号会话，保留设备 UUID。
function Auth.clearSession()
    saveCfg({ cookie = "", user_name = "" })
end

--- 获取二维码 PNG 及轮询所需 Cookie。
---@param cb fun(data: { qr_path: string, token: string }|nil, err: string|nil)
---@return { cancel: fun() }
function Auth.beginQrLoginAsync(cb)
    login_jar = {}
    local path = qrPath()
    pcall(os.remove, path)
    local cancelled = false
    local url = "https://qr.m.jd.com/show?" .. Text.formEncode({
        appid = 133,
        size = 147,
        t = timestamp(),
    })
    local job = Request.get(url, {
        headers = browserHeaders(),
        timeout = 30,
    }, function(body, err, res)
        if cancelled then return end
        mergeCookies(res)
        local token = login_jar.wlfstk_smdl
        if not body or body:sub(1, 8) ~= "\137PNG\r\n\26\n"
            or type(token) ~= "string" or token == "" then
            cb(nil, err or _("获取京东登录二维码失败"))
            return
        end
        local file, open_err = io.open(path, "wb")
        if not file then cb(nil, open_err or _("无法保存登录二维码")); return end
        local wrote, write_err = file:write(body)
        local closed = file:close()
        if not wrote or not closed then
            pcall(os.remove, path)
            cb(nil, write_err or _("无法保存登录二维码"))
            return
        end
        cb({ qr_path = path, token = token })
    end)
    return {
        cancel = function()
            cancelled = true
            job.cancel()
            pcall(os.remove, path)
        end,
    }
end

--- 轮询京东扫码状态，最多等待 120 秒。
---@param token string
---@param cb fun(data: { ticket: string }|nil, err: string|nil, status: string)
---@return { cancel: fun() }
function Auth.waitQrLoginAsync(token, cb)
    local cancelled = false
    local deadline = os.time() + 120
    local request_job

    local function poll()
        if cancelled then return end
        local callback = "jQuery" .. tostring(math.random(1000000, 9999999))
        local url = "https://qr.m.jd.com/check?" .. Text.formEncode({
            callback = callback,
            appid = 133,
            token = token,
            _ = timestamp(),
        })
        request_job = Request.get(url, {
            headers = browserHeaders(),
            timeout = 20,
        }, function(raw, err, res)
            if cancelled then return end
            mergeCookies(res)
            if (not raw or err) and os.time() < deadline then
                require("ui/uimanager"):scheduleIn(3, poll)
                return
            end
            if not raw then
                pcall(os.remove, qrPath())
                cb(nil, err or _("二维码已失效，请重新登录"), "error")
                return
            end
            local payload = raw:match("^%s*" .. callback .. "%s*%((.*)%)%s*;?%s*$")
            local ok, data = pcall(JSON.decode, payload or "")
            if not ok or type(data) ~= "table" then
                cb(nil, _("京东扫码状态无效"), "error")
                return
            end
            local code = tonumber(data.code)
            if code == 200 and type(data.ticket) == "string" and data.ticket ~= "" then
                cb({ ticket = data.ticket }, nil, "ok")
            elseif (code == 201 or code == 202) and os.time() < deadline then
                require("ui/uimanager"):scheduleIn(3, poll)
            else
                pcall(os.remove, qrPath())
                cb(nil, data.msg or _("二维码已失效，请重新登录"), "error")
            end
        end)
    end
    poll()
    return {
        cancel = function()
            cancelled = true
            if request_job then request_job.cancel() end
            pcall(os.remove, qrPath())
        end,
    }
end

--- 使用扫码 ticket 换取登录 Cookie 并原子保存源配置。
---@param info { ticket: string }|nil
---@param cb fun(user: { user_name: string }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Auth.completeQrLoginAsync(info, cb)
    if type(info) ~= "table" or type(info.ticket) ~= "string" or info.ticket == "" then
        cb(nil, _("无登录信息"))
        return nil
    end
    local cancelled = false
    local url = "https://passport.jd.com/uc/qrCodeTicketValidation?" .. Text.formEncode({
        t = info.ticket,
        ReturnUrl = "https://e.m.jd.com/",
    })
    local job = Request.get(url, {
        headers = browserHeaders(),
        timeout = 30,
    }, function(raw, err, res)
        if cancelled then return end
        mergeCookies(res)
        if not raw then
            pcall(os.remove, qrPath())
            cb(nil, err or _("京东登录校验失败"))
            return
        end
        local ok, data = pcall(JSON.decode, raw)
        if not ok or type(data) ~= "table" or tonumber(data.returnCode) ~= 0 then
            pcall(os.remove, qrPath())
            cb(nil, _("京东登录校验失败"))
            return
        end
        login_jar.QRCodeKey = nil
        login_jar.wlfstk_smdl = nil
        login_jar.guid = nil
        local cookie = cookieHeader(login_jar)
        if not cookie then
            pcall(os.remove, qrPath())
            cb(nil, _("登录未拿到会话 Cookie"))
            return
        end
        local Settings = require("utils.settings")
        local current = Settings.getSource("jdread")
        local name = Text.urlDecode(login_jar.unick or login_jar.pin or "") or ""
        current.cookie = cookie
        current.uuid = current.uuid ~= nil and current.uuid ~= ""
            and current.uuid or ("h5" .. require("ffi/sha2").md5(Settings.ensureDeviceId()))
        current.user_name = name
        Settings.saveSource("jdread", current)
        login_jar = {}
        pcall(os.remove, qrPath())
        cb({ user_name = name })
    end)
    return {
        cancel = function()
            cancelled = true
            job.cancel()
            pcall(os.remove, qrPath())
        end,
    }
end

return Auth
