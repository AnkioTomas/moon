--[[--
BookOrbit HTTP 客户端：KOReader 同步账号认证（x-auth-user / x-auth-key），只回 wire，不做领域转换。
x-auth-key 是密码的 MD5（同 kosync，服务端也收明文）。接口都在 `<server_url>/api/v1/koreader/` 下。
调用方先看 configured()，这里不再判。

@module moonsource_bookorbit.client
--]]

local JSON = require("json")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookOrbitClient
---@field server_url string 用户填的地址，不带 /api/v1
---@field username string
---@field userkey string 密码 MD5
local Client = {}
Client.__index = Client

--- 用户填的地址：去空白、尾斜杠，以及照抄来的 `/api/v1`、`/api/v1/koreader` 后缀。
---@param value string|nil
---@return string
function Client.normalizeUrl(value)
    local url = Text.rtrimSlashes(Text.stripWhitespace(value))
    return (url:gsub("/api/v1/koreader$", ""):gsub("/api/v1$", ""))
end

---@param cfg { server_url: string|nil, username: string|nil, userkey: string|nil }
---@return BookOrbitClient
function Client.new(cfg)
    return setmetatable({
        server_url = Client.normalizeUrl(cfg.server_url),
        username = Text.trim(cfg.username),
        userkey = Text.stripWhitespace(cfg.userkey),
    }, Client)
end

---@return boolean
function Client:configured()
    return self.server_url ~= "" and self.username ~= "" and self.userkey ~= ""
end

---@return table
function Client:headers()
    return { ["x-auth-user"] = self.username, ["x-auth-key"] = self.userkey }
end

---@param path string `/koreader/...`
---@param query table|nil
---@return string
function Client:url(path, query)
    local url = self.server_url .. "/api/v1" .. path
    if query then return url .. "?" .. Text.formEncode(query) end
    return url
end

--- JSON 请求：2xx 回 cb(data)，否则 cb(nil, err, code)。空体按 {} 交回。
---@param method string
---@param path string
---@param query table|nil
---@param body table|nil JSON 请求体
---@param cb fun(data: table|nil, err: string|nil, code: integer|nil)
---@return HttpJob
function Client:json(method, path, query, body, cb)
    local headers = self:headers()
    headers["Accept"] = "application/json"
    local payload
    if body then
        headers["Content-Type"] = "application/json"
        payload = JSON.encode(body)
    end
    return Request.request({
        url = self:url(path, query), method = method, headers = headers, body = payload, timeout = 30,
    }, function(res, err)
        if err or not res then
            cb(nil, err and tostring(err) or _("网络请求失败"))
            return
        end
        local code = tonumber(res.code)
        if code == 401 or code == 403 then
            cb(nil, _("BookOrbit 用户名或密码错误，或未开启 KOReader 同步"), code)
            return
        end
        if not Request.ok(code) then
            cb(nil, T(_("请求失败 (HTTP %1)"), tostring(code)), code)
            return
        end
        local raw = Text.trim(Text.stripBom(res.body or ""))
        if raw == "" then
            cb({}, nil, code)
            return
        end
        -- 反代可能回 HTML 错误页：解析失败按请求失败处理，不让异常冒到回调链外。
        local ok, data = pcall(JSON.decode, raw)
        if ok and type(data) == "table" then
            cb(data, nil, code)
        else
            cb(nil, _("响应不是 JSON"), code)
        end
    end)
end

--- 下载书库文件原件。Request.download 遇到非 2xx 也会落盘，这里删掉并报错。
---@param file_id integer
---@param dest string
---@param on_progress fun(bytes: number, total: number|nil)
---@param cb fun(ok: boolean, err: string|nil)
---@return HttpJob
function Client:download(file_id, dest, on_progress, cb)
    return Request.download({
        url = self:url("/koreader/plugin/catalog/files/" .. file_id .. "/download"),
        headers = self:headers(), timeout = 60, on_progress = on_progress,
    }, dest, function(ok, err, res)
        if ok and not Request.ok(res and res.code) then
            os.remove(dest)
            ok, err = false, T(_("请求失败 (HTTP %1)"), tostring(res and res.code))
        end
        cb(ok, err and tostring(err))
    end)
end

return Client
