--[[--
拷贝漫画认证：账号密码登录，Token 落盘。

协议参考 kComics（lxdklp/kComics）与 copymanga-downloader。

@module koplugin.book.source.copymanga.auth
--]]

local Text = require("utils.text")
local _ = require("gettext")

local Auth = {}

Auth.DEFAULT_API_HOST = "api.copy4000.com"

local SALT = 1729
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

--- Base64 编码（去换行）。
---@param data string
---@return string
local function b64encode(data)
    local ok, mime = pcall(require, "mime")
    if ok and mime and type(mime.b64) == "function" then
        return (mime.b64(data):gsub("\r?\n", ""))
    end
    local out = {}
    local function enc(n)
        return B64:sub(n + 1, n + 1)
    end
    local i = 1
    while i <= #data do
        local a = data:byte(i) or 0
        local b = data:byte(i + 1) or 0
        local c = data:byte(i + 2) or 0
        local n = a * 65536 + b * 256 + c
        out[#out + 1] = enc(math.floor(n / 262144) % 64)
        out[#out + 1] = enc(math.floor(n / 4096) % 64)
        out[#out + 1] = i + 1 <= #data and enc(math.floor(n / 64) % 64) or "="
        out[#out + 1] = i + 2 <= #data and enc(n % 64) or "="
        i = i + 3
    end
    return table.concat(out)
end

--- 读取拷贝漫画源配置。
---@return table
function Auth.cfg()
    return require("utils.settings").getSource("copymanga")
end

--- 合并 patch 并落盘。
---@param patch table
function Auth.saveCfg(patch)
    local MoonSettings = require("utils.settings")
    local c = MoonSettings.getSource("copymanga")
    for k, v in pairs(patch) do
        c[k] = v
    end
    MoonSettings.saveSource("copymanga", c)
end

--- API 主机名（不含 scheme）。
---@param c table|nil
---@return string
function Auth.apiHost(c)
    c = c or Auth.cfg()
    local host = Text.stripWhitespace(c.api_host or "")
    if host == "" then
        host = Auth.DEFAULT_API_HOST
    end
    return host:gsub("^https?://", ""):gsub("/+$", "")
end

--- 是否已登录。
---@return boolean
function Auth.hasSession()
    local c = Auth.cfg()
    return type(c.token) == "string" and c.token ~= ""
end

--- 当前 Token。
---@return string|nil
function Auth.token()
    local t = Auth.cfg().token
    if type(t) == "string" and t ~= "" then
        return t
    end
end

--- 登录展示名。
---@return string|nil
function Auth.userLabel()
    local c = Auth.cfg()
    local name = c.username
    if type(name) == "string" and name ~= "" then
        return name
    end
end

--- 构造拷贝漫画 App API 请求头。
---@param token string|nil
---@return table
function Auth.headers(token)
    local h = {
        ["User-Agent"] = "COPY/3.0.0",
        ["Accept"] = "application/json",
        ["version"] = "2025.08.15",
        ["platform"] = "1",
        ["webp"] = "1",
        ["region"] = "1",
    }
    token = token or Auth.token()
    if type(token) == "string" and token ~= "" then
        h["authorization"] = "Token " .. token
    end
    return h
end

--- 编码登录密码。
---@param password string
---@return string
function Auth.encodePassword(password)
    return b64encode(tostring(password or "") .. "-" .. tostring(SALT))
end

--- 异步登录；成功写 token 并回调。
---@param username string
---@param password string
---@param cb fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
function Auth.loginAsync(username, password, cb)
    username = Text.stripWhitespace(username)
    password = tostring(password or "")
    if username == "" or password == "" then
        cb(false, _("请输入账号和密码"))
        return { cancel = function() end }
    end
    local host = Auth.apiHost()
    local body = Text.formEncode({
        username = username,
        password = Auth.encodePassword(password),
        salt = SALT,
    })
    local cancelled = false
    local job = require("http.request").request({
        url = "https://" .. host .. "/api/v3/login",
        method = "POST",
        headers = {
            ["User-Agent"] = "COPY/3.0.0",
            ["Accept"] = "application/json",
            ["Content-Type"] = "application/x-www-form-urlencoded;charset=utf-8",
            ["version"] = "2025.08.15",
            ["platform"] = "1",
            ["webp"] = "1",
            ["region"] = "1",
        },
        body = body,
        timeout = 15,
    }, function(res, err)
        if cancelled then return end
        if err then
            cb(false, tostring(err))
            return
        end
        local ok, data = pcall(require("json").decode, Text.stripBom(res and res.body or ""))
        if not ok or type(data) ~= "table" then
            cb(false, _("登录响应无效"))
            return
        end
        if tonumber(data.code) ~= 200 then
            cb(false, data.message or data.msg or _("登录失败"))
            return
        end
        local token = (data.results or {}).token
        if type(token) ~= "string" or token == "" then
            cb(false, _("登录失败：无 token"))
            return
        end
        Auth.saveCfg({ username = username, token = token })
        cb(true)
    end)
    return {
        cancel = function()
            cancelled = true
            if job and job.cancel then job.cancel() end
        end,
    }
end

--- 清除会话。
function Auth.logout()
    Auth.saveCfg({ token = "", username = "" })
end

return Auth
