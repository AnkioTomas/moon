--[[--
Google Drive 文件接口。方法与 source.local.dav 对齐。

Drive 没有路径，按名字从根往下找文件夹。`gdrive_token` 是这个用户自己的刷新令牌，
`gdrive_client` 是 `客户端 ID:客户端密钥`。下面的 ID / 密钥只是月读这个 OAuth 客户端的身份，
用来让用户授权自己的网盘，不是任何人的访问令牌。范围要用 `drive`，才能看见已有的 Apps/Books；
`drive.file` 只能看见本应用自己创建的文件。

@module koplugin.book.source.local.gdrive
--]]

local JSON = require("json")
local Request = require("http.request")
local Header = require("http.request.header")
local Text = require("utils.text")
local ffiUtil = require("ffi/util")
local util = require("util")
local _ = require("gettext")
local T = ffiUtil.template

---@class GDriveClient
---@field kind "gdrive"
---@field cfg table
---@field ids table<string, string> 相对路径 → 文件 id 缓存
---@field access string|nil 访问令牌
---@field access_until number 令牌过期时刻
local Drive = {}
Drive.__index = Drive

local FOLDER = "application/vnd.google-apps.folder"
local FILES = "https://www.googleapis.com/drive/v3/files"
local UPLOAD = "https://www.googleapis.com/upload/drive/v3/files"
local FIELDS = "files(id,name,mimeType,size,modifiedTime),nextPageToken"

-- 月读注册的桌面 OAuth 客户端。只用来发起授权和换令牌，每个用户的刷新令牌另存。
-- 电视客户端不能申请完整 drive 范围，所以走浏览器授权码。同意后浏览器停在这个地址，用户把地址栏贴回来。
local CLIENT_ID = "934338025336-tfahubvrlj60l0r483ho80j4det35o30.apps.googleusercontent.com"
local CLIENT_SECRET = "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"
local REDIRECT = "http://127.0.0.1"

--- 构造客户端。cfg 是设置表，调用时现读。
---@param cfg table
---@return GDriveClient
function Drive.new(cfg)
    return setmetatable({
        kind = "gdrive",
        cfg = cfg,
        ids = {},
        access = nil,
        access_until = 0,
    }, Drive)
end

local trim = Text.trim

---@param cfg table
---@return string|nil id
---@return string|nil secret
local function clientPair(cfg)
    local id, secret = trim(cfg.gdrive_client or ""):match("^([^:]+):(.+)$")
    if not id or id == "" or not secret or secret == "" then return nil, nil end
    return id, secret
end

--- 写进用户设置的 `gdrive_client`。授权成功后和该用户自己的刷新令牌一起落盘。
---@return string
function Drive.clientApp()
    return CLIENT_ID .. ":" .. CLIENT_SECRET
end

--- 用户在浏览器里打开这个地址。同意后地址栏停在打不开的 127.0.0.1，整段地址或其中的 code 都可以贴回来。
---@return string
function Drive.authorizeUrl()
    local scope = "https://www.googleapis.com/auth/drive"
    return "https://accounts.google.com/o/oauth2/v2/auth?client_id="
        .. (util.urlEncode(CLIENT_ID) or CLIENT_ID)
        .. "&redirect_uri=" .. (util.urlEncode(REDIRECT) or REDIRECT)
        .. "&response_type=code&scope=" .. (util.urlEncode(scope) or scope)
        .. "&access_type=offline&prompt=consent"
end

--- 授权码，或浏览器地址栏整段（从中取出 code）。
---@param raw string|nil
---@return string
local function pastedCode(raw)
    raw = trim(raw or "")
    local from_url = raw:match("[?&]code=([^&#%s]+)")
    if from_url then return Text.urlDecode(from_url) or from_url end
    return raw
end

---@param name string
---@return string
local function escapeQuery(name)
    return (name:gsub("\\", "\\\\"):gsub("'", "\\'"))
end

---@param value string|nil
---@return number|nil
local function unixTime(value)
    local y, mo, d, h, mi, s = tostring(value or ""):match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
    if not y then return nil end
    local t = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(s), isdst = false })
    local now = os.time()
    return t + os.difftime(now, os.time(os.date("!*t", now)))
end

---@param err any
---@return string
local function networkErr(err)
    return T(_("无法连接 Google Drive：%1"), tostring(err))
end

---@param res table|nil
---@param code number|nil
---@return string
local function statusErr(res, code)
    if code == 401 then return _("Google Drive 认证失败：刷新令牌或客户端无效") end
    local body = res and res.body
    if type(body) ~= "string" then body = "" end
    local message = body:match('"message"%s*:%s*"([^"]+)"')
    if message and message ~= "" then
        return T(_("Google Drive 请求失败（HTTP %1）：%2"), code or "?", message)
    end
    return T(_("Google Drive 请求失败（HTTP %1）"), code or "?")
end

local function cancelledHandle()
    return { cancel = function() end }
end

--- 用授权码换这个用户自己的刷新令牌。
---@param code string
---@param cb fun(refresh: string|nil, err: string|nil)
---@return table
function Drive.exchangeCode(code, cb)
    code = pastedCode(code)
    if code == "" then
        cb(nil, _("请填写授权码"))
        return cancelledHandle()
    end
    local body = "grant_type=authorization_code&code=" .. (util.urlEncode(code) or code)
        .. "&client_id=" .. (util.urlEncode(CLIENT_ID) or CLIENT_ID)
        .. "&client_secret=" .. (util.urlEncode(CLIENT_SECRET) or CLIENT_SECRET)
        .. "&redirect_uri=" .. (util.urlEncode(REDIRECT) or REDIRECT)
    return Request.request({
        url = "https://oauth2.googleapis.com/token",
        method = "POST",
        headers = Header.forRequest({ ["Content-Type"] = "application/x-www-form-urlencoded" }),
        body = body,
    }, function(res, err)
        if not res or not Request.ok(res.code) then
            local status = res and tonumber(res.code)
            cb(nil, res and statusErr(res, status) or networkErr(err))
            return
        end
        local parsed_ok, parsed = pcall(JSON.decode, res.body or "")
        local refresh = parsed_ok and type(parsed) == "table" and parsed.refresh_token
        if type(refresh) ~= "string" or refresh == "" then
            cb(nil, _("Google Drive 没有返回刷新令牌"))
            return
        end
        cb(refresh)
    end)
end

---@param path string|nil
---@return string[]
local function partsOf(path)
    local parts = {}
    for part in Text.trimSlashes(trim(path or "")):gmatch("[^/]+") do
        parts[#parts + 1] = part
    end
    return parts
end

--- 拿到访问令牌再发请求。401 时刷新重试一次。
---@param build fun(token: string, done: fun(res: any, err: string|nil, code: number|nil)): table|nil res 由 build 自定（HTTP 响应 / 文件 id / true）
---@param cb fun(res: any, err: string|nil, code: number|nil)
---@return table
function Drive:call(build, cb)
    local state = { cancelled = false }
    local function finish(...)
        if state.cancelled then return end
        cb(...)
    end
    local function once(refreshed)
        if state.cancelled then return end
        state.job = nil
        local token_job = self:tokenAsync(function(token, token_err)
            if state.cancelled then return end
            if not token then finish(nil, token_err); return end
            state.job = build(token, function(res, err, code)
                if state.cancelled then return end
                if code == 401 and not refreshed then
                    self.access, self.access_until = nil, 0
                    once(true)
                    return
                end
                finish(res, err, code)
            end)
        end)
        -- 令牌缓存命中时回调同步跑完、state.job 已是请求句柄，不能被令牌句柄盖掉
        if not state.job then state.job = token_job end
    end
    once(false)
    return { cancel = function()
        state.cancelled = true
        if state.job and state.job.cancel then state.job:cancel() end
    end }
end

---@param cb fun(token: string|nil, err: string|nil)
---@return table|nil
function Drive:tokenAsync(cb)
    local refresh = trim(self.cfg.gdrive_token or "")
    if refresh == "" then
        cb(nil, _("未配置 Google Drive 刷新令牌"))
        return cancelledHandle()
    end
    local id, secret = clientPair(self.cfg)
    if not id then
        cb(nil, _("Google 客户端格式应为 ID:密钥"))
        return cancelledHandle()
    end
    if self.access and os.time() < self.access_until then
        cb(self.access)
        return cancelledHandle()
    end
    local body = "grant_type=refresh_token&refresh_token=" .. (util.urlEncode(refresh) or refresh)
        .. "&client_id=" .. (util.urlEncode(id) or id)
        .. "&client_secret=" .. (util.urlEncode(secret) or secret)
    return Request.request({
        url = "https://oauth2.googleapis.com/token",
        method = "POST",
        headers = Header.forRequest({ ["Content-Type"] = "application/x-www-form-urlencoded" }),
        body = body,
    }, function(res, err)
        if not res or not Request.ok(res.code) then
            local code = res and tonumber(res.code)
            cb(nil, res and statusErr(res, code) or networkErr(err))
            return
        end
        local parsed_ok, parsed = pcall(JSON.decode, res.body or "")
        local token = parsed_ok and type(parsed) == "table" and parsed.access_token
        if type(token) ~= "string" or token == "" then
            cb(nil, _("Google Drive 认证失败：刷新令牌或客户端无效"))
            return
        end
        local ttl = tonumber(parsed.expires_in) or 3600
        self.access = token
        self.access_until = os.time() + math.max(ttl - 60, 30)
        cb(token)
    end)
end

---@param token string
---@param opts table
---@param cb fun(res: table|nil, err: string|nil, code: number|nil)
---@return table
function Drive:_request(token, opts, cb)
    opts.headers = Header.forRequest(opts.headers)
    opts.headers.Authorization = "Bearer " .. token
    return Request.request(opts, function(res, err)
        if not res then
            cb(nil, networkErr(err))
        elseif not Request.ok(res.code) then
            cb(nil, statusErr(res, tonumber(res.code)), tonumber(res.code))
        else
            cb(res)
        end
    end)
end

--- 按查询翻页，收齐 files。
---@param token string
---@param query string
---@param cb fun(files: table[]|nil, err: string|nil, code: number|nil)
---@return table
function Drive:_listQuery(token, query, cb)
    local files, state = {}, {}
    local function page(page_token)
        local url = FILES .. "?pageSize=1000&fields=" .. (util.urlEncode(FIELDS) or FIELDS)
            .. "&q=" .. (util.urlEncode(query) or query)
        if page_token then url = url .. "&pageToken=" .. (util.urlEncode(page_token) or page_token) end
        state.job = self:_request(token, { url = url, method = "GET" }, function(res, err, code)
            if not res then cb(nil, err, code); return end
            local parsed_ok, parsed = pcall(JSON.decode, res.body or "")
            if not parsed_ok or type(parsed) ~= "table" then
                cb(nil, _("Google Drive 请求失败（HTTP 200）"))
                return
            end
            for _idx, item in ipairs(parsed.files or {}) do files[#files + 1] = item end
            if type(parsed.nextPageToken) == "string" and parsed.nextPageToken ~= "" then
                page(parsed.nextPageToken)
            else
                cb(files)
            end
        end)
    end
    page(nil)
    return { cancel = function()
        if state.job and state.job.cancel then state.job:cancel() end
    end }
end

---@param token string
---@param parent_id string
---@param name string
---@param cb fun(id: string|nil, err: string|nil, code: number|nil)
---@return table
function Drive:_createFolder(token, parent_id, name, cb)
    return self:_request(token, {
        url = FILES,
        method = "POST",
        headers = { ["Content-Type"] = "application/json" },
        body = JSON.encode({ name = name, mimeType = FOLDER, parents = { parent_id } }),
    }, function(res, err, code)
        if not res then cb(nil, err, code); return end
        local parsed_ok, parsed = pcall(JSON.decode, res.body or "")
        local id = parsed_ok and type(parsed) == "table" and parsed.id
        if type(id) ~= "string" or id == "" then
            cb(nil, _("Google Drive 请求失败（HTTP 200）"))
            return
        end
        cb(id)
    end)
end

--- 把相对路径解析成文件或文件夹 id。create 时缺的中间目录会建出来。
---@param path string
---@param opts { create: boolean|nil, folder: boolean|nil }
---@param cb fun(id: string|nil, err: string|nil, code: number|nil)
---@return table
function Drive:resolve(path, opts, cb)
    local parts = partsOf(path)
    local state = { cancelled = false }
    local function step(index, parent_id)
        if state.cancelled then return end
        if index > #parts then cb(parent_id); return end
        local name = parts[index]
        local cur = table.concat(parts, "/", 1, index)
        local last = index == #parts
        local want_folder = (not last) or opts.folder == true
        local cached = self.ids[cur]
        local function go(id)
            self.ids[cur] = id
            step(index + 1, id)
        end
        if cached then go(cached); return end
        state.job = self:call(function(token, done)
            local active
            local query = "name = '" .. escapeQuery(name) .. "' and '"
                .. escapeQuery(parent_id) .. "' in parents and trashed = false"
            active = self:_listQuery(token, query, function(files, err, code)
                if not files then done(nil, err, code); return end
                local found
                for _idx, item in ipairs(files) do
                    local is_dir = item.mimeType == FOLDER
                    if is_dir == want_folder and type(item.id) == "string" then found = item.id; break end
                end
                if found then done(found); return end
                if not opts.create or not want_folder then
                    done(nil, _("Google Drive 路径不存在"), 404)
                    return
                end
                active = self:_createFolder(token, parent_id, name, function(id, create_err, create_code)
                    done(id, create_err, create_code)
                end)
            end)
            return { cancel = function()
                if active and active.cancel then active:cancel() end
            end }
        end, function(id, err, code)
            if state.cancelled then return end
            if not id then cb(nil, err, code); return end
            go(id)
        end)
    end
    if #parts == 0 then
        cb("root")
        return cancelledHandle()
    end
    step(1, "root")
    return { cancel = function()
        state.cancelled = true
        if state.job and state.job.cancel then state.job:cancel() end
    end }
end

---@param path string|nil
---@param cb fun(entries: table[]|nil, err: string|nil, code: number|nil)
---@return table
function Drive:listAsync(path, cb)
    path = Text.trimSlashes(trim(path or ""))
    local state = { cancelled = false }
    state.job = self:resolve(path, { folder = true }, function(folder_id, err, code)
        if state.cancelled then return end
        if not folder_id then
            self.ids[path] = nil
            cb(nil, err, code)
            return
        end
        state.job = self:call(function(token, done)
            local query = "'" .. escapeQuery(folder_id) .. "' in parents and trashed = false"
            return self:_listQuery(token, query, done)
        end, function(files, list_err, list_code)
            if state.cancelled then return end
            if not files then cb(nil, list_err, list_code); return end
            local entries = {}
            for _idx, item in ipairs(files) do
                local name = item.name
                if type(name) == "string" and name ~= "" then
                    local is_dir = item.mimeType == FOLDER
                    local child = path ~= "" and (path .. "/" .. name) or name
                    if type(item.id) == "string" then self.ids[child] = item.id end
                    entries[#entries + 1] = {
                        name = name,
                        path = child,
                        href = item.id,
                        is_dir = is_dir,
                        size = is_dir and 0 or tonumber(item.size) or 0,
                        mtime = (not is_dir) and unixTime(item.modifiedTime) or nil,
                    }
                end
            end
            table.sort(entries, function(a, b)
                if a.is_dir ~= b.is_dir then return a.is_dir end
                return a.name < b.name
            end)
            cb(entries)
        end)
    end)
    return { cancel = function()
        state.cancelled = true
        if state.job and state.job.cancel then state.job:cancel() end
    end }
end

---@param path string
---@param dest string
---@param _opts table|nil
---@param cb fun(ok: boolean|nil, err: string|nil, code: number|nil)
---@return table
function Drive:getAsync(path, dest, _opts, cb)
    local state = { cancelled = false }
    state.job = self:resolve(path, {}, function(id, err, code)
        if state.cancelled then return end
        if not id then cb(nil, err, code); return end
        state.job = self:call(function(token, done)
            local url = FILES .. "/" .. (util.urlEncode(id) or id) .. "?alt=media"
            return Request.download({
                url = url,
                method = "GET",
                headers = Header.forDownload({ ["Authorization"] = "Bearer " .. token }),
                timeout = require("http.timeout").net(10),
            }, dest, function(ok, download_err, res)
                if ok then
                    done(true)
                elseif res and res.code and not Request.ok(res.code) then
                    done(nil, statusErr(res, tonumber(res.code)), tonumber(res.code))
                elseif res and not res.code then
                    done(nil, networkErr(download_err))
                else
                    done(nil, download_err)
                end
            end)
        end, function(ok, download_err, download_code)
            if download_code == 404 then self.ids[Text.trimSlashes(trim(path))] = nil end
            cb(ok, download_err, download_code)
        end)
    end)
    return { cancel = function()
        state.cancelled = true
        if state.job and state.job.cancel then state.job:cancel() end
    end }
end

---@param token string
---@param url string
---@param method string
---@param metadata table|nil
---@param local_path string
---@param size number
---@param cb fun(ok: boolean|nil, err: string|nil, code: number|nil)
---@return table
function Drive:_upload(token, url, method, metadata, local_path, size, cb)
    local state = {}
    state.job = self:_request(token, {
        url = url,
        method = method,
        headers = {
            ["Content-Type"] = "application/json; charset=UTF-8",
            ["X-Upload-Content-Type"] = "application/octet-stream",
            ["X-Upload-Content-Length"] = tostring(size),
        },
        body = JSON.encode(metadata or {}),
    }, function(res, err, code)
        if not res then cb(nil, err, code); return end
        local location = Request.header(res, "Location")
        if type(location) ~= "string" or location == "" then
            cb(nil, _("Google Drive 没有返回上传地址"))
            return
        end
        state.job = self:_request(token, {
            url = location,
            method = "PUT",
            headers = { ["Content-Type"] = "application/octet-stream" },
            body_file = local_path,
            body_size = size,
            timeout = require("http.timeout").net(10),
        }, function(put_res, put_err, put_code)
            cb(put_res and true or nil, put_err, put_code)
        end)
    end)
    return { cancel = function()
        if state.job and state.job.cancel then state.job:cancel() end
    end }
end

---@param path string
---@param local_path string
---@param cb fun(ok: boolean|nil, err: string|nil, code: number|nil)
---@return table|nil
function Drive:putFileAsync(path, local_path, cb)
    local file, open_err = io.open(local_path, "rb")
    if not file then
        cb(nil, open_err or _("无法读取待上传文件"))
        return cancelledHandle()
    end
    local size = file:seek("end")
    file:close()
    if not size or size == 0 then
        cb(nil, _("待上传文件为空"))
        return cancelledHandle()
    end
    path = Text.trimSlashes(trim(path))
    local parent, name = path:match("^(.*)/([^/]+)$")
    if not name then parent, name = "", path end
    local state = { cancelled = false }
    state.job = self:resolve(parent, { create = true, folder = true }, function(parent_id, err, code)
        if state.cancelled then return end
        if not parent_id then cb(nil, err, code); return end
        state.job = self:call(function(token, done)
            local active
            local query = "name = '" .. escapeQuery(name) .. "' and '"
                .. escapeQuery(parent_id) .. "' in parents and trashed = false"
            active = self:_listQuery(token, query, function(files, list_err, list_code)
                if not files then done(nil, list_err, list_code); return end
                local existing
                for _idx, item in ipairs(files) do
                    if item.mimeType ~= FOLDER and type(item.id) == "string" then existing = item.id; break end
                end
                local url = existing
                    and (UPLOAD .. "/" .. (util.urlEncode(existing) or existing) .. "?uploadType=resumable")
                    or (UPLOAD .. "?uploadType=resumable")
                local metadata = existing and {} or { name = name, parents = { parent_id } }
                active = self:_upload(token, url, existing and "PATCH" or "POST", metadata, local_path, size, function(ok, put_err, put_code)
                    if ok and existing then self.ids[path] = existing end
                    done(ok, put_err, put_code)
                end)
            end)
            return { cancel = function()
                if active and active.cancel then active:cancel() end
            end }
        end, cb)
    end)
    return { cancel = function()
        state.cancelled = true
        if state.job and state.job.cancel then state.job:cancel() end
    end }
end

---@param path string
---@param cb fun(ok: boolean|nil, err: string|nil, code: number|nil)
---@return table
function Drive:deleteAsync(path, cb)
    path = Text.trimSlashes(trim(path))
    local state = { cancelled = false }
    state.job = self:resolve(path, {}, function(id, err, code)
        if state.cancelled then return end
        if not id then cb(nil, err, code); return end
        state.job = self:call(function(token, done)
            local url = FILES .. "/" .. (util.urlEncode(id) or id)
            return self:_request(token, { url = url, method = "DELETE" }, function(res, delete_err, delete_code)
                if res or delete_code == 404 then
                    self.ids[path] = nil
                    done(res and true or nil, delete_err, delete_code == 404 and 404 or delete_code)
                else
                    done(nil, delete_err, delete_code)
                end
            end)
        end, cb)
    end)
    return { cancel = function()
        state.cancelled = true
        if state.job and state.job.cancel then state.job:cancel() end
    end }
end

--- 按层建目录。已存在的文件夹直接用。
---@param path string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return table|nil
function Drive:ensurePathAsync(path, cb)
    if Text.trimSlashes(trim(path or "")) == "" then
        cb(true)
        return cancelledHandle()
    end
    return self:resolve(path, { create = true, folder = true }, function(id, err)
        cb(id and true or nil, err)
    end)
end

return Drive
