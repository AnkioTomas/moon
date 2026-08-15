--[[--
WebDAV 客户端（HTTP Basic，仅异步）

  local dav = Webdav.new{ url=, username=, password= }
  dav:listAsync(path?, cb)           → entries, err
  dav:getAsync(path, dest, opts?, cb) → true, err

@module koplugin.book.http.webdav
--]]

local util = require("util")
local ffiUtil = require("ffi/util")
local Header = require("http.header")
local Request = require("http.request")
local _ = require("gettext")
local T = require("ffi/util").template

--- PROPFIND 列表项
---@class WebdavEntry
---@field name string 显示名
---@field path string 相对 base 的路径
---@field href string 原始 href
---@field is_dir boolean 是否目录
---@field size number|nil 字节数
---@field mtime string|nil Last-Modified 原文

---@class WebdavClient
---@field url string 根 URL（已去尾斜杠）
---@field username string
---@field password string
---@field join fun(self: WebdavClient, path: string|nil, as_dir: boolean|nil): string 拼接 URL
---@field listAsync fun(self: WebdavClient, path: string|nil, cb: fun(entries: WebdavEntry[]|nil, err: string|nil)): { cancel: fun() }
---@field getAsync fun(self: WebdavClient, path: string, dest: string, opts: table|nil, cb: fun(ok: boolean|nil, err: string|nil)): { cancel: fun() }
---@field putFileAsync fun(self: WebdavClient, path: string, local_path: string, cb: fun(ok: boolean|nil, err: string|nil)): { cancel: fun() }|nil

local Webdav = {}
Webdav.__index = Webdav

local PROPFIND_LIST = [[<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>]]

--- 去掉首尾斜杠
---@param s string|nil
---@return string
local function trimSlashes(s)
    s = tostring(s or "")
    local from = s:match("^/*()")
    if from > #s then
        return ""
    end
    return s:match(".*[^/]", from) or ""
end

--- 去掉尾部斜杠
---@param s string|nil
---@return string
local function rtrimSlashes(s)
    s = tostring(s or "")
    local n = #s
    while n > 0 and s:sub(n, n) == "/" do
        n = n - 1
    end
    return s:sub(1, n)
end

--- HTTP 状态码转用户可读错误文案
---@param code any
---@param detail string|nil
---@return string
local function statusErr(code, detail)
    local n = tonumber(code)
    if not n then
        return T(_("请求失败: %1"), tostring(code))
    end
    if n == 401 or n == 403 then
        return _("认证失败，请检查用户名或密码")
    end
    local base = T(_("HTTP %1"), tostring(n))
    if type(detail) == "string" and detail ~= "" then
        return base .. ": " .. detail
    end
    return base
end

--- 构造 WebDAV 客户端
---@param cfg { url: string, username: string|nil, password: string|nil, user: string|nil }|nil
---@return WebdavClient
function Webdav.new(cfg)
    cfg = cfg or {}
    local self = setmetatable({}, Webdav)
    self.url = rtrimSlashes(cfg.url or "")
    self.username = cfg.username or cfg.user or ""
    self.password = cfg.password or ""
    return self
end

--- 拼接 base + path（保留路径斜杠，段编码）
---@param path string|nil
---@param as_dir boolean|nil 目录 URL 强制尾斜杠
---@return string
function Webdav:join(path, as_dir)
    local base = rtrimSlashes(self.url)
    path = trimSlashes(path or "")
    local encoded = path ~= "" and (util.urlEncode(path, "/") or path) or ""
    local url = encoded ~= "" and (base .. "/" .. encoded) or base
    if as_dir and url:sub(-1) ~= "/" then
        url = url .. "/"
    end
    return url
end

--- 解析 PROPFIND 207 响应
---@param xml string
---@param folder_url string
---@param folder_path string
---@return table
local function parseList(xml, folder_url, folder_path)
    local folder_href = trimSlashes(util.urlDecode(folder_url:match("^https?://[^/]*(.*)$") or folder_url))
    local entries = {}
    for item in xml:gmatch("<[^:]*:response[^>]*>(.-)</[^:]*:response>") do
        local href = item:match("<[^:]*:href[^>]*>(.-)</[^:]*:href>")
        if href then
            local full = util.urlDecode(href) or href
            full = util.htmlEntitiesToUtf8(full)
            local name = ffiUtil.basename(full)
            local is_empty_type = item:find("<[^:]*:resourcetype%s*/>")
                or item:find("<[^:]*:resourcetype>%s*</[^:]*:resourcetype>")
            local is_collection = item:find("<[^:]*:collection[^<]*/>")
                or item:find("<[^:]*:collection>%s*</[^:]*:collection>")
            local is_dir = (not is_empty_type) and is_collection

            local child_path = folder_path ~= "" and (folder_path .. "/" .. name) or name
            if is_dir then
                if trimSlashes(full) ~= folder_href then
                    table.insert(entries, {
                        name = name,
                        path = child_path,
                        href = full,
                        is_dir = true,
                        size = 0,
                        mtime = nil,
                    })
                end
            else
                local size = tonumber(item:match("<[^:]*:getcontentlength[^>]*>(%d+)</[^:]*:getcontentlength>")) or 0
                local mtime = item:match("<[^:]*:getlastmodified[^>]*>(.-)</[^:]*:getlastmodified>")
                table.insert(entries, {
                    name = name,
                    path = child_path,
                    href = full,
                    is_dir = false,
                    size = size,
                    mtime = mtime,
                })
            end
        end
    end
    table.sort(entries, function(a, b)
        if a.is_dir ~= b.is_dir then
            return a.is_dir
        end
        return (a.name or "") < (b.name or "")
    end)
    return entries
end

--- Nonblocking Depth:1 directory listing.
---@param path string|nil
---@param cb fun(entries: WebdavEntry[]|nil, err: string|nil)
---@return { cancel: fun() }
function Webdav:listAsync(path, cb)
    path = trimSlashes(path or "")
    local url = self:join(path, true)
    return Request.request({
        url = url,
        method = "PROPFIND",
        headers = {
            ["Content-Type"] = "application/xml; charset=utf-8",
            ["Depth"] = "1",
            ["Content-Length"] = tostring(#PROPFIND_LIST),
        },
        body = PROPFIND_LIST,
        auth_username = self.username,
        auth_password = self.password,
    }, function(res, err)
        if err then
            cb(nil, err)
        elseif not Request.ok(res and res.code) then
            cb(nil, statusErr(res and res.code))
        else
            local xml = res.body or ""
            cb(xml == "" and {} or parseList(xml, url, path))
        end
    end)
end

--- Nonblocking download to dest.
---@param path string
---@param dest string
---@param opts table|nil
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Webdav:getAsync(path, dest, opts, cb)
    opts = opts or {}
    return Request.download({
        url = self:join(path, false),
        method = "GET",
        headers = Header.forDownload(opts.headers),
        auth_username = self.username,
        auth_password = self.password,
        timeout = opts.timeout or 300,
        on_progress = opts.on_progress,
    }, dest, function(ok, err, res)
        if ok then
            cb(true)
        elseif res and res.code and not Request.ok(res.code) then
            local body_msg = type(res.body) == "string" and res.body:sub(1, 200) or nil
            cb(nil, statusErr(res.code, body_msg))
        else
            cb(nil, err)
        end
    end)
end

--- 上传本地文件到 WebDAV。
---@param path string
---@param local_path string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Webdav:putFileAsync(path, local_path, cb)
    local file, open_err = io.open(local_path, "rb")
    if not file then
        cb(nil, open_err or _("无法读取待上传文件"))
        return nil
    end
    local body = file:read("*a")
    file:close()
    if type(body) ~= "string" or body == "" then
        cb(nil, _("待上传文件为空"))
        return nil
    end
    return Request.request({
        url = self:join(path, false),
        method = "PUT",
        headers = Header.forRequest({
            ["Content-Type"] = "application/octet-stream",
            ["Content-Length"] = tostring(#body),
        }),
        body = body,
        auth_username = self.username,
        auth_password = self.password,
        timeout = 300,
    }, function(res, err)
        if err then
            cb(nil, err)
        elseif not Request.ok(res and res.code) then
            cb(nil, statusErr(res and res.code))
        else
            cb(true)
        end
    end)
end

return Webdav
