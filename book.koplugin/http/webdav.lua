--[[--
WebDAV 客户端（HTTP Basic，仅异步）。

PROPFIND / GET / PUT / MKCOL / DELETE。同一根地址上的读写串行，列目录最多四路并发。
连通性探针也在这里：往目录写一个文件、读回比对、再删掉。
业务（静读天下目录、进度文件）不在这里。

@module koplugin.book.http.webdav
--]]

local util = require("util")
local ffiUtil = require("ffi/util")
local Header = require("http.request.header")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("gettext")
local T = ffiUtil.template

require("l10n").apply()

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

--- 同一台 WebDAV 同时只飞一个请求。笔记、统计、书架、上传并行时，PW3 的 Wi-Fi 会把每一路都拖到超时。
---@type table<string, { active: integer, queue: function[] }>
local lanes = {}

--- 列目录允许的同时在飞请求数。完整读写仍串行，避免和笔记 / 上传互相拖垮弱网设备。
local LIST_CONCURRENCY = 4

--- 本进程已经确认存在的目录（完整 URL）。建过或探测过就不再 MKCOL。
---@type table<string, boolean>
local collections = {}

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

--- 同一 url 一条车道：读写（上传、下载、MKCOL 等）limit=1 串行；列目录另一条，最多 LIST_CONCURRENCY 路并发
--- （硬刷新要对大量书文件夹并发 PROPFIND，不能跟读写挤一条串行车道）。
--- start(release) 开始一次请求，结束时必须 release（含失败）。
--- 回调先于 release：回调里再发的请求排在后面，不会和当前这次重叠，也不会死锁。
---@param start fun(release: fun()): { cancel: fun() }|nil
---@param limit integer|nil 缺省 1
---@return { cancel: fun() }
function Webdav:_one(start, limit)
    limit = limit or 1
    local key = limit .. "\0" .. self.url
    local lane = lanes[key]
    if not lane then
        lane = { active = 0, queue = {} }
        lanes[key] = lane
    end
    local handle = {}
    local function go()
        lane.active = lane.active + 1
        local released = false
        local function release()
            if released then return end
            released = true
            lane.active = lane.active - 1
            local nxt = table.remove(lane.queue, 1)
            if nxt then
                nxt()
            elseif lane.active == 0 and lanes[key] == lane then
                lanes[key] = nil
            end
        end
        local job = start(release)
        handle.cancel = function()
            if job and job.cancel then job:cancel() end
            release()
        end
    end
    if lane.active >= limit then
        local entry = go
        lane.queue[#lane.queue + 1] = entry
        handle.cancel = function()
            for i = #lane.queue, 1, -1 do
                if lane.queue[i] == entry then table.remove(lane.queue, i) end
            end
        end
    else
        go()
    end
    return handle
end

--- 带 Basic 凭据发请求：成功 cb(res)；非 2xx cb(nil, 文案, code)；网络错误 cb(nil, err)。
---@param opts HttpRequest
---@param cb fun(res: table|nil, err: string|nil, code: number|nil)
---@param limit integer|nil 车道并发数，见 _one
---@return HttpJob
function Webdav:_request(opts, cb, limit)
    opts.auth_username = self.username
    opts.auth_password = self.password
    return self:_one(function(release)
        local fired = false
        local function finish(res, err)
            if fired then return end
            fired = true
            -- 回调抛错也要放行，否则这条队列会永远占着这台服务器。
            local pok, err_obj = xpcall(function()
                if err then
                    cb(nil, networkErr(err))
                elseif not res or not Request.ok(res.code) then
                    cb(nil, statusErr(res and res.code), res and tonumber(res.code))
                else
                    cb(res)
                end
            end, debug.traceback)
            release()
            if not pok then error(err_obj, 0) end
        end
        local job = Request.request(opts, finish)
        return { cancel = function()
            if job and job.cancel then job:cancel() end
            if not fired then fired = true; release() end
        end }
    end, limit)
end

--- href 归一成不含 scheme/host、去尾斜杠的路径，供和被列目录比较、拼相对路径。
---@param value string
---@return string
local function hrefPath(value)
    local path = (util.urlDecode(value) or value)
    path = util.htmlEntitiesToUtf8(path)
    path = path:match("^https?://[^/]*(.*)$") or path
    return trimSlashes(path)
end

--- 解析 PROPFIND 207 响应。Depth:1 与 Depth:infinity 都按 href 相对被列目录还原路径，
--- 不能只用 basename，否则深层列表会把 `分类/系列/书.epub` 收成根下的 `书.epub`。
---@param xml string
---@param folder_url string
---@param folder_path string
---@return table
local function parseList(xml, folder_url, folder_path)
    local folder_href = hrefPath(folder_url)
    local entries = {}
    for item in xml:gmatch("<[%w_]*:?response[^>]*>(.-)</[%w_]*:?response>") do
        local href = item:match("<[%w_]*:?href[^>]*>(.-)</[%w_]*:?href>")
        if href then
            local full = util.urlDecode(href) or href
            full = util.htmlEntitiesToUtf8(full)
            local full_path = hrefPath(href)
            local is_empty_type = item:find("<[%w_]*:?resourcetype%s*/>")
                or item:find("<[%w_]*:?resourcetype>%s*</[%w_]*:?resourcetype>")
            local is_collection = item:find("<[%w_]*:?collection[^<]*/>")
                or item:find("<[%w_]*:?collection>%s*</[%w_]*:?collection>")
            local is_dir = not is_empty_type and is_collection ~= nil
            local modified = item:match("<[%w_]*:?getlastmodified[^>]*>(.-)</[%w_]*:?getlastmodified>")

            -- 回包里第一条通常是被列目录自身，跳过。
            if not is_dir or full_path ~= folder_href then
                local rel
                local prefix = folder_href == "" and "/" or (folder_href .. "/")
                if full_path:sub(1, #prefix) == prefix then
                    rel = full_path:sub(#prefix + 1)
                else
                    rel = ffiUtil.basename(full)
                end
                local name = ffiUtil.basename(rel)
                entries[#entries + 1] = {
                    name = name,
                    path = folder_path ~= "" and (folder_path .. "/" .. rel) or rel,
                    href = full,
                    is_dir = is_dir,
                    size = is_dir and 0
                        or tonumber(item:match("<[%w_]*:?getcontentlength[^>]*>(%d+)</[%w_]*:?getcontentlength>")) or 0,
                    mtime = modified and Text.parseHttpDate(modified),
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

--- Nonblocking directory listing。opts.depth 缺省 "1"；也支持 "infinity"。
---@param path string|nil
---@param cb fun(entries: WebdavEntry[]|nil, err: string|nil, code: number|nil)
---@param opts { depth?: "1"|"infinity", timeout?: number, connect_timeout?: number }|nil
---@return HttpJob
function Webdav:listAsync(path, cb, opts)
    opts = opts or {}
    path = trimSlashes(path or "")
    local url = self:join(path, true)
    local depth = opts.depth == "infinity" and "infinity" or "1"
    local req = {
        url = url,
        method = "PROPFIND",
        headers = {
            ["Content-Type"] = "application/xml; charset=utf-8",
            ["Depth"] = depth,
        },
        body = PROPFIND_LIST,
    }
    if opts.timeout then req.timeout = opts.timeout end
    if opts.connect_timeout then req.connect_timeout = opts.connect_timeout end
    return self:_request(req, function(res, err, code)
        if not res then
            cb(nil, err, code)
            return
        end
        local xml = res.body or ""
        local prefix = xml:match("<([%w_]*:?)multistatus[%s/>]")
        local complete = prefix and (xml:find("</" .. prefix .. "multistatus%s*>")
            or xml:find("<" .. prefix .. "multistatus[^>]-/%s*>"))
        -- 容量受限时服务器可能回 207 + 部分 response + 507，不能把它当成完整快照。
        if not complete or xml:find("<[%w_]*:?status[^>]*>%s*HTTP/[%d%.]+%s+507[%s<]") then
            cb(nil, _("WebDAV 返回了不完整的目录列表"))
            return
        end
        cb(parseList(xml, url, path))
    end, LIST_CONCURRENCY)
end

--- Nonblocking download to dest.
---@param path string
---@param dest string
---@param opts table|nil
---@param cb fun(ok: boolean|nil, err: string|nil, code: number|nil) code 仅 HTTP 非 2xx 时给出
---@return HttpJob
function Webdav:getAsync(path, dest, opts, cb)
    opts = opts or {}
    return self:_one(function(release)
        local fired = false
        local function finish(ok, err, res)
            if fired then return end
            fired = true
            local pok, err_obj = xpcall(function()
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
            end, debug.traceback)
            release()
            if not pok then error(err_obj, 0) end
        end
        local job = Request.download({
            url = self:join(path, false),
            headers = Header.forDownload(opts.headers),
            auth_username = self.username,
            auth_password = self.password,
            timeout = opts.timeout or require("http.timeout").net(10),
            on_progress = opts.on_progress,
        }, dest, finish)
        return { cancel = function()
            if job and job.cancel then job:cancel() end
            if not fired then fired = true; release() end
        end }
    end)
end

--- 上传本地文件到 WebDAV。timeout 缺省是下载档（整本 epub）；笔记 / 统计 / 进度传普通请求超时。
--- opts.allow_empty：允许 0 字节（设置文件可以是空的）。opts.headers 追加到请求头。
---@param path string
---@param local_path string
---@param cb fun(ok: boolean|nil, err: string|nil, code: number|nil) code 非 nil 表示服务器回了状态码，nil 是传输层失败
---@param timeout number|nil
---@param opts { allow_empty?: boolean, headers?: table<string, string> }|nil
---@return HttpJob|nil
function Webdav:putFileAsync(path, local_path, cb, timeout, opts)
    opts = type(opts) == "table" and opts or {}
    local file, open_err = io.open(local_path, "rb")
    if not file then
        cb(nil, open_err or _("无法读取待上传文件"))
        return nil
    end
    local size = file:seek("end")
    file:close()
    local headers = { ["Content-Type"] = "application/octet-stream" }
    for key, value in pairs(opts.headers or {}) do headers[key] = value end
    if not size or size == 0 then
        if not opts.allow_empty then
            cb(nil, _("待上传文件为空"))
            return nil
        end
        -- Content-Length: 0 写进头。body_size = 0 在请求层是假值，不会被写出去。
        headers["Content-Length"] = "0"
        return self:_request({
            url = self:join(path, false),
            method = "PUT",
            headers = Header.forRequest(headers),
            body = "",
            timeout = timeout or require("http.timeout").net(10),
        }, function(res, err, code)
            cb(res and true, err, code)
        end)
    end
    return self:_request({
        url = self:join(path, false),
        method = "PUT",
        headers = Header.forRequest(headers),
        body_file = local_path,
        body_size = size,
        timeout = timeout or require("http.timeout").net(10),
    }, function(res, err, code)
        cb(res and true, err, code)
    end)
end

--- 创建目录。405 是目录已在。409 先列一下：列得出来才当已存在，列不出来就是父目录没有，不能当成成功。
---@param path string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return HttpJob|nil
function Webdav:makeCollectionAsync(path, cb)
    local url = self:join(path, true)
    if collections[url] then cb(true); return nil end
    return self:_request({ url = url, method = "MKCOL" }, function(res, err, code)
        if res or code == 405 then
            collections[url] = true
            cb(true)
        elseif code == 409 then
            self:listAsync(path, function(entries)
                if entries then collections[url] = true; cb(true) else cb(nil, err) end
            end)
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

--- 连通性探针：在目录里写入、读回比对、再删除。临时文件用完即删。
---@param path string 目录（相对根地址）
---@param cb fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
function Webdav:probeAsync(path, cb)
    local Paths = require("utils.paths")
    local Fs = require("utils.fs")
    local root = trimSlashes(path or "")
    local remote = (root ~= "" and (root .. "/") or "") .. ".moon-webdav-test"
    local upload = Paths.tmpname(".upload")
    local download = Paths.tmpname(".download")
    local token = "moon-webdav-test " .. os.time() .. " " .. math.random(1e9)
    local file = io.open(upload, "wb")
    local written = file and file:write(token)
    local closed = file and file:close()
    if not (written and closed) then
        os.remove(upload)
        cb(false, _("无法创建测试文件"))
        return { cancel = function() end }
    end
    local cancelled, active = false, nil
    local function finish(ok, stage, err)
        os.remove(upload)
        os.remove(download)
        if cancelled then return end
        cb(ok == true, not ok and (stage .. (err or "")) or nil)
    end
    local function verify()
        if Fs.read(download) ~= token then finish(false, _("读回内容与写入不一致")); return end
        active = self:deleteAsync(remote, function(ok, err)
            finish(ok == true, _("删除失败："), err)
        end)
    end
    active = self:ensurePathAsync(root, function(ok_dir, dir_err)
        if not ok_dir then finish(false, _("创建目录失败："), dir_err); return end
        active = self:putFileAsync(remote, upload, function(ok_put, put_err)
            if not ok_put then finish(false, _("写入失败："), put_err); return end
            active = self:getAsync(remote, download, nil, function(ok_get, get_err)
                if not ok_get then finish(false, _("读取失败："), get_err); return end
                verify()
            end)
        end)
    end)
    return { cancel = function()
        cancelled = true
        if active and active.cancel then active:cancel() end
        os.remove(upload)
        os.remove(download)
    end }
end

return Webdav
