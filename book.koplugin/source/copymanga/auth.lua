--[[--
拷贝漫画账号会话：App 登录，持久化 Token。

登录规则与 kComics / 官方 App 一致：
  salt = 6 位随机整数
  password = base64(明文密码 .. "-" .. salt)
  POST /api/v3/login  (x-www-form-urlencoded)

@module koplugin.book.source.copymanga.auth
--]]

local Client = require("source.copymanga.client")
local JSON = require("json")
local Text = require("utils.text")
local _ = require("gettext")

local Auth = {}
local SOURCE_ID = "copymanga"

---@return table
local function cfg()
    return require("utils.settings").getSource(SOURCE_ID)
end

---@param patch table
local function save(patch)
    local settings = require("utils.settings")
    local current = settings.getSource(SOURCE_ID)
    for key, value in pairs(patch) do
        current[key] = value
    end
    settings.saveSource(SOURCE_ID, current)
end

--- 站点前端同款密码编码。
---@param password string
---@param salt string|number
---@return string
function Auth.encodePassword(password, salt)
    return Text.base64Encode(tostring(password) .. "-" .. tostring(salt))
end

---@return string
local function newSalt()
    return tostring(math.random(100000, 999999))
end

---@return boolean
function Auth.hasSession()
    local token = cfg().token
    return type(token) == "string" and token ~= ""
end

---@return string|nil
function Auth.userLabel()
    local current = cfg()
    if type(current.nickname) == "string" and current.nickname ~= "" then
        return current.nickname
    end
    if type(current.username) == "string" and current.username ~= "" then
        return current.username
    end
    return nil
end

---@return string|nil
function Auth.token()
    local token = cfg().token
    if type(token) == "string" and token ~= "" then
        return token
    end
    return nil
end

--- 本地保存的账号密码；缺任一端则没有可自动重登的凭据。
---@return string|nil, string|nil
function Auth.credentials()
    local current = cfg()
    local username = current.username
    local password = current.password
    if type(username) == "string" and username ~= ""
        and type(password) == "string" and password ~= ""
    then
        return username, password
    end
    return nil
end

--- 清除登录态，保留站点地址。
function Auth.clearSession()
    save({
        token = "",
        user_id = "",
        username = "",
        nickname = "",
        password = "",
    })
end

--- 账号密码登录；成功后写入 token / 用户信息。
---@param username string
---@param password string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Auth.loginAsync(username, password, cb)
    username = Text.stripWhitespace(username)
    password = tostring(password or "")
    if username == "" or password == "" then
        cb(nil, _("请输入账号和密码"))
        return nil
    end

    local salt = newSalt()
    local body = Text.formEncode({
        username = username,
        password = Auth.encodePassword(password, salt),
        salt = salt,
    })
    local headers = Client.headers()
    headers["Content-Type"] = "application/x-www-form-urlencoded;charset=utf-8"

    return require("http.request").request({
        url = Client.normalizeBaseUrl(cfg().base_url) .. "/api/v3/login",
        method = "POST",
        body = body,
        headers = headers,
        timeout = 30,
        connect_timeout = 10,
    }, function(res, err)
        if err then
            cb(nil, err)
            return
        end
        local raw = res and res.body or ""
        local ok, wire = pcall(JSON.decode, raw)
        if not ok or type(wire) ~= "table" then
            cb(nil, _("登录响应无效"))
            return
        end
        if tonumber(wire.code) ~= 200 or type(wire.results) ~= "table" then
            cb(nil, wire.message or _("登录失败"))
            return
        end
        local results = wire.results
        local token = results.token
        if type(token) ~= "string" or token == "" then
            cb(nil, _("登录失败：未返回令牌"))
            return
        end
        save({
            token = token,
            user_id = tostring(results.user_id or ""),
            username = tostring(results.username or username),
            nickname = tostring(results.nickname or results.username or username),
            password = password,
        })
        cb(true)
    end)
end

return Auth
