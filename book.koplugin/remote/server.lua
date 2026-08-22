--[[--
远程管理 HTTP 服务核心：LuaSocket TCP + 增量状态机。

挂接：start 后由 UIManager:insertZMQ(server) 驱动 waitEvent
（UIManager 把它当迭代器反复调用，返回 nil = 本轮无更多工作；
空闲时至迟 50ms 再来一轮，见 UIManager ZMQ_TIMEOUT）。

- 上传 = raw body（PUT/POST /upload?dir=…&name=…），不做 multipart：
  网页用 fetch 直传文件体，curl -T 同理；
- 收发全零超时非阻塞，单次 waitEvent 自限时间片（默认 25ms），传大文件不冻 UI；
- 文件系统 IO 全经 handlers 注入，本模块只管 HTTP 协议。

@module koplugin.book.remote.server
--]]

local socket = require("socket")
local logger = require("logger")
local JSON = require("json")
local Text = require("utils.text")

local HEADER_LIMIT = 16 * 1024
local CHUNK = 32 * 1024
--- 无字节进展的连接存活上限（秒）；pending 状态（写入中）豁免
local IDLE_TIMEOUT = 120

local STATUS = {
    [200] = "OK",
    [400] = "Bad Request",
    [403] = "Forbidden",
    [404] = "Not Found",
    [405] = "Method Not Allowed",
    [409] = "Conflict",
    [411] = "Length Required",
    [413] = "Payload Too Large",
    [431] = "Request Header Fields Too Large",
    [500] = "Internal Server Error",
    [501] = "Not Implemented",
}

---@class RemoteHandlers
---@field list_dir fun(path: string): table[]|nil, any 目录项 { name, dir, size, mtime }；非目录返回 nil, err
---@field resolve_download fun(path: string): string|nil 存在且是普通文件才返回路径
---@field save fun(temp: string, dir: string, name: string, cb: fun(ok: boolean|nil, err: any)) 上传落位（可异步）
---@field mkdir fun(path: string): boolean|nil, any
---@field delete fun(path: string): boolean|nil, any
---@field rename fun(path: string, to: string): boolean|nil, any
---@field temp_path fun(name: string): string 上传临时落盘路径
---@field is_protected fun(path: string): boolean 重要路径及其祖先不可删除/移动
---@field get_input fun(): { active: boolean, text: string|nil } 设备激活输入框状态与当前文本
---@field set_input fun(text: string): boolean|nil, any 光标处追加注入（addChars 路径）；无激活框返回 nil, err
---@field get_clipboard fun(): { text: string } 设备共享剪贴板（最后复制的文本）
---@field set_clipboard fun(text: string) 写入设备剪贴板并同步进激活输入框

--- 一切非 2xx 响应都是 JSON {"error": msg}：页面能把真实原因显示出来，
--- 而不是 r.json() 解析纯文本炸出 SyntaxError 掩盖问题。

local Server = {}
Server.__index = Server

-- 路由实现拆分：文件管理 → remote.file，远程输入 → remote.input
-- （函数首参即 self；不反向 require server，无循环）
local File = require("remote.file")
local Input = require("remote.input")
Server._routeList = File.list
Server._routeDownload = File.download
Server._routeUpload = File.upload
Server._routeMutate = File.mutate
Server._routeRename = File.rename
Server._routeInput = Input.route
Server._routeClipboard = Input.clipboard

---@param o { host: string|nil, port: number, handlers: RemoteHandlers, root: string, roots: string[]|nil, home: string|nil, shortcuts: table[]|nil, slice: number|nil }
---@return table
function Server.new(o)
    o = o or {}
    assert(type(o.handlers) == "table", "remote.server: handlers required")
    assert(type(o.root) == "string", "remote.server: root required")
    return setmetatable({
        host = o.host or "*",
        port = o.port,
        handlers = o.handlers,
        root = o.root,
        roots = o.roots or { o.root },
        home = o.home or o.root, -- 页面默认路径
        shortcuts = o.shortcuts or {},
        slice = tonumber(o.slice) or 0.025,
        _conns = {},
    }, Server)
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
    logger.info("book remote listening on", self.host, self.port)
    return true
end

function Server:stop()
    for _, conn in ipairs(self._conns) do
        self:_kill(conn)
    end
    self._conns = {}
    if self._sock then
        self._sock:close()
        self._sock = nil
    end
end

--- UIManager 轮询入口：一小片工作，nil=本轮结束。
---@return nil
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
    return nil
end

-- ── 连接生命周期 ─────────────────────────────────────

function Server:_kill(conn)
    conn.dead = true
    pcall(function() conn.sock:close() end)
    if conn.file then
        pcall(function() conn.file:close() end)
        conn.file = nil
    end
    if conn.temp then
        pcall(os.remove, conn.temp)
        conn.temp = nil
    end
end

function Server:_accept()
    while true do
        local client = self._sock:accept()
        if not client then
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

function Server:_reapIdle()
    local now = socket.gettime()
    for i = #self._conns, 1, -1 do
        local conn = self._conns[i]
        if not conn.dead and conn.state ~= "pending" and now - conn.touched > IDLE_TIMEOUT then
            logger.warn("book remote idle timeout, closing conn")
            self:_kill(conn)
            table.remove(self._conns, i)
        end
    end
end

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
    elseif conn.state == "respond" then
        return self:_write(conn)
    end
    return false
end

-- ── headers ──────────────────────────────────────────

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
---@param p any
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

-- 路由模块（remote.file）以 self.cleanPath 使用
Server.cleanPath = cleanPath

local function contains(root, path)
    if root == "/" then
        return path:sub(1, 1) == "/"
    end
    return path == root or path:sub(1, #root + 1) == root .. "/"
end

---@param p any
---@return string|nil
function Server:_safePath(p)
    local path = cleanPath(p)
    if not path then
        return nil
    end
    for _, root in ipairs(self.roots) do
        if contains(root, path) then
            return path
        end
    end
    return nil
end

function Server:_parent(path)
    for _, root in ipairs(self.roots) do
        if path == root then
            return nil
        end
    end
    local parent = path:match("^(.*)/[^/]+$")
    if parent == "" then
        parent = "/"
    end
    return self:_safePath(parent)
end

function Server:_isRoot(path)
    for _, root in ipairs(self.roots) do
        if path == root then
            return true
        end
    end
    return false
end

--- 解析请求行 + headers 并分发路由；失败直接排响应。
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
    local query = parseQuery(qs)

    -- 静态页面/资源（GET）：index/file/input 三页 + css/js
    local body, ctype = Server.asset(path)
    if body then
        if method ~= "GET" then
            return self:_fail(conn, 405, "Method Not Allowed")
        end
        return self:_queueResponse(conn, { code = 200, ctype = ctype, body = body })
    end

    if path == "/api/config" then
        if method ~= "GET" then
            return self:_fail(conn, 405, "Method Not Allowed")
        end
        return self:_queueResponse(conn, {
            code = 200,
            ctype = "application/json; charset=utf-8",
            body = JSON.encode({
                root = self.root,
                home = self.home,
                shortcuts = self.shortcuts,
            }),
        })
    elseif path == "/api/list" then
        return self:_routeList(conn, method, query.path)
    elseif path == "/download" then
        return self:_routeDownload(conn, method, query.path)
    elseif path == "/upload" then
        return self:_routeUpload(conn, method, headers, query.dir, query.name)
    elseif path == "/api/mkdir" then
        return self:_routeMutate(conn, method, query.path, self.handlers.mkdir)
    elseif path == "/api/delete" then
        return self:_routeMutate(conn, method, query.path, self.handlers.delete)
    elseif path == "/api/input" then
        return self:_routeInput(conn, method, headers, query)
    elseif path == "/api/clipboard" then
        return self:_routeClipboard(conn, method, headers, query)
    elseif path == "/api/rename" then
        return self:_routeRename(conn, method, query)
    end
    return self:_fail(conn, 404, "Not Found")
end

-- ── body（上传流式落盘）───────────────────────────────

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
    if conn.text_mode then
        conn.text_buf[#conn.text_buf + 1] = got
    else
        conn.file:write(got)
    end
    conn.remaining = conn.remaining - #got
    conn.touched = socket.gettime()
    if conn.remaining > 0 then
        return true
    end
    if conn.text_mode then
        -- 文本通道收尾：text_mode 是路由标记（"append" 输入框 / "clipboard" 剪贴板）。
        -- 注入同步完成直接回；无激活输入框 → 409（剪贴板写入不受输入框影响）。
        local text = table.concat(conn.text_buf)
        local mode = conn.text_mode
        conn.text_buf = nil
        conn.text_mode = nil
        if mode == "clipboard" then
            self.handlers.set_clipboard(text)
            return self:_queueResponse(conn, {
                code = 200, ctype = "application/json; charset=utf-8", body = '{"ok":true}',
            })
        end
        local ok, err = self.handlers.set_input(text)
        if not ok then
            return self:_fail(conn, 409, err)
        end
        return self:_queueResponse(conn, {
            code = 200, ctype = "application/json; charset=utf-8", body = '{"ok":true}',
        })
    end
    conn.file:close()
    conn.file = nil
    local temp, dir, name = conn.temp, conn.dir, conn.name
    conn.temp = nil -- 所有权移交 save（kill 不许再删）
    conn.state = "pending"
    self.handlers.save(temp, dir, name, function(ok, err)
        if conn.dead then
            return
        end
        conn.resp = ok
            and { code = 200, ctype = "application/json; charset=utf-8", body = '{"ok":true}' }
            or {
                code = 500,
                ctype = "application/json; charset=utf-8",
                body = JSON.encode({ error = "Save failed: " .. tostring(err) }),
            }
    end)
    return true
end

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

--- 错误响应：一律 JSON {"error": msg}（页面据此显示真实原因）。
function Server:_fail(conn, code, msg)
    return self:_queueResponse(conn, {
        code = code,
        ctype = "application/json; charset=utf-8",
        body = JSON.encode({ error = tostring(msg) }),
    })
end

---@param resp { code: number, ctype: string|nil, body: string|nil, extra: string[]|nil, file: any|nil, size: number|nil }
function Server:_queueResponse(conn, resp)
    local lines = {
        string.format("HTTP/1.1 %d %s\r\n", resp.code, STATUS[resp.code] or "Unknown"),
    }
    if resp.ctype then
        lines[#lines + 1] = "Content-Type: " .. resp.ctype .. "\r\n"
    end
    if resp.extra then
        for _, h in ipairs(resp.extra) do
            lines[#lines + 1] = h .. "\r\n"
        end
    end
    if resp.file then
        lines[#lines + 1] = string.format("Content-Length: %d\r\n", resp.size or 0)
        conn.body_file = resp.file
    else
        lines[#lines + 1] = string.format("Content-Length: %d\r\n", #(resp.body or ""))
    end
    lines[#lines + 1] = "Connection: close\r\n\r\n"
    conn.out = table.concat(lines) .. (resp.file and "" or (resp.body or ""))
    conn.out_off = 1
    conn.state = "respond"
end

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
                self:_kill(conn) -- 发完：Connection: close
                return true
            end
        else
            self:_kill(conn)
            return true
        end
    end
    local sent, err, last = conn.sock:send(conn.out, conn.out_off)
    local upto = sent or last
    if upto then
        conn.out_off = upto + 1
        conn.touched = socket.gettime()
        return true
    end
    if err == "closed" then
        self:_kill(conn)
    end
    return false
end

-- ── 页面与静态资源 ─────────────────────────────────────

-- 一切页面资源都是静态路由（不注入模板）：html 经 /、/file.html、/input.html，
-- 样式脚本经 /style.css、/js.js、/file.js、/input.js；实例配置走 /api/config。
local HTML_DIR = (debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or ".") .. "/html"

local ASSETS = {
    ["/"] = { "index.html", "text/html; charset=utf-8" },
    ["/index.html"] = { "index.html", "text/html; charset=utf-8" },
    ["/file.html"] = { "file.html", "text/html; charset=utf-8" },
    ["/input.html"] = { "input.html", "text/html; charset=utf-8" },
    ["/style.css"] = { "style.css", "text/css; charset=utf-8" },
    ["/js.js"] = { "js.js", "application/javascript; charset=utf-8" },
    ["/file.js"] = { "file.js", "application/javascript; charset=utf-8" },
    ["/input.js"] = { "input.js", "application/javascript; charset=utf-8" },
}

local _asset_cache = {} ---@type table<string, string>

--- 读静态资源（lazy 缓存，随插件安装不变）。
---@param name string
---@return string
local function readAsset(name)
    local s = _asset_cache[name]
    if not s then
        local f = assert(io.open(HTML_DIR .. "/" .. name, "rb"), "remote.server: html/" .. name .. " unreadable")
        s = f:read("*all")
        f:close()
        _asset_cache[name] = s
    end
    return s
end

---@param path string 路由路径
---@return string|nil name, string|nil ctype
function Server.asset(path)
    local a = ASSETS[path]
    if not a then
        return nil
    end
    local ok, body = pcall(readAsset, a[1])
    if not ok then
        return nil
    end
    return body, a[2]
end

return Server
