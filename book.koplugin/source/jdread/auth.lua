--[[--
京东账号扫码登录：二维码 PNG → 状态轮询 → ticket 换取 .jd.com 会话。

@module koplugin.book.source.jdread.auth
--]]

local JSON = require("json")
local Request = require("http.request")
local Image = require("utils.image")
local Text = require("utils.text")
local _ = require("gettext")

local Auth = {}

local LOGIN_PAGE = "https://passport.jd.com/new/login.aspx?ReturnUrl=https%3A%2F%2Fe.m.jd.com%2F"
local HOME = "https://e.m.jd.com/"
local LOGIN_UA = Request.randomUA()
local QR_COOKIE_KEYS = { "QRCodeKey", "wlfstk_smdl", "guid" }
local qr_seq = 0
local qr_file

-- qrCodeTicketValidation 的 returnCode 语义，取自官方 login.qrcode.2024.js。
local TICKET_ERRORS = {
    [58] = "二维码已失效，请重新登录",
    [59] = "二维码已失效，请重新登录",
    [60] = "京东登录失败",
    [70] = "京东登录失败",
    [80] = "京东判定本次扫码存在风险，请稍后重试",
}

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

---@param jar table
---@param res table|nil
local function mergeCookies(jar, res)
    local values = Request.header(res, "Set-Cookie")
    if type(values) == "string" then values = { values } end
    for _idx, line in ipairs(type(values) == "table" and values or {}) do
        local key, value = line:match("^%s*([^=;]+)=([^;]*)")
        if key then
            if value == "" then jar[key] = nil else jar[key] = value end
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
    for _idx, key in ipairs(keys) do parts[#parts + 1] = key .. "=" .. jar[key] end
    return table.concat(parts, "; ")
end

---@param jar table
---@return table
local function browserHeaders(jar)
    return {
        ["Accept"] = "application/json, text/javascript, */*; q=0.01",
        ["Cookie"] = cookieHeader(jar),
        ["Referer"] = LOGIN_PAGE,
        ["User-Agent"] = LOGIN_UA,
    }
end

---@return string
local function timestamp()
    return tostring(os.time() * 1000 + math.random(0, 999))
end

local function clearQrFile()
    if qr_file then
        os.remove(qr_file)
        qr_file = nil
    end
end

--- 每次换新文件名：同一路径会被位图缓存成上一张已作废的码。
---@return string
local function nextQrFile()
    clearQrFile()
    local Paths = require("utils.paths")
    Paths.ensureLayout("jdread")
    qr_seq = qr_seq + 1
    qr_file = Paths.imageDir("jdread") .. "/login-qr-" .. qr_seq .. ".png"
    return qr_file
end

local function dropQrCookies(jar)
    for _idx, key in ipairs(QR_COOKIE_KEYS) do
        jar[key] = nil
    end
end

--- 去掉扫码临时 cookie 之后还剩什么；不改 jar。
---@param jar table
---@return string|nil
local function sessionCookie(jar)
    local saved = {}
    for _idx, key in ipairs(QR_COOKIE_KEYS) do
        saved[key] = jar[key]
        jar[key] = nil
    end
    local cookie = cookieHeader(jar)
    for key, value in pairs(saved) do
        jar[key] = value
    end
    return cookie
end

---@param base string
---@param loc string|nil
---@return string|nil
local function absUrl(base, loc)
    if type(loc) ~= "string" or loc == "" then return nil end
    if loc:find("^https?://") then return loc end
    local origin = type(base) == "string" and base:match("^(https?://[^/]+)")
    if not origin then return nil end
    if loc:sub(1, 1) == "/" then return origin .. loc end
    return origin .. "/" .. loc
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
--- jar 归本次登录独占：check 要求 token 与同一张码的 wlfstk_smdl/QRCodeKey 配对，串用即 257“参数异常”。
---@param cb fun(data: { qr_path: string, token: string, jar: table }|nil, err: string|nil)
---@return { cancel: fun() }
function Auth.beginQrLoginAsync(cb)
    local jar = {}
    local path = nextQrFile()
    local cancelled = false
    local url = "https://qr.m.jd.com/show?" .. Text.formEncode({
        appid = 133,
        size = 147,
        t = timestamp(),
    })
    local job = Request.get(url, {
        headers = browserHeaders(jar),
        timeout = 30,
    }, function(body, err, res)
        if cancelled then return end
        mergeCookies(jar, res)
        local token = jar.wlfstk_smdl
        if not body or Image.ext(body) ~= ".png"
            or type(token) ~= "string" or token == "" then
            cb(nil, err or _("获取京东登录二维码失败"))
            return
        end
        local file, open_err = io.open(path, "wb")
        if not file then cb(nil, open_err or _("无法保存登录二维码")); return end
        local wrote, write_err = file:write(body)
        local closed = file:close()
        if not wrote or not closed then
            clearQrFile()
            cb(nil, write_err or _("无法保存登录二维码"))
            return
        end
        cb({ qr_path = path, token = token, jar = jar })
    end)
    return { cancel = function()
            cancelled = true
            job.cancel()
            clearQrFile()
        end }
end

--- 轮询京东扫码状态，最多等待 120 秒。
---@param login { token: string, jar: table } beginQrLoginAsync 的结果
---@param cb fun(data: { ticket: string, jar: table }|nil, err: string|nil, status: string)
---@return { cancel: fun() }
function Auth.waitQrLoginAsync(login, cb)
    local token, jar = login.token, login.jar
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
            headers = browserHeaders(jar),
            timeout = 20,
        }, function(raw, err, res)
            if cancelled then return end
            mergeCookies(jar, res)
            if (not raw or err) and os.time() < deadline then
                require("ui/uimanager"):scheduleIn(3, poll)
                return
            end
            if not raw then
                clearQrFile()
                cb(nil, err or _("二维码已失效，请重新登录"), "error")
                return
            end
            local payload = raw:match("^%s*" .. callback .. "%s*%((.*)%)%s*;?%s*$")
            local ok, data = pcall(JSON.decode, payload or "")
            if not ok or type(data) ~= "table" then
                clearQrFile()
                cb(nil, _("京东扫码状态无效"), "error")
                return
            end
            local code = tonumber(data.code)
            if code == 200 and type(data.ticket) == "string" and data.ticket ~= "" then
                cb({ ticket = data.ticket, jar = jar }, nil, "ok")
            elseif (code == 201 or code == 202) and os.time() < deadline then
                require("ui/uimanager"):scheduleIn(3, poll)
            else
                clearQrFile()
                cb(nil, data.msg or _("二维码已失效，请重新登录"), "error")
            end
        end)
    end
    poll()
    return { cancel = function()
            cancelled = true
            if request_job then request_job.cancel() end
            clearQrFile()
        end }
end

--- 使用扫码 ticket 换取登录 Cookie 并原子保存源配置。
---@param info { ticket: string, jar: table } waitQrLoginAsync 的结果
---@param cb fun(user: { user_name: string }|nil, err: string|nil)
---@return { cancel: fun() }
function Auth.completeQrLoginAsync(info, cb)
    local jar = info.jar
    local cancelled = false
    local job
    local hops = 0

    local function persist()
        dropQrCookies(jar)
        local cookie = cookieHeader(jar)
        if not cookie then
            clearQrFile()
            cb(nil, _("登录未拿到会话 Cookie"))
            return
        end
        local Settings = require("utils.settings")
        local current = Settings.getSource("jdread")
        local name = Text.urlDecode(jar.unick or jar.pin or "") or ""
        current.cookie = cookie
        current.uuid = current.uuid ~= nil and current.uuid ~= ""
            and current.uuid or ("h5" .. require("ffi/sha2").md5(require("utils.device_id").ensure()))
        current.user_name = name
        Settings.saveSource("jdread", current)
        clearQrFile()
        cb({ user_name = name })
    end

    --- 校验成功但这一跳没 Set-Cookie：跟 JSON.url / Location，最多两跳。
    --- 不走 Request.allow_redirects，302 的 Set-Cookie 在 res 里。
    local function follow(url)
        hops = hops + 1
        job = Request.get(url, {
            headers = browserHeaders(jar),
            timeout = 30,
        }, function(_body, _err, res)
            if cancelled then return end
            mergeCookies(jar, res)
            if sessionCookie(jar) then
                persist()
                return
            end
            local next_url = hops < 2 and absUrl(url, Request.header(res, "Location"))
            if next_url then
                follow(next_url)
                return
            end
            persist()
        end)
    end

    local url = "https://passport.jd.com/uc/qrCodeTicketValidation?" .. Text.formEncode({
        t = info.ticket,
        ReturnUrl = HOME,
    })
    job = Request.get(url, {
        headers = browserHeaders(jar),
        timeout = 30,
    }, function(raw, err, res)
        if cancelled then return end
        mergeCookies(jar, res)
        if not raw then
            clearQrFile()
            cb(nil, err or _("京东登录校验失败"))
            return
        end
        local ok, data = pcall(JSON.decode, raw)
        local code = ok and type(data) == "table" and tonumber(data.returnCode) or nil
        if code ~= 0 then
            clearQrFile()
            local msg = _(TICKET_ERRORS[code] or "京东登录校验失败")
            cb(nil, code and (msg .. " (" .. code .. ")") or msg)
            return
        end
        if sessionCookie(jar) then
            persist()
            return
        end
        local hop = data.url
        follow(type(hop) == "string" and hop ~= "" and hop or HOME)
    end)
    return { cancel = function()
            cancelled = true
            if job then job.cancel() end
            clearQrFile()
        end }
end

return Auth
