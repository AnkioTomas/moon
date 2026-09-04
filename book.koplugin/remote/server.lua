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
local logger = require("utils.log")
local JSON = require("json")
local Text = require("utils.text")

local HEADER_LIMIT = 16 * 1024
local CHUNK = 32 * 1024
--- 无字节进展的连接存活上限（秒）；pending 状态（写入中）用 PENDING_TIMEOUT
local IDLE_TIMEOUT = 120
--- pending（等 handlers.save 回调）的存活上限（秒）。回调丢了就永远不回收，
--- 连接与临时文件一起挂着，因此豁免必须有尽头。大文件落位可能很慢，给足余量。
local PENDING_TIMEOUT = 30 * 60
--- 同时在途连接上限。到顶后直接拒绝新连接：设备内存与 fd 都很紧，
--- 没有上限时一个 for 循环的 curl 就能把 KOReader 拖死。
local MAX_CONNS = 32

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
---@field list_dir fun(path: string, cb: fun(entries: table[]|nil, err: any)) 异步目录列表
---@field is_dir fun(path: string): boolean 路径是否为目录（上传前单次校验）
---@field resolve_download fun(path: string): string|nil 存在且是普通文件才返回路径
---@field path_exists fun(path: string): boolean 路径是否已存在（上传重名预检）
---@field save fun(temp: string, dir: string, name: string, cb: fun(ok: boolean|nil, err: any), conflict: "overwrite"|"skip"|"rename"|nil) 上传落位（可异步）
---@field mkdir fun(path: string, cb: fun(ok: boolean|nil, err: any))
---@field delete fun(path: string, cb: fun(ok: boolean|nil, err: any))
---@field rename fun(path: string, to: string, cb: fun(ok: boolean|nil, err: any))
---@field extract fun(path: string, cb: fun(ok: boolean|nil, err: any, output: string|nil))
---@field temp_path fun(name: string): string 上传临时落盘路径
---@field is_protected fun(path: string): boolean 重要路径及其祖先不可删除/移动（展示级判定，可免 realpath；变更 handler 内部仍全量校验）
---@field get_input fun(): { active: boolean, text: string|nil } 设备激活输入框状态与当前文本
---@field set_input fun(text: string): boolean|nil, any 光标处追加注入（addChars 路径）；无激活框返回 nil, err
---@field get_clipboard fun(): { text: string } 设备共享剪贴板（最后复制的文本）
---@field set_clipboard fun(text: string) 写入设备剪贴板并同步进激活输入框

--- 一切非 2xx 响应都是 JSON {"error": msg}：页面能把真实原因显示出来，
--- 而不是 r.json() 解析纯文本炸出 SyntaxError 掩盖问题。

local Server = {}
Server.__index = Server

-- 路由实现拆分：文件、远程输入、共享剪贴板、远程配置各自独立。
-- （函数首参即 self；不反向 require server，无循环）
local File = require("remote.file")
local Input = require("remote.input")
local Clipboard = require("remote.clipboard")
local SettingsRoute = require("remote.settings_route")
Server._routeList = File.list
Server._routeDownload = File.download
Server._routeUpload = File.upload
Server._routeMutate = File.mutate
Server._routeRename = File.rename
Server._routeExtract = File.extract
Server._routeInput = Input.route
Server._routeClipboard = Clipboard.route
Server._routeSettings = SettingsRoute.settings

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
    logger.info("book remote listening on", self.host, self.port)
    return true
end

--- 关停：断开全部在途连接并关闭监听 socket；可重复调用。
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

--- 标记连接死亡并释放其占用：socket、正在写的文件、未移交的上传临时文件。
--- 关闭动作全部 pcall：kill 常在异常路径调用，二次错误会盖掉真实原因。
---@param conn table
function Server:_kill(conn)
    conn.dead = true
    pcall(function() conn.sock:close() end)
    if conn.file then
        pcall(function() conn.file:close() end)
        conn.file = nil
    end
    -- 下载中途断开（浏览器点取消、超时回收）时 body_file 还开着：
    -- 不关就是每次一个 fd，几十次下载后 accept 直接 EMFILE。
    if conn.body_file then
        pcall(function() conn.body_file:close() end)
        conn.body_file = nil
    end
    if conn.temp then
        pcall(os.remove, conn.temp)
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
            pcall(function() client:close() end)
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

---@param p any
---@return string|nil
function Server:_safePath(p)
    local path = cleanPath(p)
    if not path then
        return nil
    end
    for _, root in ipairs(self.roots) do
        if Text.pathContains(root, path) then
            return path
        end
    end
    return nil
end

--- 取上级目录；path 本身是某个 managed root 或越界时返回 nil。
---@param path string
---@return string|nil
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

--- 路径是否正好是某个 managed root。
---@param path string
---@return boolean
function Server:_isRoot(path)
    for _, root in ipairs(self.roots) do
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
    local query = parseQuery(qs)

    -- 静态页面/资源（GET）：index/file/input 三页 + css/js
    local body, ctype = Server.asset(path)
    if body then
        if method ~= "GET" then
            return self:_fail(conn, 405, "Method Not Allowed")
        end
        return self:_queueResponse(conn, { code = 200, ctype = ctype, body = body })
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
        return self:_routeDownload(conn, method, query.path, query.inline)
    elseif path == "/upload" then
        return self:_routeUpload(conn, method, headers, query.dir, query.name, query.conflict)
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
    elseif path == "/api/extract" then
        return self:_routeExtract(conn, method, query.path)
    elseif path == "/api/settings" then
        return self:_routeSettings(conn, method, headers, query)
    end
    return self:_fail(conn, 404, "Not Found")
end

-- ── body（上传流式落盘 / 文本攒内存）────────────────────

--- 文本 body 入口（远程输入/剪贴板/远程配置共用）：校验 Content-Length，
--- 切 body 状态攒内存（不落盘），收尾函数挂 conn.finish——body 收齐后由
--- _readBody 回调（签名 fun(server, conn, text)，自含响应）。
---@param conn table
---@param headers table 已小写化的请求头
---@param limit number body 上限（字节）
---@param finish fun(self: table, conn: table, text: string)
---@return true|nil|false true=有 body 进状态机；false=空 body，调用方当场收尾；
---        nil=已排错误响应（411/413），调用方直接 return
function Server:_acceptText(conn, headers, limit, finish)
    local len, len_err = self:_contentLength(headers)
    if len_err == "missing" then
        self:_fail(conn, 411, "Content-Length required")
        return nil
    end
    if not len then
        self:_fail(conn, 400, "Invalid Content-Length")
        return nil
    end
    if len > limit then
        self:_fail(conn, 413, "Body too large")
        return nil
    end
    if len == 0 then
        return false
    end
    conn.finish = finish
    conn.text_buf = {}
    conn.remaining = len
    conn.state = "body"
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
    local sent, err, last = conn.sock:send(conn.out, conn.out_off)
    local upto = sent or last
    if upto then
        conn.out_off = upto + 1
        conn.touched = socket.gettime()
        return true
    end
    if err == "closed" then self:_kill(conn) end
    return false
end

--- 收 body：文本通道攒内存，上传通道流式写盘。
--- 收满后文本通道调 conn.finish 自行收尾；上传通道关文件、把临时文件所有权移交
--- handlers.save 并转 pending 等回调。写盘失败当场回 500，避免落一个截断文件还回 ok。
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
        -- 磁盘满/IO 错误必须当场失败：继续走下去会 save 一个截断文件并回 {"ok":true}
        local ok, werr = conn.file:write(got)
        if not ok then
            conn.file:close()
            conn.file = nil
            if conn.temp then
                pcall(os.remove, conn.temp)
                conn.temp = nil
            end
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
    conn.file:close()
    conn.file = nil
    local temp, dir, name, conflict = conn.temp, conn.dir, conn.name, conn.conflict
    conn.temp = nil -- 所有权移交 save（kill 不许再删）
    conn.state = "pending"
    self.handlers.save(temp, dir, name, function(ok, err)
        if ok then
            logger.dbg("book remote upload saved", dir, name, conflict)
        else
            logger.warn("book remote upload failed", dir, name, err)
        end
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
    end, conflict)
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

--- 错误响应：一律 JSON {"error": msg}（页面据此显示真实原因）。
---@param conn table
---@param code number HTTP 状态码（需在 STATUS 表内，否则原因短语为 Unknown）
---@param msg any 错误说明，tostring 后进 JSON
function Server:_fail(conn, code, msg)
    return self:_queueResponse(conn, {
        code = code,
        ctype = "application/json; charset=utf-8",
        body = JSON.encode({ error = tostring(msg) }),
    })
end

--- 拼响应头并转 respond 状态；带 file 时只发头，body 由 _write 分块读发。
---@param conn table
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

-- 一切页面资源都是静态路由（不注入模板）；实例配置走 /api/config。
local HTML_DIR = (debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or ".") .. "/html"

local ASSETS = {
    ["/"] = { "index.html", "text/html; charset=utf-8" },
    ["/index.html"] = { "index.html", "text/html; charset=utf-8" },
    ["/file.html"] = { "file.html", "text/html; charset=utf-8" },
    ["/input.html"] = { "input.html", "text/html; charset=utf-8" },
    ["/clipboard.html"] = { "clipboard.html", "text/html; charset=utf-8" },
    ["/settings.html"] = { "settings.html", "text/html; charset=utf-8" },
    ["/logo.jpg"] = { "logo.jpg", "image/jpeg" },
    ["/style.css"] = { "style.css", "text/css; charset=utf-8" },
    ["/js.js"] = { "js.js", "application/javascript; charset=utf-8" },
    ["/file.js"] = { "file.js", "application/javascript; charset=utf-8" },
    ["/input.js"] = { "input.js", "application/javascript; charset=utf-8" },
    ["/clipboard.js"] = { "clipboard.js", "application/javascript; charset=utf-8" },
    ["/settings.js"] = { "settings.js", "application/javascript; charset=utf-8" },
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
---@return string|nil body, string|nil ctype 非静态路由或读取失败时返回 nil
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
