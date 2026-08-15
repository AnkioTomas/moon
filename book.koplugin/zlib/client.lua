--[[--
Z-Library eAPI 客户端（HTTP Basic 门禁 + Z-Library 账号会话，仅异步）。

@module koplugin.book.zlib.client
--]]

local JSON = require("json")
local Request = require("http.request")
local _ = require("gettext")
local T = require("ffi/util").template

local BASE_URL = "https://zh.iread.ink"
local BASIC_USER = "iread"
local BASIC_PASSWORD = "DGvG2h3JMOvEoS"
local USER_AGENT = "KOReader/MoonBook Z-Library"

local Client = {}
Client.__index = Client

local function urlEncode(value)
    return tostring(value):gsub("([^%w%-_%.~])", function(char)
        return string.format("%%%02X", string.byte(char))
    end)
end

local function form(data)
    local keys, out = {}, {}
    for key in pairs(data or {}) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        out[#out + 1] = urlEncode(key) .. "=" .. urlEncode(data[key])
    end
    return table.concat(out, "&")
end

local function decode(body)
    if type(body) ~= "string" or body == "" then return nil, _("响应为空") end
    local ok, data = pcall(JSON.decode, body)
    if not ok or type(data) ~= "table" then return nil, _("无效响应格式") end
    return data
end

local function apiError(data, fallback)
    local err = type(data) == "table" and data.error or nil
    if type(err) == "table" then err = err.message end
    if err ~= nil and tostring(err) ~= "" then return tostring(err) end
    if type(data) == "table" and type(data.message) == "string" and data.message ~= "" then
        return data.message
    end
    return fallback
end

function Client.new(cfg)
    cfg = cfg or {}
    return setmetatable({
        cfg = cfg,
        email = cfg.email or "",
        password = cfg.password or "",
        user_id = cfg.user_id or "",
        user_key = cfg.user_key or "",
    }, Client)
end

function Client:hasSession()
    return self.user_id ~= "" and self.user_key ~= ""
end

function Client:hasCredentials()
    return self.email ~= "" and self.password ~= ""
end

function Client:headers(with_session)
    local headers = {
        ["Accept"] = "application/json, text/javascript, */*; q=0.01",
        ["User-Agent"] = USER_AGENT,
    }
    if with_session and self:hasSession() then
        headers["Cookie"] = string.format("remix_userid=%s; remix_userkey=%s", self.user_id, self.user_key)
    end
    return headers
end

function Client:_jsonAsync(method, path, opts, cb)
    opts = opts or {}
    local body = opts.form and form(opts.form) or nil
    local headers = self:headers(opts.session)
    if body then
        headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
        headers["Content-Length"] = tostring(#body)
        headers["X-Requested-With"] = "XMLHttpRequest"
    end
    return Request.request({
        url = BASE_URL .. path,
        method = method,
        body = body,
        headers = headers,
        auth_username = BASIC_USER,
        auth_password = BASIC_PASSWORD,
        timeout = opts.timeout or 45,
    }, function(res, err)
        if err then cb(nil, err); return end
        local data, decode_err = decode(res and res.body)
        if not Request.ok(res and res.code) then
            cb(nil, apiError(data, T(_("HTTP %1"), tostring(res and res.code))))
            return
        end
        if not data then cb(nil, decode_err); return end
        cb(data)
    end)
end

function Client:pingAsync(cb)
    return self:_jsonAsync("GET", "/eapi/info/ok", nil, function(data, err)
        if data and tonumber(data.success) == 1 then cb(true) else cb(nil, err or apiError(data, _("连接失败"))) end
    end)
end

function Client:listPopularAsync(cb)
    return self:_jsonAsync("GET", "/eapi/book/most-popular", { session = true }, function(data, err)
        if data and tonumber(data.success) == 1 then cb(data) else cb(nil, err or apiError(data, _("加载失败"))) end
    end)
end

function Client:searchAsync(query, page, limit, cb)
    return self:_jsonAsync("POST", "/eapi/book/search", {
        session = true,
        form = { message = query or "", page = page or 1, limit = limit or 12 },
    }, function(data, err)
        if data and not data.error then cb(data) else cb(nil, err or apiError(data, _("搜索失败"))) end
    end)
end

function Client:detailAsync(id, hash, cb)
    return self:_jsonAsync("GET", string.format("/eapi/book/%s/%s", id, hash), { session = true }, function(data, err)
        if data and tonumber(data.success) == 1 and type(data.book) == "table" then
            cb(data.book)
        else
            cb(nil, err or apiError(data, _("获取详情失败")))
        end
    end)
end

function Client:loginAsync(cb)
    if not self:hasCredentials() then
        cb(nil, _("请先在设置里填写 Z-Library 邮箱和密码"))
        return nil
    end
    return self:_jsonAsync("POST", "/eapi/user/login", {
        form = { email = self.email, password = self.password },
    }, function(data, err)
        if not data or tonumber(data.success) ~= 1 then
            cb(nil, err or apiError(data, _("登录失败")))
            return
        end
        local user = data.user or data.response or {}
        local id = tostring(user.id or user.user_id or "")
        local key = tostring(user.remix_userkey or user.user_key or "")
        if id == "" or key == "" then cb(nil, _("登录失败：无效会话")); return end
        self.user_id, self.user_key = id, key
        self.cfg.user_id, self.cfg.user_key = id, key
        require("utils.settings").saveSource("zlib", self.cfg)
        cb(true)
    end)
end

function Client:ensureSessionAsync(cb)
    if self:hasSession() then cb(true); return nil end
    return self:loginAsync(cb)
end

function Client:downloadLinkAsync(id, hash, cb)
    return self:_jsonAsync("GET", string.format("/eapi/book/%s/%s/file", id, hash), {
        session = true,
    }, function(data, err)
        local file = data and data.file
        if not data or tonumber(data.success) ~= 1 or type(file) ~= "table" then
            cb(nil, err or apiError(data, _("获取下载链接失败")))
            return
        end
        if file.allowDownload == false then cb(nil, _("已达下载限额，请稍后再试")); return end
        if type(file.downloadLink) ~= "string" or file.downloadLink == "" then cb(nil, _("未返回下载链接")); return end
        cb(file.downloadLink)
    end)
end

function Client:downloadAsync(id, hash, dest, on_progress, cb)
    local cancelled, job, retried = false, nil, false
    local result = {}
    function result.cancel()
        cancelled = true
        if job and job.cancel then job.cancel() end
        pcall(os.remove, dest)
    end
    local function finish(ok, err)
        if not cancelled then cb(ok, err) end
    end
    local function fetchFile(link)
        if cancelled then return end
        pcall(os.remove, dest)
        job = Request.download({
            url = link,
            method = "GET",
            headers = self:headers(true),
            timeout = 180,
            on_progress = on_progress,
        }, dest, function(ok, err, res)
            if not ok then pcall(os.remove, dest); finish(nil, err); return end
            local content_type = Request.header(res, "Content-Type")
            if type(content_type) == "string" and content_type:lower():find("text/html", 1, true) then
                pcall(os.remove, dest)
                finish(nil, _("已达下载限额或返回了网页"))
                return
            end
            finish(true)
        end)
    end
    local function getLink()
        job = self:downloadLinkAsync(id, hash, function(link, err)
            if link then fetchFile(link); return end
            if not retried and type(err) == "string"
                and (err:find("Please login", 1, true) or err:find("请登录", 1, true)) then
                retried = true
                self.user_id, self.user_key = "", ""
                self.cfg.user_id, self.cfg.user_key = nil, nil
                require("utils.settings").saveSource("zlib", self.cfg)
                job = self:loginAsync(function(ok, login_err)
                    if ok then getLink() else finish(nil, login_err) end
                end)
                return
            end
            finish(nil, err)
        end)
    end
    job = self:ensureSessionAsync(function(ok, err)
        if ok then getLink() else finish(nil, err) end
    end)
    return result
end

return Client
