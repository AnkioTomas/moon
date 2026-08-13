--[[--
WebDAV 客户端（HTTP Basic）

  local dav = Webdav.new{ url=, username=, password= }
  dav:ping()
  dav:list(path?)            → entries, err
  dav:get(path, dest, opts?) → true, err      下载到本地文件
  dav:put(path, local_path)  → true, err      上传本地文件
  dav:putBody(path, body)    → true, err      上传字符串
  dav:mkdir(path)            → true, err      MKCOL
  dav:delete(path)           → true, err

entry: { name, path, href, is_dir, size, mtime }

@module koplugin.book.http.webdav
--]]

local lfs = require("libs/libkoreader-lfs")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local util = require("util")
local ffiUtil = require("ffi/util")
local Header = require("http.header")
local Request = require("http.request")
local _ = require("gettext")
local T = require("ffi/util").template

local Webdav = {}
Webdav.__index = Webdav

local PROPFIND_PING = [[<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>]]
local PROPFIND_LIST = [[<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>]]

local function trimSlashes(s)
    s = tostring(s or "")
    local from = s:match("^/*()")
    if from > #s then
        return ""
    end
    return s:match(".*[^/]", from) or ""
end

local function rtrimSlashes(s)
    s = tostring(s or "")
    local n = #s
    while n > 0 and s:sub(n, n) == "/" do
        n = n - 1
    end
    return s:sub(1, n)
end

local function statusErr(code)
    local n = tonumber(code)
    if not n then
        return T(_("请求失败: %1"), tostring(code))
    end
    if n == 401 or n == 403 then
        return _("认证失败，请检查用户名或密码")
    end
    return T(_("HTTP %1"), tostring(n))
end

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

---@param req table
---@param timeout number|nil
---@param block_timeout number|nil
---@return any, table|nil, string|nil
function Webdav:send(req, timeout, block_timeout)
    req.user = self.username
    req.password = self.password
    return Request.send(req, timeout, block_timeout)
end

--- Depth:0 探测根是否可达
---@return boolean|nil, string|nil
function Webdav:ping()
    if self.url == "" then
        return nil, _("未配置 WebDAV 地址")
    end
    local code, _, err = self:send({
        url = self:join("", true),
        method = "PROPFIND",
        headers = Header.forRequest({
            ["Content-Type"] = "application/xml; charset=utf-8",
            ["Depth"] = "0",
            ["Content-Length"] = tostring(#PROPFIND_PING),
        }),
        source = ltn12.source.string(PROPFIND_PING),
        sink = ltn12.sink.table({}),
    })
    if err then
        return nil, err
    end
    if not Request.ok(code) then
        return nil, statusErr(code)
    end
    return true
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

--- 列出目录（PROPFIND Depth:1）
---@param path string|nil 相对 base 的路径
---@return table|nil entries, string|nil err
function Webdav:list(path)
    path = trimSlashes(path or "")
    local url = self:join(path, true)
    local sink = {}
    local code, _, err = self:send({
        url = url,
        method = "PROPFIND",
        headers = Header.forRequest({
            ["Content-Type"] = "application/xml; charset=utf-8",
            ["Depth"] = "1",
            ["Content-Length"] = tostring(#PROPFIND_LIST),
        }),
        source = ltn12.source.string(PROPFIND_LIST),
        sink = ltn12.sink.table(sink),
    })
    if err then
        return nil, err
    end
    if not Request.ok(code) then
        return nil, statusErr(code)
    end
    local xml = table.concat(sink)
    if xml == "" then
        return {}
    end
    return parseList(xml, url, path)
end

--- 下载远程文件到本地 dest
---@param path string
---@param dest string
---@param opts { on_progress: fun(bytes: number)|nil, timeout: number|nil, block_timeout: number|nil }|nil
---@return boolean|nil, string|nil
function Webdav:get(path, dest, opts)
    opts = opts or {}
    local url = self:join(path, false)
    local tmp = dest .. ".part"
    os.remove(tmp)
    local file, open_err = io.open(tmp, "wb")
    if not file then
        return nil, open_err or _("无法创建本地文件")
    end
    local sink = ltn12.sink.file(file)
    if opts.on_progress and socketutil.chainSinkWithProgressCallback then
        sink = socketutil.chainSinkWithProgressCallback(sink, opts.on_progress)
    end
    local code, _, err = self:send({
        url = url,
        method = "GET",
        headers = Header.forDownload(),
        sink = sink,
    }, opts.timeout or 15, opts.block_timeout or 300)
    if err then
        os.remove(tmp)
        return nil, err
    end
    if not Request.ok(code) then
        os.remove(tmp)
        return nil, statusErr(code)
    end
    os.remove(dest)
    if not os.rename(tmp, dest) then
        os.remove(tmp)
        return nil, _("无法保存文件")
    end
    return true
end

---@param path string
---@param source any ltn12 source
---@param length number
---@param opts table|nil
---@return boolean|nil, string|nil
function Webdav:_putSource(path, source, length, opts)
    opts = opts or {}
    local headers = Header.forDownload(opts.headers)
    headers["Content-Length"] = tostring(length or 0)
    if opts.content_type then
        headers["Content-Type"] = opts.content_type
    end
    local code, _, err = self:send({
        url = self:join(path, false),
        method = "PUT",
        headers = headers,
        source = source,
        sink = ltn12.sink.null(),
    }, opts.timeout or 15, opts.block_timeout or 300)
    if err then
        return nil, err
    end
    if not Request.ok(code) then
        return nil, statusErr(code)
    end
    return true
end

--- 上传本地文件
---@param path string 远程相对路径
---@param local_path string
---@param opts table|nil
---@return boolean|nil, string|nil
function Webdav:put(path, local_path, opts)
    local size = lfs.attributes(local_path, "size")
    if not size then
        return nil, _("本地文件不存在")
    end
    local f = io.open(local_path, "rb")
    if not f then
        return nil, _("无法读取本地文件")
    end
    return self:_putSource(path, ltn12.source.file(f), size, opts)
end

--- 上传字符串正文
---@param path string
---@param body string
---@param opts table|nil
---@return boolean|nil, string|nil
function Webdav:putBody(path, body, opts)
    body = tostring(body or "")
    return self:_putSource(path, ltn12.source.string(body), #body, opts)
end

--- 创建目录（MKCOL）
---@param path string
---@return boolean|nil, string|nil
function Webdav:mkdir(path)
    local code, _, err = self:send({
        url = self:join(path, true),
        method = "MKCOL",
        headers = Header.forRequest(),
        sink = ltn12.sink.null(),
    })
    if err then
        return nil, err
    end
    if Request.ok(code) then
        return true
    end
    return nil, statusErr(code)
end

--- 删除文件或目录
---@param path string
---@return boolean|nil, string|nil
function Webdav:delete(path)
    local code, _, err = self:send({
        url = self:join(path, false),
        method = "DELETE",
        headers = Header.forRequest(),
        sink = ltn12.sink.null(),
    })
    if err then
        return nil, err
    end
    if not Request.ok(code) then
        return nil, statusErr(code)
    end
    return true
end

return Webdav
