--[[--
晋江「App」协议：账号密码登录拿 token（android API）。

账号、密码和 token 都存在源设置里：token 失效（接口回 1004「登入验证失败」）时用保存的账号密码静默重登，
重登还要设备验证码才算登录过期，交给 Auth 弹登录。和网页 Cookie 协议（web.lua）互不相干；
token 的请求头各接口不同，响应既可能是明文 JSON，也可能整包加密（密钥由响应头 accesskey / keystring 派生，见 decryptBody）。

协议接口（protocols/init.lua 按设置选一个协议调用）：`available` / `shelfAsync` / `contentAsync`。

@module koplugin.book.source.jjwxc.protocols.app
--]]

local Job = require("workers.job")
local JSON = require("json")
local Mapper = require("source.jjwxc.mapper")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("gettext")

local Token = {}

Token.id = "app"

local SOURCE_ID = "jjwxc"
local APP = "https://app-cdn.jjwxc.net/androidapi"
-- 接口回包 code：1004 = 要登录（token 无效），1025 = 登录态有效但这章没买。
local LOGIN_CODE = 1004
local UNPAID_CODE = 1025
-- 登录接口的版本号与 App 内置的 DES 密钥（密钥写在 App 里，不是用户机密）。
local LOGIN_VERSION = 402
local DES_KEY, DES_IV = "KW8Dvm2N", "1ae2c94b"
local ACCOUNT_HEADERS = {
    ["User-Agent"] = "Mobile",
    ["Accept-Encoding"] = "identity",
    ["Referer"] = "http://android.jjwxc.net?v=" .. LOGIN_VERSION,
}
-- 带 token 取正文必须带 App 的 UA，UA 是 "Mobile" 时服务端回 2016「浏览器标识异常」。
local CONTENT_HEADERS = {
    ["User-Agent"] = "JINJIANG-Android/381",
    ["Referer"] = "http://android.jjwxc.net?v=381",
    ["Accept-Encoding"] = "identity",
}
-- 要求设备验证（手机 / 邮箱验证码）的 code。
local DEVICE_VERIFY_CODE = 221003

---@return string
function Token.label() return _("App 账号") end

---@return string|nil
function Token.get()
    local token = require("utils.settings").getSource(SOURCE_ID).token
    return type(token) == "string" and token ~= "" and token or nil
end

---@return boolean
function Token.available() return Token.get() ~= nil end

--- 段评接口（Pc/comment）的登录态：VIP 章节要求，App 协议把 token 放查询参数（放请求头 / Cookie 都被拒）。
---@return string query
---@return table headers
function Token.commentAuth()
    local token = Token.get()
    return token and "&token=" .. Text.urlEncode(token) or "", {}
end

--- 登录成功后保存，重登与书架都靠它。
---@param account string
---@param password string
---@param token string
function Token.save(account, password, token)
    local Settings = require("utils.settings")
    local cfg = Settings.getSource(SOURCE_ID)
    cfg.account, cfg.password, cfg.token = account, password, token
    Settings.saveSource(SOURCE_ID)
end

--- 整包加密响应的解密：accesskey / keystring 两个响应头派生 DES 密钥，12 字符的盐在正文头或尾（看 accesskey 末字符奇偶）。
---@param body string
---@param accesskey string
---@param keystring string
---@return string|nil
function Token.decryptBody(body, accesskey, keystring)
    local sum = 0
    for i = 1, #accesskey do sum = sum + accesskey:byte(i) end
    local start, count = sum % #keystring, math.floor(sum / 65)
    local part = start + count > #keystring and keystring:sub(start + 1) or keystring:sub(start + 1, start + count)
    local salt, cipher
    if accesskey:byte(-1) % 2 == 1 then
        salt, cipher = body:sub(-12), body:sub(1, -13)
    else
        salt, cipher = body:sub(1, 12), body:sub(13)
    end
    local Md5, Des = require("crypto.md5"), require("crypto.des")
    local key, iv = Md5.hex(part .. salt):sub(1, 8), Md5.hex(salt):sub(1, 8)
    if cipher:find("^%x+$") then
        local raw = require("crypto.hex").from_hex(cipher)
        return raw and Des.decrypt(raw, key, iv)
    end
    return Des.decryptBase64(cipher, key, iv)
end

---@param path string
---@param params table<string, any>
---@param headers table<string, string>
---@param cb fun(wire: table|nil, err: string|nil)
---@return HttpJob
local function get(path, params, headers, cb)
    local query = {}
    for key, value in pairs(params) do query[#query + 1] = key .. "=" .. tostring(value) end
    table.sort(query)
    return Request.get(APP .. path .. "?" .. table.concat(query, "&"), {
        accept = "application/json",
        headers = headers,
        timeout = require("http.timeout").net(1),
    }, function(raw, err, res)
        if not raw then cb(nil, err and tostring(err) or _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, raw)
        if ok and type(wire) == "table" then cb(wire); return end
        local accesskey, keystring = Request.header(res, "accesskey"), Request.header(res, "keystring")
        if not (accesskey and keystring and keystring ~= "") then
            require("utils.log").warn("jjwxc invalid response", path, #raw, raw:sub(1, 300))
            cb(nil, _("响应无效"))
            return
        end
        -- DES 是纯 Lua 重活，放子进程
        Job.run(function() return { plain = Token.decryptBody(raw, accesskey, keystring) } end, {
            name = "jjwxc_body",
            kind = "light",
            timeout = 60,
            on_done = function(r)
                local ok2, wire2 = pcall(JSON.decode, r.plain or "")
                if ok2 and type(wire2) == "table" then cb(wire2); return end
                require("utils.log").warn("jjwxc decrypt body failed", path, #raw)
                cb(nil, _("响应无效"))
            end,
            on_failed = function(e) cb(nil, tostring(e)) end,
            on_cancelled = function() end,
        })
    end)
end

---@param value any
---@return string|nil
local function nonEmpty(value)
    return type(value) == "string" and value ~= "" and value or nil
end

---@param n integer
---@param alphabet string
---@return string
local function randomString(n, alphabet)
    local out = {}
    for i = 1, n do
        local k = math.random(#alphabet)
        out[i] = alphabet:sub(k, k)
    end
    return table.concat(out)
end

--- 账号密码登录，拿 App token。
--- 回调 (token) / (nil, err) / (nil, message, "verify")：后者表示要先做设备验证再带 checktype + code 重试。
---@param account string
---@param password string
---@param verify { checktype: "phone"|"email", code: string }|nil
---@param cb fun(token: string|nil, err: string|nil, kind: "verify"|nil)
---@return HttpJob
function Token.loginAsync(account, password, verify, cb)
    local Des = require("crypto.des")
    local identifiers = randomString(20, "0123456789") .. ":" .. randomString(16, "0123456789abcdef") .. "d4:"
    local params = {
        loginName = Text.urlEncode(account),
        encode = 1,
        loginPassword = Text.urlEncode(Des.encryptBase64(password, DES_KEY, DES_IV)),
        sign = Text.urlEncode(Des.encryptBase64(os.time() * 1000 .. "_" .. identifiers .. "_", DES_KEY, DES_IV)),
        identifiers = Text.urlEncode(identifiers),
        autologin = 1,
        versionCode = LOGIN_VERSION,
    }
    if verify then
        params.checktype = verify.checktype
        params.checkdevicecode = Text.urlEncode(verify.code)
    end
    return get("/login", params, ACCOUNT_HEADERS, function(wire, err)
        if not wire then cb(nil, err); return end
        if type(wire.token) == "string" and wire.token ~= "" then cb(wire.token); return end
        if tonumber(wire.code) == DEVICE_VERIFY_CODE and not verify then
            cb(nil, nonEmpty(wire.message) or _("晋江要求设备验证"), "verify")
            return
        end
        cb(nil, nonEmpty(wire.message) or _("晋江登录失败"))
    end)
end

--- 让晋江给账号绑定的手机 / 邮箱发设备验证码。
---@param account string
---@param checktype "phone"|"email"
---@param cb fun(message: string|nil, err: string|nil)
---@return HttpJob
function Token.sendCodeAsync(account, checktype, cb)
    local headers = { ["User-Agent"] = "Mobile", ["Accept-Encoding"] = "identity" }
    return Request.post("https://app.jjwxc.org/appDevicesecurityAndroid/getDeviceSecurityCode",
        Text.formEncode({ versionCode = 401, username = account, checktype = checktype }), {
        accept = "application/json",
        headers = headers,
        content_type = "application/x-www-form-urlencoded",
        timeout = require("http.timeout").net(1),
    }, function(raw, err)
        if not raw then cb(nil, err and tostring(err) or _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok or type(wire) ~= "table" then cb(nil, _("响应无效")); return end
        -- 发送成功时提示语在 data.message；失败（如 2021 缺少前置步骤、1004）只有顶层 message
        local sent = type(wire.data) == "table" and wire.data.message
        if type(sent) == "string" and sent ~= "" and tonumber(wire.code) ~= 1004 then cb(sent); return end
        cb(nil, nonEmpty(wire.message) or _("晋江没有确认验证码已发送"))
    end)
end

local waiters

--- 用保存的账号密码重登（同一时刻只发一个请求）。要设备验证则登录过期，交给 Auth 弹登录。
---@param cb fun(token: string|nil, err: string|nil)
local function relogin(cb)
    if waiters then waiters[#waiters + 1] = cb; return end
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    local account, password = cfg.account, cfg.password
    if not (account and password) then cb(nil, require("source.auth").expire(SOURCE_ID, _("晋江登录已失效"))); return end
    waiters = { cb }
    Token.loginAsync(account, password, nil, function(token, err, kind)
        if token then Token.save(account, password, token) end
        if kind == "verify" then err = require("source.auth").expire(SOURCE_ID, _("晋江登录已失效")) end
        local list = waiters
        waiters = nil
        for _idx, fn in ipairs(list) do fn(token, err) end
    end)
end

--- 带 token 的书架（App 增量收藏接口），token 被拒就重登一次再取。
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return HttpJob
function Token.shelfAsync(cb)
    local function fetch(token, retry)
        return get("/incrementFavorite", { versionCode = 185, token = Text.urlEncode(token), backupTime = 1041350400, order = 1 },
            ACCOUNT_HEADERS, function(wire, err)
                if not wire then cb(nil, err); return end
                if tonumber(wire.code) == LOGIN_CODE and retry then
                    relogin(function(fresh, rerr)
                        if fresh then fetch(fresh, false) else cb(nil, rerr) end
                    end)
                    return
                end
                local list = wire.addData
                if type(list) ~= "table" then cb(nil, wire.message or _("晋江书架无法解析")); return end
                require("source.auth").ok(SOURCE_ID)
                cb(Mapper.tokenFavRows(list))
            end)
    end
    return fetch(Token.get(), true)
end

--- 带 token 取章节正文：已购 VIP 章的响应整包加密、content 又是 DES/Base64 密文，解密放子进程。
--- token 无效（1004）重登一次再取；没买（1025）直接回 unpaid。
---@param novel_id string
---@param chapter_id string
---@param cb fun(text: string|nil, err: string|nil, kind: "unpaid"|nil)
---@return { cancel: fun() }
function Token.contentAsync(novel_id, chapter_id, cb)
    ---@type boolean, CancelHandle|nil
    local cancelled, job = false, nil
    local function fetch(token, retry)
        job = get("/chapterContent", {
            novelId = novel_id, chapterId = chapter_id, versionCode = 381, token = Text.urlEncode(token),
        }, CONTENT_HEADERS, function(wire, err)
            if cancelled then return end
            if not wire then cb(nil, err); return end
            local data = type(wire.data) == "table" and wire.data.content ~= nil and wire.data or wire
            local code = tonumber(wire.code)
            if code == LOGIN_CODE or code == UNPAID_CODE or type(data.content) ~= "string" or data.content == "" then
                if code == LOGIN_CODE and retry then
                    relogin(function(fresh, rerr)
                        if cancelled then return end
                        if fresh then fetch(fresh, false) else cb(nil, rerr) end
                    end)
                    return
                end
                cb(nil, wire.message or _("晋江章节内容为空"), code == UNPAID_CODE and "unpaid" or nil)
                return
            end
            job = Job.run(function()
                local content = data.content
                if data.encryptType == "jj" then
                    content = require("crypto.des").decryptBase64(content, DES_KEY, DES_IV)
                end
                return { text = content }
            end, {
                name = "jjwxc_token_content",
                kind = "light",
                timeout = 60,
                on_done = function(res)
                    if cancelled then return end
                    if res.text then cb(res.text) else cb(nil, _("晋江已购章节解密失败")) end
                end,
                on_failed = function(e) if not cancelled then cb(nil, tostring(e)) end end,
                on_cancelled = function() end,
            })
        end)
    end
    fetch(Token.get(), true)
    return { cancel = function()
        cancelled = true
        job:cancel()
    end }
end

return Token
