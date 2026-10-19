--[[--
WebDAV 客户端（HTTP Basic，仅异步）。

@module koplugin.book.http.webdav
--]]

local util = require("util")
local ffiUtil = require("ffi/util")
local Header = require("http.request.header")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("gettext")
local T = ffiUtil.template

--- PROPFIND 列表项
---@class WebdavEntry
---@field name string 显示名
---@field path string 相对 base 的路径
---@field href string 原始 href
---@field is_dir boolean 是否目录
---@field size number|nil 字节数
---@field mtime number|nil Last-Modified 换算的 UTC 秒；目录或无法解析时为 nil

---@class WebdavClient
---@field url string 根 URL（已去尾斜杠）
---@field username string
---@field password string
local Webdav = {}
Webdav.__index = Webdav

local PROPFIND_LIST = [[<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>]]

local trimSlashes = Text.trimSlashes

--- HTTP 状态码转用户可读错误文案；一律点明是 WebDAV，用户才知道该去查哪项设置。
---@return string
local function statusErr(code)
    local n = tonumber(code)
    if n == 401 then
        return _("WebDAV 认证失败：用户名或密码错误")
    elseif n == 403 then
        return _("WebDAV 没有权限：该账号无法读写这个目录")
    elseif n == 404 then
        return _("WebDAV 路径不存在：请检查地址和目录")
    elseif n == 507 then
        return _("WebDAV 空间不足")
    elseif n and n >= 500 then
        return T(_("WebDAV 服务器出错（HTTP %1）"), n)
    elseif n then
        return T(_("WebDAV 请求失败（HTTP %1）"), n)
    end
    return T(_("WebDAV 请求失败：%1"), tostring(code))
end

--- 传输层失败（连不上、超时、证书、断网）。
---@return string
local function networkErr(err)
    return T(_("无法连接 WebDAV 服务器：%1"), tostring(err))
end

--- 构造 WebDAV 客户端
---@param cfg { url: string, username: string|nil, password: string|nil }
---@return WebdavClient
function Webdav.new(cfg)
    local self = setmetatable({}, Webdav)
    self.url = Text.rtrimSlashes(cfg.url or "")
    self.username = cfg.username or ""
    self.password = cfg.password or ""
    return self
end

--- 拼接 base + path（保留路径斜杠，段编码）
---@param path string|nil
---@param as_dir boolean|nil 目录 URL 强制尾斜杠
---@return string
function Webdav:join(path, as_dir)
    path = trimSlashes(path or "")
    local url = path ~= "" and (self.url .. "/" .. (util.urlEncode(path, "/") or path)) or self.url
    if as_dir and url:sub(-1) ~= "/" then
        url = url .. "/"
    end
    return url
end

--- 带 Basic 凭据发请求：成功 cb(res)；非 2xx cb(nil, 文案, code)；网络错误 cb(nil, err)。
---@param opts HttpRequest
---@param cb fun(res: table|nil, err: string|nil, code: number|nil)
---@return HttpJob
function Webdav:_request(opts, cb)
    opts.auth_username = self.username
    opts.auth_password = self.password
    return Request.request(opts, function(res, err)
        if err then
            cb(nil, networkErr(err))
        elseif not Request.ok(res.code) then
            cb(nil, statusErr(res.code), tonumber(res.code))
        else
            cb(res)
        end
    end)
end

local MONTHS = { Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
    Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12 }

--- RFC 1123 日期（`Tue, 02 Jan 2024 03:04:05 GMT`）→ UTC 秒。
---@param value string|nil
---@return number|nil
local function httpDate(value)
    local d, mon, y, h, mi, s = tostring(value or ""):match("(%d+) (%a+) (%d+) (%d+):(%d+):(%d+)")
    if not MONTHS[mon or ""] then return nil end
    local t = os.time({ year = tonumber(y), month = MONTHS[mon], day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(s), isdst = false })
    -- os.time 按本地时区解释表，补回本地与 UTC 的差。
    local now = os.time()
    return t + os.difftime(now, os.time(os.date("!*t", now)))
end

--- 解析 PROPFIND 207 响应
---@param xml string
---@param folder_url string
---@param folder_path string
---@return table
local function parseList(xml, folder_url, folder_path)
    local folder_href = trimSlashes(util.urlDecode(folder_url:match("^https?://[^/]*(.*)$") or folder_url))
    local entries = {}
    for item in xml:gmatch("<[%w_]*:?response[^>]*>(.-)</[%w_]*:?response>") do
        local href = item:match("<[%w_]*:?href[^>]*>(.-)</[%w_]*:?href>")
        if href then
            local full = util.urlDecode(href) or href
            full = util.htmlEntitiesToUtf8(full)
            local name = ffiUtil.basename(full)
            local is_empty_type = item:find("<[%w_]*:?resourcetype%s*/>")
                or item:find("<[%w_]*:?resourcetype>%s*</[%w_]*:?resourcetype>")
            local is_collection = item:find("<[%w_]*:?collection[^<]*/>")
                or item:find("<[%w_]*:?collection>%s*</[%w_]*:?collection>")
            local is_dir = not is_empty_type and is_collection ~= nil

            -- Depth:1 回包里第一条是被列目录自身，跳过。
            if not is_dir or trimSlashes(full) ~= folder_href then
                entries[#entries + 1] = {
                    name = name,
                    path = folder_path ~= "" and (folder_path .. "/" .. name) or name,
                    href = full,
                    is_dir = is_dir,
                    size = is_dir and 0
                        or tonumber(item:match("<[%w_]*:?getcontentlength[^>]*>(%d+)</[%w_]*:?getcontentlength>")) or 0,
                    mtime = not is_dir
                        and httpDate(item:match("<[%w_]*:?getlastmodified[^>]*>(.-)</[%w_]*:?getlastmodified>")) or nil,
                }
            end
        end
    end
    table.sort(entries, function(a, b)
        if a.is_dir ~= b.is_dir then
            return a.is_dir
        end
        return a.name < b.name
    end)
    return entries
end

--- Nonblocking Depth:1 directory listing.
---@param path string|nil
---@param cb fun(entries: WebdavEntry[]|nil, err: string|nil)
---@return HttpJob
function Webdav:listAsync(path, cb)
    path = trimSlashes(path or "")
    local url = self:join(path, true)
    return self:_request({
        url = url,
        method = "PROPFIND",
        headers = {
            ["Content-Type"] = "application/xml; charset=utf-8",
            ["Depth"] = "1",
        },
        body = PROPFIND_LIST,
    }, function(res, err)
        if not res then
            cb(nil, err)
            return
        end
        local xml = res.body or ""
        cb(xml == "" and {} or parseList(xml, url, path))
    end)
end

--- Nonblocking download to dest.
---@param path string
---@param dest string
---@param opts table|nil
---@param cb fun(ok: boolean|nil, err: string|nil, code: number|nil) code 仅 HTTP 非 2xx 时给出
---@return HttpJob
function Webdav:getAsync(path, dest, opts, cb)
    opts = opts or {}
    return Request.download({
        url = self:join(path, false),
        headers = Header.forDownload(opts.headers),
        auth_username = self.username,
        auth_password = self.password,
        timeout = opts.timeout or require("http.timeout").net(10),
        on_progress = opts.on_progress,
    }, dest, function(ok, err, res)
        if ok then
            cb(true)
        elseif res and res.code and not Request.ok(res.code) then
            cb(nil, statusErr(res.code), tonumber(res.code))
        elseif res and not res.code then
            cb(nil, networkErr(err))
        else
            -- 没开始请求（res=nil）或已收到 2xx：本地写盘 / 改名失败，不是 WebDAV 的问题
            cb(nil, err)
        end
    end)
end

--- 上传本地文件到 WebDAV。
---@param path string
---@param local_path string
---@param cb fun(ok: boolean|nil, err: string|nil, code: number|nil) code 非 nil 表示服务器回了状态码，nil 是传输层失败
---@return HttpJob|nil
function Webdav:putFileAsync(path, local_path, cb)
    local file, open_err = io.open(local_path, "rb")
    if not file then
        cb(nil, open_err or _("无法读取待上传文件"))
        return nil
    end
    local size = file:seek("end")
    file:close()
    if not size or size == 0 then
        cb(nil, _("待上传文件为空"))
        return nil
    end
    return self:_request({
        url = self:join(path, false),
        method = "PUT",
        headers = Header.forRequest({ ["Content-Type"] = "application/octet-stream" }),
        body_file = local_path,
        body_size = size,
        timeout = require("http.timeout").net(10),
    }, function(res, err, code)
        cb(res and true, err, code)
    end)
end

--- 创建目录。WebDAV 对已存在目录通常返回 405/409，这两种结果都视为成功。
---@param path string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return HttpJob
function Webdav:makeCollectionAsync(path, cb)
    return self:_request({ url = self:join(path, true), method = "MKCOL" }, function(res, err, code)
        if res or code == 405 or code == 409 then
            cb(true)
        else
            cb(nil, err)
        end
    end)
end

--- 按层创建目录，上传前调用一次即可。
---@param path string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return CancelHandle|nil
function Webdav:ensurePathAsync(path, cb)
    local clean = trimSlashes(path or "")
    if clean == "" then cb(true); return nil end
    local parts = {}
    for part in clean:gmatch("[^/]+") do parts[#parts + 1] = part end
    local index = 0
    local cancelled = false
    local active
    local function next_part()
        if cancelled then return end
        index = index + 1
        if not parts[index] then cb(true); return end
        local current = table.concat(parts, "/", 1, index)
        active = self:makeCollectionAsync(current, function(ok, err)
            if not ok then cb(nil, err); return end
            next_part()
        end)
    end
    next_part()
    return { cancel = function()
        cancelled = true
        if active then active:cancel() end
    end }
end

--- 删除远端文件。
---@param path string
---@param cb fun(ok: boolean|nil, err: string|nil, code: number|nil) code 仅 HTTP 非 2xx 时给出
---@return HttpJob
function Webdav:deleteAsync(path, cb)
    return self:_request({ url = self:join(path, false), method = "DELETE" }, function(res, err, code)
        cb(res and true, err, code)
    end)
end

return Webdav
