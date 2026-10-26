--[[--
远程管理 HTTP 服务核心：LuaSocket TCP + 增量状态机。

挂接：start 后由 UIManager:insertZMQ(server) 驱动 waitEvent
（UIManager 把它当迭代器反复调用，返回 nil = 本轮无更多工作；
空闲时至迟 50ms 再来一轮，见 UIManager ZMQ_TIMEOUT）。

- 上传 = raw body（PUT/POST /upload?dir=…&name=…），不做 multipart：
  网页用 fetch 直传文件体，curl -T 同理；
- 收发全零超时非阻塞，单次 waitEvent 自限时间片（默认 25ms），传大文件不冻 UI；
- 文件系统 IO 全经 handlers 注入，本模块只管 HTTP 协议。

新增 API：在 file.lua / input.lua / 新模块写路由函数（首参即 server 实例），server.lua 顶部挂成 Server._routeXxx 并在 Server:_route 分派；
路由模块不反向 require server。路径必须落在受管根内，前缀检查用 realpath 后的路径。server 核心禁止 require Widget / NetworkMgr。

@module koplugin.book.features.remote.server
--]]

local socket = require("socket")
local logger = require("utils.log")
local JSON = require("json")
local Text = require("utils.text")

local HEADER_LIMIT = 32 * 1024 -- 扩展回调的 GET 查询串最长 16 KiB（cookie 登录态），另留请求头余量
local CHUNK = 32 * 1024
--- 无字节进展的连接存活上限（秒）；pending 状态（写入中）用 PENDING_TIMEOUT
local IDLE_TIMEOUT = 120
--- pending（等落位 / 安装回调）的存活上限（秒）。回调丢了就永远不回收，
--- 连接与临时文件一起挂着，因此豁免必须有尽头。大文件落位可能很慢，给足余量。
local PENDING_TIMEOUT = 30 * 60
--- 同时在途连接上限。到顶后直接拒绝新连接：设备内存与 fd 都很紧，
--- 没有上限时一个 for 循环的 curl 就能把 KOReader 拖死。
local MAX_CONNS = 32

local STATUS = {
    [200] = "OK",
    [201] = "Created",
    [400] = "Bad Request",
    [403] = "Forbidden",
    [404] = "Not Found",
    [405] = "Method Not Allowed",
    [409] = "Conflict",
    [411] = "Length Required",
    [413] = "Payload Too Large",
    [422] = "Unprocessable Content",
    [431] = "Request Header Fields Too Large",
    [500] = "Internal Server Error",
    [501] = "Not Implemented",
    [502] = "Bad Gateway",
}

---@class RemoteHandlers
---@field list_dir fun(path: string, cb: fun(entries: table[]|nil, err: any)) 异步目录列表
---@field is_dir fun(path: string): boolean 路径是否为目录（上传前单次校验）
---@field resolve_download fun(path: string): string|nil 存在且是普通文件才返回路径
---@field downloaded fun(path: string)|nil 文件整份发完后回调（下载中途断开不触发）
---@field path_exists fun(path: string): boolean 路径是否已存在（上传重名预检）
---@field save fun(temp: string, dir: string, name: string, cb: fun(ok: boolean|nil, err: any), conflict: "overwrite"|"skip"|"rename"|nil) 上传落位（可异步）
---@field mkdir fun(path: string, cb: fun(ok: boolean|nil, err: any))
---@field delete fun(path: string, cb: fun(ok: boolean|nil, err: any))
---@field rename fun(path: string, to: string, cb: fun(ok: boolean|nil, err: any))
---@field extract fun(path: string, cb: fun(ok: boolean|nil, err: any, output: string|nil))
---@field temp_path fun(): string 上传临时落盘路径
---@field is_protected fun(path: string): boolean 重要路径及其祖先不可删除/移动（展示级判定，可免 realpath；变更 handler 内部仍全量校验）
---@field get_input fun(): { active: boolean, text: string|nil } 设备激活输入框状态与当前文本
---@field set_input fun(text: string): boolean|nil, any 光标处追加注入（addChars 路径）；无激活框返回 nil, err
---@field get_clipboard fun(): { text: string } 设备共享剪贴板（最后复制的文本）
---@field set_clipboard fun(text: string) 写入设备剪贴板并同步进激活输入框
---@field get_status fun(): table 首页设备状态快照
---@field install_update fun(temp: string, cb: fun(ok: boolean, err: string|nil)) 安装上传的月读插件包（临时文件所有权移交）
---@field backup_zip fun(cb: fun(output: string|nil, err: any))|nil 打包 .moon（不含日志与缓存）
---@field reset_config fun(cb: fun(ok: boolean, err: string|nil))|nil 清除全部配置与 crash.log，成功后设备提示并重启
---@field restore_backup fun(temp: string, cb: fun(ok: boolean, err: string|nil))|nil 用上传的备份包替换 .moon，成功后设备提示并重启

--- 一切非 2xx 响应都是 JSON {"error": msg}：页面能把真实原因显示出来，
--- 而不是 r.json() 解析纯文本炸出 SyntaxError 掩盖问题。

local Server = {}
Server.__index = Server

-- 路由实现拆分：文件、远程输入、共享剪贴板、远程配置、月读更新各自独立。
-- （函数首参即 self；不反向 require server，无循环）
local File = require("features.remote.file")
local Input = require("features.remote.input")
local Clipboard = require("features.remote.clipboard")
local Status = require("features.remote.status")
local SettingsRoute = require("features.remote.settings_route")
local UpdateRoute = require("features.remote.update")
local BackupRoute = require("features.remote.backup")
local ExtRoute = require("features.remote.ext_route")
Server._routeList = File.list
Server._routeDownload = File.download
Server._routeUpload = File.upload
Server._routeMutate = File.mutate
Server._routeRename = File.rename
Server._routeExtract = File.extract
Server._routeTransfer = File.transfer
Server._routeStat = File.stat
Server._routeWrite = File.write
Server._routeZip = File.zip
Server._routeInput = Input.route
Server._routeClipboard = Clipboard.route
Server._routeStatus = Status.route
Server._routeSettings = SettingsRoute.settings
Server._routeUpdate = UpdateRoute.route
Server._routeBackup = BackupRoute.route
Server._routeReset = BackupRoute.reset
Server._routeExt = ExtRoute.route

--- idle_timeout：连续这么多秒没有任何在途连接就调一次 on_idle（nil = 不检测）。
---@param o { host: string|nil, port: number, handlers: RemoteHandlers, root: string, roots: string[]|nil, home: string|nil, shortcuts: table[]|nil, slice: number|nil, idle_timeout: number|nil, on_idle: fun()|nil }
---@return table
function Server.new(o)
    assert(type(o.handlers) == "table", "features.remote.server: handlers required")
    assert(type(o.root) == "string", "features.remote.server: root required")
    assert(not o.idle_timeout or o.on_idle, "features.remote.server: on_idle required with idle_timeout")
    return setmetatable({
        host = o.host or "*",
        port = o.port,
        handlers = o.handlers,
        root = o.root,
        roots = o.roots or { o.root },
        home = o.home or o.root, -- 页面默认路径
        shortcuts = o.shortcuts or {},
        slice = o.slice or 0.025,
        idle_timeout = o.idle_timeout,
        on_idle = o.on_idle,
        _conns = {},
        _active_at = socket.gettime(),
    }, Server)
end

--- 运行中切换空闲超时并重新计时：否则刚打开开关就可能因为早已空闲而立刻停服。
---@param seconds number|nil nil = 关闭空闲检测
function Server:setIdleTimeout(seconds)
    self.idle_timeout = seconds
    self._active_at = socket.gettime()
end

--- 原子替换文件管理范围；运行中的连接后续路由立即使用新布局。
---@param o { root: string, roots: string[], home: string|nil, shortcuts: table[]|nil }
function Server:updateLayout(o)
    self.root = o.root
    self.roots = o.roots
    self.home = o.home or o.root
    self.shortcuts = o.shortcuts or {}
end

---@return boolean ok, string|nil err
function Server:start()
    if self._sock then
        return true
    end
    local sock, err = socket.bind(self.host, self.port)
    if not sock then
        return false, err
    end
    sock:settimeout(0)
    self._sock = sock
    self._active_at = socket.gettime()
    logger.info("book remote listening on", self.host, self.port)
    return true
end

--- 静态资源内存缓存（停服即释放，512MB 机器上不常驻）。
local _asset_cache = {} ---@type table<string, { body: string, stamp: string|nil }>

--- 关停：断开全部在途连接并关闭监听 socket；可重复调用。
function Server:stop()
    for _idx, conn in ipairs(self._conns) do
        self:_kill(conn)
    end
    self._conns = {}
    if self._zip then -- 未取走的打包下载临时文件
        os.remove(self._zip.path)
        self._zip = nil
    end
    if self._sock then
        self._sock:close()
        self._sock = nil
    end
    _asset_cache = {}
end

--- UIManager 轮询入口：一小片工作，nil=本轮结束。
function Server:waitEvent()
    if not self._sock then
        return nil
    end
    self:_accept()
    local deadline = socket.gettime() + self.slice
    local progress = true
    while progress do
        progress = false
        for i = #self._conns, 1, -1 do
            local conn = self._conns[i]
            if self:_step(conn) then
                progress = true
            end
            if conn.dead then
                table.remove(self._conns, i)
            end
        end
        if socket.gettime() >= deadline then
            break
        end
    end
    self:_reapIdle()
    -- 在途连接（含等文件系统回调的 pending）都算活跃；网页开着会定时轮询，自然续期。
    local now = socket.gettime()
    if #self._conns > 0 then
        self._active_at = now
    elseif self.idle_timeout and now - self._active_at >= self.idle_timeout then
        logger.info("book remote idle for", self.idle_timeout, "s")
        self.on_idle()
    end
    return nil
end

-- ── 连接生命周期 ─────────────────────────────────────

--- 标记连接死亡并释放其占用：socket、正在写的文件、未移交的上传临时文件。
---@param conn table
function Server:_kill(conn)
    conn.dead = true
    conn.sock:close()
    if conn.file then
        conn.file:close()
        conn.file = nil
    end
    -- 下载中途断开（浏览器点取消、超时回收）时 body_file 还开着：
    -- 不关就是每次一个 fd，几十次下载后 accept 直接 EMFILE。
    if conn.body_file then
        conn.body_file:close()
        conn.body_file = nil
    end
    if conn.temp then
        os.remove(conn.temp)
        conn.temp = nil
    end
end

--- 收干监听队列里所有新连接，各建一条 headers 状态的连接记录（非阻塞）。
function Server:_accept()
    while true do
        local client = self._sock:accept()
        if not client then
            return
        end
        if #self._conns >= MAX_CONNS then
            logger.warn("book remote too many connections, dropping", #self._conns)
            client:close()
            return
        end
        client:settimeout(0)
        self._conns[#self._conns + 1] = {
            sock = client,
            state = "headers",
            buf = "",
            out = "",
            out_off = 1,
            touched = socket.gettime(),
        }
    end
end

--- 回收无进展的连接。pending（等 save 回调）用更宽的 PENDING_TIMEOUT 而非无限豁免：
--- 回调因异常丢失时连接和上传临时文件会永久挂着。
function Server:_reapIdle()
    local now = socket.gettime()
    for i = #self._conns, 1, -1 do
        local conn = self._conns[i]
        local limit = conn.state == "pending" and PENDING_TIMEOUT or IDLE_TIMEOUT
        if not conn.dead and now - conn.touched > limit then
            logger.warn("book remote idle timeout, closing conn", conn.state)
            self:_kill(conn)
            table.remove(self._conns, i)
        end
    end
end

--- 按连接当前状态推进一小步（headers/body/pending/respond）。
---@param conn table
---@return boolean 本轮是否有进展
function Server:_step(conn)
    if conn.dead then
        return false
    end
    if conn.state == "headers" then
        return self:_readHeaders(conn)
    elseif conn.state == "body" then
        return self:_readBody(conn)
    elseif conn.state == "pending" then
        return self:_checkPending(conn)
    elseif conn.state == "continue" then
        return self:_writeContinue(conn)
    elseif conn.state == "respond" then
        return self:_write(conn)
    end
    return false
end

--- 严格解析 Content-Length；HTTP 只允许十进制非负整数。
---@param headers table
---@return number|nil length
---@return string|nil err "missing"|"invalid"
function Server:_contentLength(headers)
    local raw = headers["content-length"]
    if type(raw) ~= "string" or raw == "" then
        return nil, "missing"
    end
    if not raw:match("^%d+$") then
        return nil, "invalid"
    end
    local len = tonumber(raw)
    if not len or len == math.huge then
        return nil, "invalid"
    end
    return len
end

-- ── headers ──────────────────────────────────────────

--- 收字节直到出现空行分隔，随即分发路由；超 HEADER_LIMIT 回 431。
--- 空行之后的残留字节留在 conn.buf，归 body 阶段消费。
---@param conn table
---@return boolean 本轮是否读到字节
function Server:_readHeaders(conn)
    local data, err, partial = conn.sock:receive(CHUNK)
    local got = data or partial
    if err == "closed" and (not got or #got == 0) then
        self:_kill(conn)
        return false
    end
    if got and #got > 0 then
        conn.touched = socket.gettime()
        conn.buf = conn.buf .. got
    end
    local split = conn.buf:find("\r\n\r\n", 1, true)
    if not split then
        if #conn.buf > HEADER_LIMIT then
            self:_fail(conn, 431, "Headers too large")
        end
        return got ~= nil and #got > 0
    end
    local head = conn.buf:sub(1, split - 1)
    conn.buf = conn.buf:sub(split + 4) -- 残留字节属于 body
    self:_route(conn, head)
    return true
end

-- ── 页面与静态资源 ─────────────────────────────────────

-- 一切页面资源都是静态路由（不注入模板）；实例配置走 /api/config。
local HTML_DIR = (debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or ".") .. "/html"

local ASSETS = {
    ["/"] = { "index.html", "text/html; charset=utf-8" },
    ["/index.html"] = { "index.html", "text/html; charset=utf-8" },
    ["/file.html"] = { "file.html", "text/html; charset=utf-8" },
    ["/input.html"] = { "input.html", "text/html; charset=utf-8" },
    ["/clipboard.html"] = { "clipboard.html", "text/html; charset=utf-8" },
    ["/settings.html"] = { "settings.html", "text/html; charset=utf-8" },
    ["/update.html"] = { "update.html", "text/html; charset=utf-8" },
    ["/logo.jpg"] = { "logo.jpg", "image/jpeg" },
    ["/favicon.ico"] = { "favicon.ico", "image/x-icon" },
    ["/apple-touch-icon.png"] = { "apple-touch-icon.png", "image/png" },
    ["/style.css"] = { "style.css", "text/css; charset=utf-8" },
    ["/js.js"] = { "js.js", "application/javascript; charset=utf-8" },
    ["/index.js"] = { "index.js", "application/javascript; charset=utf-8" },
    ["/file.js"] = { "file.js", "application/javascript; charset=utf-8" },
    ["/input.js"] = { "input.js", "application/javascript; charset=utf-8" },
    ["/clipboard.js"] = { "clipboard.js", "application/javascript; charset=utf-8" },
    ["/settings.js"] = { "settings.js", "application/javascript; charset=utf-8" },
    ["/update.js"] = { "update.js", "application/javascript; charset=utf-8" },
}

--- 文件戳（mtime+size）；取不到 lfs（离线测试）时返回 nil，退化为永久缓存。
---@param path string
---@return string|nil
local function assetStamp(path)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok or type(lfs) ~= "table" or not lfs.attributes then return nil end
    local attr = lfs.attributes(path)
    if not attr then return nil end
    return tostring(attr.modification) .. ":" .. tostring(attr.size)
end

--- 读静态资源（二进制安全 "rb"，按 mtime+size 失效的内存缓存：插件热更新/替换文件后
--- 不必重启 KOReader 就能拿到新内容）。读不到是打包缺文件，回 500 把原因亮出来。
---@param name string
---@return string|nil body
---@return string|nil err
---@param full string|nil 绝对路径（扩展提供者开放的文件）；缺省读 html 目录
local function readAsset(name, full)
    local path = full or HTML_DIR .. "/" .. name
    local stamp = assetStamp(path)
    local hit = _asset_cache[path]
    if hit and hit.stamp == stamp then return hit.body end
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local s = f:read("*all")
    f:close()
    _asset_cache[path] = { body = s, stamp = stamp }
    return s
end

--- query 串 → 表（urlDecode 键值）
---@param qs string|nil
---@return table
local function parseQuery(qs)
    local query = {}
    for pair in (qs or ""):gmatch("[^&]+") do
        local k, v = pair:match("^(.-)=(.*)$")
        if k then
            query[Text.urlDecode(k)] = Text.urlDecode(v)
        end
    end
    return query
end

--- 规范绝对路径，消掉重复斜杠、. 与 ..。
---@return string|nil
local function cleanPath(p)
    if type(p) ~= "string" or p:sub(1, 1) ~= "/" then
        return nil
    end
    local parts = {}
    for part in p:gmatch("[^/]+") do
        if part == ".." then
            if #parts == 0 then
                return nil
            end
            parts[#parts] = nil
        elseif part ~= "." then
            parts[#parts + 1] = part
        end
    end
    return "/" .. table.concat(parts, "/")
end

-- 路由模块（features.remote.file）以 self.cleanPath 使用
Server.cleanPath = cleanPath

--- 只做路径规范化。不按 managed roots 截断：文件管理可以走出快捷入口。
---@return string|nil
function Server:_safePath(p)
    return cleanPath(p)
end

--- 取上级目录。只有 `/` 没有上级。
---@param path string
---@return string|nil
function Server:_parent(path)
    local parent = path:match("^(.*)/[^/]+$")
    if parent == "" then
        parent = "/"
    end
    return parent and self:_safePath(parent) or nil
end

--- 路径是否正好是某个 managed root。
---@param path string
---@return boolean
function Server:_isRoot(path)
    for _idx, root in ipairs(self.roots) do
        if path == root then
            return true
        end
    end
    return false
end

--- Host 是域名说明是 DNS rebinding：浏览器会把它当同源，于是恶意页面里的脚本
--- 能拿设备当自己的后端。只认 IP / localhost 字面量；无 Host 头不是浏览器，放过。
---@param headers table
---@return boolean
local function hostIsLiteral(headers)
    local host = headers["host"]
    if type(host) ~= "string" or host == "" then
        return true
    end
    -- 去掉端口：[::1]:9528 / 192.168.1.5:9528 / ::1 / localhost
    local name = host:match("^%[(.-)%]") or host:match("^([^:]+):%d+$") or host
    return name == "localhost"
        or name:match("^%d+%.%d+%.%d+%.%d+$") ~= nil
        or (name:find(":", 1, true) ~= nil and name:match("^[%x:]+$") ~= nil)
end

--- 跨站写请求拦截：Origin 缺失（curl 等非浏览器）放过，存在则必须与 Host 一致。
---
--- `Origin: null` 必须拒绝：沙箱 iframe、data:/file: 页面发出的请求就长这样，
--- 恰好是攻击者能构造的场景。放过它等于给跨站写开了个后门。
---@param headers table
---@return boolean
local function sameOrigin(headers)
    local origin = headers["origin"]
    if type(origin) ~= "string" or origin == "" then
        return true
    end
    if origin == "null" then
        return false
    end
    return origin:match("^https?://(.+)$") == headers["host"]
end

--- 解析请求行 + headers 并分发路由；失败直接排响应。
--- 顺序固定：静态资源（仅 GET，否则 405）→
--- Host 字面量校验（403，防 DNS rebinding）→ 非 GET 的同源校验（403）→ API 路由；
--- 全不匹配回 404。
---@param conn table
---@param head string 请求行 + headers 原文（不含结尾空行）
function Server:_route(conn, head)
    local first = head:match("^([^\r\n]+)") or ""
    local method, uri = first:match("^(%S+)%s+(%S+)%s+HTTP/%d%.%d$")
    if not method then
        return self:_fail(conn, 400, "Bad request line")
    end
    local headers = {}
    for line in head:gmatch("\r\n([^\r\n]+)") do
        local k, v = line:match("^([%w%-]+):%s*(.-)%s*$")
        if k then
            headers[k:lower()] = v
        end
    end
    local path, qs = uri:match("^([^?]*)%??(.*)$")
    path = Text.urlDecode(path or "")
    ---@cast path string
    local query = parseQuery(qs)

    local asset = ASSETS[path]
    if not asset then asset = ExtRoute.asset(path) end
    if asset then
        if method ~= "GET" then
            return self:_fail(conn, 405, "Method Not Allowed")
        end
        local body, err = readAsset(asset[1], asset[3])
        if not body then
            return self:_fail(conn, 500, err)
        end
        return self:_queueResponse(conn, { code = 200, ctype = asset[2], body = body })
    end

    if not hostIsLiteral(headers) then
        return self:_fail(conn, 403, "Bad host")
    end
    -- 非 GET 都是 CORS「简单请求」：不校验来源的话，用户打开恶意页面就能删文件、
    -- 改配置（攻击者读不到响应也无所谓，副作用已经发生）。
    if method ~= "GET" and not sameOrigin(headers) then
        return self:_fail(conn, 403, "Cross-origin request rejected")
    end

    if path == "/api/config" then
        if method ~= "GET" then
            return self:_fail(conn, 405, "Method Not Allowed")
        end
        return self:_json(conn, 200, JSON.encode({
            root = self.root,
            home = self.home,
            shortcuts = self.shortcuts,
        }))
    elseif path == "/api/pages" then
        if method ~= "GET" then
            return self:_fail(conn, 405, "Method Not Allowed")
        end
        return self:_json(conn, 200, JSON.encode(ExtRoute.pages()))
    elseif path == "/api/i18n" then
        return self:_routeI18n(conn, method)
    elseif path == "/api/logs.zip" then
        return self:_routeLogs(conn, method)
    elseif path == "/api/list" then
        return self:_routeList(conn, method, query.path)
    elseif path == "/download" then
        return self:_routeDownload(conn, method, query.path, query.inline)
    elseif path == "/upload" then
        return self:_routeUpload(conn, method, headers, query.dir, query.name, query.conflict)
    elseif path == "/api/mkdir" then
        return self:_routeMutate(conn, method, query.path, "mkdir")
    elseif path == "/api/delete" then
        return self:_routeMutate(conn, method, query.path, "delete")
    elseif path == "/api/input" then
        return self:_routeInput(conn, method, headers, query)
    elseif path == "/api/clipboard" then
        return self:_routeClipboard(conn, method, headers, query)
    elseif path == "/api/status" then
        return self:_routeStatus(conn, method)
    elseif path == "/api/rename" then
        return self:_routeRename(conn, method, query)
    elseif path == "/api/extract" then
        return self:_routeExtract(conn, method, query.path)
    elseif path == "/api/copy" or path == "/api/move" then
        return self:_routeTransfer(conn, method, query, path == "/api/copy" and "copy" or "move")
    elseif path == "/api/stat" then
        return self:_routeStat(conn, method, query.path)
    elseif path == "/api/write" then
        return self:_routeWrite(conn, method, headers, query)
    elseif path == "/api/zip" then
        return self:_routeZip(conn, method, headers, query)
    elseif path == "/api/settings" then
        return self:_routeSettings(conn, method, headers, query)
    elseif path == "/api/update" then
        return self:_routeUpdate(conn, method, headers)
    elseif path == "/api/backup" then
        return self:_routeBackup(conn, method, headers)
    elseif path == "/api/reset" then
        return self:_routeReset(conn, method)
    end
    local ext_name, ext_action = path:match("^/api/([%w_]+)/([%w_]+)$")
    local ext = ext_name and ExtRoute.find(ext_name)
    if ext then
        return self:_routeExt(conn, method, headers, query, ext, ext_action)
    end
    return self:_fail(conn, 404, "Not Found")
end

-- ── body（上传流式落盘 / 文本攒内存）────────────────────

--- 文本 body 入口（远程输入/剪贴板/远程配置共用）：校验 Content-Length，
--- 切 body 状态攒内存（不落盘），收齐后由 _readBody 调 finish(server, conn, text)
--- 自行排响应；空 body 当场以 "" 调 finish。长度不合法时直接排 411/400/413。
---@param conn table
---@param headers table 已小写化的请求头
---@param limit number body 上限（字节）
---@param finish fun(self: table, conn: table, text: string)
function Server:_acceptText(conn, headers, limit, finish)
    local len, len_err = self:_contentLength(headers)
    if len_err == "missing" then
        return self:_fail(conn, 411, "Content-Length required")
    end
    if not len then
        return self:_fail(conn, 400, "Invalid Content-Length")
    end
    if len > limit then
        return self:_fail(conn, 413, "Body too large")
    end
    if len == 0 then
        return finish(self, conn, "")
    end
    conn.finish = finish
    conn.text_buf = {}
    conn.remaining = len
    conn.state = "body"
end

--- 文件 body 入口（上传、更新包共用）：校验长度后开临时文件，切 body 状态流式落盘；
--- 收齐后临时文件所有权移交 commit，commit 落位完调 reply(resp) 排响应。
--- 带 Expect: 100-continue 先回 interim。chunked 501，缺长度 411，非法 400，超 limit 413，开文件失败 500。
---@param conn table
---@param headers table 已小写化的请求头
---@param limit number body 上限（字节）
---@param commit fun(temp: string, reply: fun(resp: table))
---@return true|nil true=已进 body 状态；nil=已排错误响应
function Server:_acceptFile(conn, headers, limit, commit)
    if headers["transfer-encoding"] then
        return self:_fail(conn, 501, "Chunked not supported")
    end
    local len, len_err = self:_contentLength(headers)
    if len_err == "missing" or len == 0 then
        return self:_fail(conn, 411, "Content-Length required")
    end
    if not len then
        return self:_fail(conn, 400, "Invalid Content-Length")
    end
    if len > limit then
        return self:_fail(conn, 413, "Upload too large")
    end
    local temp = self.handlers.temp_path()
    local file, ferr = io.open(temp, "wb")
    if not file then
        return self:_fail(conn, 500, ferr)
    end
    conn.file = file
    conn.temp = temp
    conn.commit = commit
    conn.remaining = len
    local expect = headers["expect"]
    if type(expect) == "string" and expect:lower():find("100%-continue") then
        conn.out = "HTTP/1.1 100 Continue\r\n\r\n"
        conn.out_off = 1
        conn.state = "continue"
    else
        conn.state = "body"
    end
    return true
end

--- 完整发出 100 Continue 后再进入 body；与最终响应共用部分写语义。
---@param conn table
---@return boolean
function Server:_writeContinue(conn)
    if conn.out_off > #conn.out then
        conn.out = ""
        conn.out_off = 1
        conn.state = "body"
        return true
    end
    return self:_send(conn)
end

--- 收 body：文本通道攒内存，上传通道流式写盘。
--- 收满后文本通道调 conn.finish 自行收尾；文件通道关文件、把临时文件所有权移交
--- conn.commit 并转 pending 等回调。写盘失败当场回 500，避免落一个截断文件还回 ok。
---@param conn table
---@return boolean 本轮是否有进展
function Server:_readBody(conn)
    local got
    if #conn.buf > 0 then
        got = conn.buf
        conn.buf = ""
    else
        local data, err, partial = conn.sock:receive(math.min(conn.remaining, CHUNK))
        got = data or partial
        if err == "closed" and (not got or #got == 0) then
            self:_kill(conn)
            return false
        end
    end
    if not got or #got == 0 then
        return false
    end
    if #got > conn.remaining then
        got = got:sub(1, conn.remaining) -- 超收部分丢弃（Connection: close，无下一请求）
    end
    if conn.finish then
        conn.text_buf[#conn.text_buf + 1] = got
    else
        -- 磁盘满/IO 错误必须当场失败：继续走下去会 save 一个截断文件并回 {"ok":true}。
        -- 文件和临时文件留给回完响应后的 _kill 收拾。
        local ok, werr = conn.file:write(got)
        if not ok then
            self:_fail(conn, 500, tostring(werr or "write failed"))
            return true
        end
    end
    conn.remaining = conn.remaining - #got
    conn.touched = socket.gettime()
    if conn.remaining > 0 then
        return true
    end
    if conn.finish then
        -- 文本通道收尾：finish 由路由在 _acceptText 时挂上
        local finish = conn.finish
        conn.finish = nil
        local text = table.concat(conn.text_buf)
        conn.text_buf = nil
        finish(self, conn, text)
        return true
    end
    -- 缓冲写的磁盘满错误常在 close 刷盘时才报出来，不判就会把截断文件当成功。
    local closed, cerr = conn.file:close()
    conn.file = nil
    if not closed then
        self:_fail(conn, 500, tostring(cerr or "close failed"))
        return true
    end
    local temp, commit = conn.temp, conn.commit
    conn.temp, conn.commit = nil, nil -- 所有权移交 commit（kill 不许再删）
    conn.state = "pending"
    commit(temp, function(resp)
        if not conn.dead then
            conn.resp = resp
        end
    end)
    return true
end

--- 轮询异步落位结果：conn.resp 就绪才排响应，否则本轮无进展。
---@param conn table
---@return boolean
function Server:_checkPending(conn)
    if not conn.resp then
        return false
    end
    local resp = conn.resp
    conn.resp = nil
    self:_queueResponse(conn, resp)
    return true
end

-- ── respond ──────────────────────────────────────────

--- JSON 响应表；pending 回调直接赋给 conn.resp，同步路径交给 _queueResponse。
---@param code number
---@param body string 已编码的 JSON 串
---@return table
function Server.jsonResp(code, body)
    return { code = code, ctype = "application/json; charset=utf-8", body = body }
end

--- 错误响应表：一律 JSON {"error": msg}（页面据此显示真实原因）。
---@param code number HTTP 状态码（需在 STATUS 表内，否则原因短语为 Unknown）
---@param msg any 错误说明，tostring 后进 JSON
---@return table
function Server.errorResp(code, msg)
    return Server.jsonResp(code, JSON.encode({ error = tostring(msg) }))
end

--- GET /api/logs.zip：一键打包日志（插件日志 + KOReader crash.log + info.txt，已脱敏）。
---@param conn table
---@param method string
function Server:_routeLogs(conn, method)
    if method ~= "GET" then
        return self:_fail(conn, 405, "Method Not Allowed")
    end
    return self:_sendBuiltZip(conn, self.handlers.logs_zip, require("features.remote.logs").fileName())
end

--- 后台建临时 zip，以附件 name 流式发出，发完/断开时由 _kill 删除。
---@param conn table
---@param build fun(cb: fun(output: string|nil, err: any))|nil
---@param name string 下载文件名
function Server:_sendBuiltZip(conn, build, name)
    if not build then
        return self:_fail(conn, 404, "Not Found")
    end
    conn.state = "pending"
    build(function(output, err)
        if conn.dead then
            if output then os.remove(output) end
            return
        end
        if not output then
            logger.warn("book remote zip build failed", name, err)
            conn.resp = Server.errorResp(500, err or "archive failed")
            return
        end
        -- 发完（或断开）由 _kill 删：Kindle 的 /mnt/us 是 FUSE，打开后立即 unlink 再读会读到 0 字节
        local file = io.open(output, "rb")
        if not file then
            os.remove(output)
            conn.resp = Server.errorResp(500, "Archive gone")
            return
        end
        local size = file:seek("end") or 0
        if size == 0 then
            file:close()
            os.remove(output)
            conn.resp = Server.errorResp(500, "empty archive")
            return
        end
        file:seek("set", 0)
        conn.temp = output
        conn.resp = {
            code = 200,
            ctype = "application/zip",
            extra = {
                "Content-Disposition: attachment; filename*=UTF-8''" .. Text.urlEncode(name),
                "Cache-Control: no-store",
            },
            file = file,
            size = size,
        }
    end)
    return true
end

--- GET /api/i18n：网页文案跟随 KOReader 语言。插件 l10n 目录 + features/remote/l10n/web（源文即简体中文），
--- 下发 {lang, html, strings}；同一语言只编码一次（语言切换后 KOReader 会重启）。
---@param conn table
---@param method string
function Server:_routeI18n(conn, method)
    if method ~= "GET" then
        return self:_fail(conn, 405, "Method Not Allowed")
    end
    local name, catalog = require("l10n").catalog()
    local cache = self._i18n_cache
    if not cache or cache.name ~= name then
        local html = name == "zh_CN" and "zh-CN" or name:gsub("_", "-")
        local strings = {}
        local function merge(t)
            for k, v in pairs(t) do
                if type(k) == "string" and type(v) == "string" and v ~= "" then
                    strings[k] = v
                end
            end
        end
        merge(catalog)
        -- 网页专属文案（features/remote/l10n/web/{lang}.lua）覆盖同名插件文案
        if name ~= "zh_CN" then
            local ok_web, web = pcall(require, "features.remote.l10n.web." .. name)
            if ok_web and type(web) == "table" then merge(web) end
            for _idx, web_ext in ipairs(ExtRoute.l10n(name)) do merge(web_ext) end
        end
        -- 简体中文 strings 为空（可能编码成 []），前端按「无译文」处理
        local body = JSON.encode({ lang = name, html = html, strings = strings })
        cache = { name = name, body = body }
        self._i18n_cache = cache
    end
    return self:_json(conn, 200, cache.body)
end

---@param body string 已编码的 JSON 串
function Server:_json(conn, code, body)
    return self:_queueResponse(conn, Server.jsonResp(code, body))
end

---@param conn table
---@param code number
---@param msg any
function Server:_fail(conn, code, msg)
    return self:_queueResponse(conn, Server.errorResp(code, msg))
end

--- 拼响应头并转 respond 状态；带 file 时只发头，body 由 _write 分块读发。
---@param conn table
---@param resp { code: number, ctype: string|nil, body: string|nil, extra: string[]|nil, file: any|nil, size: number|nil, on_sent: fun()|nil }
function Server:_queueResponse(conn, resp)
    local lines = {
        string.format("HTTP/1.1 %d %s\r\n", resp.code, STATUS[resp.code] or "Unknown"),
    }
    if resp.ctype then
        lines[#lines + 1] = "Content-Type: " .. resp.ctype .. "\r\n"
    end
    if resp.extra then
        for _idx, h in ipairs(resp.extra) do
            lines[#lines + 1] = h .. "\r\n"
        end
    end
    if resp.file then
        lines[#lines + 1] = string.format("Content-Length: %d\r\n", resp.size or 0)
        conn.body_file = resp.file
        conn.on_sent = resp.on_sent
    else
        lines[#lines + 1] = string.format("Content-Length: %d\r\n", #(resp.body or ""))
    end
    lines[#lines + 1] = "Connection: close\r\n\r\n"
    conn.out = table.concat(lines) .. (resp.file and "" or (resp.body or ""))
    conn.out_off = 1
    conn.state = "respond"
end

--- 非阻塞外发当前缓冲；发完后若有 body_file 就续读下一块，否则关连接（Connection: close）。
---@param conn table
---@return boolean 本轮是否有进展
function Server:_write(conn)
    if conn.out_off > #conn.out then
        if conn.body_file then
            local chunk = conn.body_file:read(CHUNK)
            if chunk and #chunk > 0 then
                conn.out = chunk
                conn.out_off = 1
            else
                conn.body_file:close()
                conn.body_file = nil
                local on_sent = conn.on_sent
                self:_kill(conn) -- 发完：Connection: close
                if on_sent then on_sent() end
                return true
            end
        else
            self:_kill(conn)
            return true
        end
    end
    return self:_send(conn)
end

--- 非阻塞发出 conn.out 的剩余部分（部分写续传）；对端关闭即 kill。
--- 发送缓冲区满时 send 回 last = out_off - 1：一个字节没发出去不算进展，
--- 否则 waitEvent 会空转到时间片用完，还会刷新 touched 让卡死的连接永不回收。
---@param conn table
---@return boolean 本轮是否有进展
function Server:_send(conn)
    local sent, err, last = conn.sock:send(conn.out, conn.out_off)
    local upto = sent or last
    if upto >= conn.out_off then
        conn.out_off = upto + 1
        conn.touched = socket.gettime()
        return true
    end
    if err == "closed" then
        self:_kill(conn)
    end
    return false
end

return Server
