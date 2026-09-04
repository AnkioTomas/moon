--[[--
remote.server（文件管理）离线测试：脚本化假 socket 驱动增量状态机。

假 socket 语义对齐 LuaSocket 零超时模式：
  receive(n) → 数据 / nil,"timeout" / nil,"closed",partial
  send(s, i) → 末字节下标 / nil,"timeout",last / nil,"closed"
时钟可拨（fake_now），slice=0 时一次 waitEvent 只过一轮（每连接最多动一块），
用来验证大 body 跨多次 waitEvent 推进。

@module tests.remote.server_spec
--]]

local Assert = require("support.assert")

--- 字符串包含（断言计数走 Assert.is_true）
---@param s string
---@param sub string
local function has(s, sub)
    Assert.is_true(
        type(s) == "string" and s:find(sub, 1, true) ~= nil,
        "expected to contain: " .. sub
    )
end

-- ── 假 socket 环境 ────────────────────────────────────

local fake_now = 1000.0
local bind_queue ---@type table[] 待 accept 的客户端
local bind_opts ---@type table|nil bind 失败注入

package.preload["socket"] = function()
    return {
        gettime = function()
            return fake_now
        end,
        bind = function(host, port)
            if bind_opts and bind_opts.err then
                return nil, bind_opts.err
            end
            bind_opts = { host = host, port = port, closed = false }
            function bind_opts:settimeout(_) end
            function bind_opts:accept()
                return table.remove(bind_queue, 1)
            end
            function bind_opts:close()
                self.closed = true
            end
            return bind_opts
        end,
    }
end

-- 覆盖全局 json 空壳：encode 需要真序列化（rows 只含 string/number/boolean/nil）
package.preload["json"] = function()
    local function encode(v)
        local t = type(v)
        if t == "string" then
            return string.format("%q", v)
        elseif t == "number" or t == "boolean" then
            return tostring(v)
        elseif t == "table" then
            local is_arr = #v > 0
            local parts = {}
            if is_arr then
                for i = 1, #v do
                    parts[#parts + 1] = encode(v[i])
                end
                return "[" .. table.concat(parts, ",") .. "]"
            end
            for k, val in pairs(v) do
                if val ~= nil then
                    parts[#parts + 1] = encode(tostring(k)) .. ":" .. encode(val)
                end
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
        error("json stub: unsupported " .. t)
    end
    return {
        encode = encode,
        decode = require("support.json_stub").decode,
    }
end

local TOKEN = "0123456789abcdef"

--- 除静态资源外所有路由都要 token：给请求行的 URI 补上 t=，
--- 免得每条用例都写一遍。opts.no_token 保留原样（用于认证本身的用例）。
---@param chunk string
---@return string
local function withToken(chunk)
    local method, uri, rest = chunk:match("^(%u+) (%S+) (HTTP/1%.1.*)$")
    if not method then
        return chunk
    end
    local sep = uri:find("?", 1, true) and "&" or "?"
    return method .. " " .. uri .. sep .. "t=" .. TOKEN .. " " .. rest
end

--- 新假客户端：chunks 为 receive 逐次吐出的字节片。
--- opts.send_limit：单次 send 最多发出的字节数（模拟 EAGAIN 部分写）。
--- opts.no_token：不给请求补 token。
---@param chunks string[]
---@param opts table|nil
---@return table
local function newClient(chunks, opts)
    opts = opts or {}
    if not opts.no_token then
        for i = 1, #chunks do
            chunks[i] = withToken(chunks[i])
        end
    end
    local c = {
        chunks = chunks,
        sent = {},
        closed = false,
        send_limit = opts.send_limit,
    }
    function c:settimeout(_) end
    function c:receive(n)
        local s = self.chunks[1]
        if not s then
            return nil, self.eof and "closed" or "timeout"
        end
        if n and #s > n then
            self.chunks[1] = s:sub(n + 1)
            return s:sub(1, n)
        end
        table.remove(self.chunks, 1)
        return s
    end
    function c:send(data, off)
        off = off or 1
        local avail = data:sub(off)
        if self.send_limit and #avail > self.send_limit then
            self.sent[#self.sent + 1] = avail:sub(1, self.send_limit)
            return nil, "timeout", off + self.send_limit - 1
        end
        self.sent[#self.sent + 1] = avail
        return #data
    end
    function c:close()
        self.closed = true
    end
    --- 已发出的全部字节
    function c:output()
        return table.concat(self.sent)
    end
    return c
end

-- ── 服务装配 ──────────────────────────────────────────

local Server = require("remote.server")

--- 假文件系统 handlers：dirs 是已知目录集合，calls 记录变更调用。
local function fakeHandlers(dirs)
    local calls = {}
    local handlers = {
        list_dir = function(path, cb)
            if not dirs[path] then
                cb(nil, "not a directory")
                return
            end
            cb(dirs[path])
        end,
        is_dir = function(path)
            return dirs[path] ~= nil
        end,
        resolve_download = function(path)
            return path == "/dl/ok.bin" and "/dl/ok.bin" or nil
        end,
        save = function(temp, dir, name, cb)
            local f = io.open(temp, "rb")
            calls.save = { dir = dir, name = name, content = f and f:read("*all") or nil }
            if f then
                f:close()
            end
            os.remove(temp)
            cb(true)
        end,
        mkdir = function(path, cb)
            calls.mkdir = path
            cb(true)
        end,
        delete = function(path, cb)
            calls.delete = path
            cb(true)
        end,
        rename = function(path, to, cb)
            calls.rename = { from = path, to = to }
            cb(true)
        end,
        extract = function(path, cb)
            calls.extract = path
            cb(true, nil, path:gsub("%.zip$", ""))
        end,
        is_protected = function()
            return false
        end,
        get_input = function()
            return { active = false }
        end,
        set_input = function(text)
            calls.input = text
            return true
        end,
        get_clipboard = function()
            return { text = calls.clipboard or "" }
        end,
        set_clipboard = function(text)
            calls.clipboard = text
        end,
        temp_path = function()
            return os.tmpname()
        end,
    }
    return handlers, calls
end

--- 建 server 并注入一个已完成 TCP 握手的客户端。
---@param client table
---@param handlers table|nil
---@param opts table|nil
---@return table server
local function serve(client, handlers, opts)
    bind_queue = { client }
    if not handlers then
        handlers = fakeHandlers({})
    end
    local server = Server.new({
        host = "127.0.0.1",
        port = 9528,
        token = TOKEN,
        handlers = handlers,
        root = opts and opts.root or "/",
        roots = opts and opts.roots,
        home = opts and opts.home,
        shortcuts = opts and opts.shortcuts,
        slice = opts and opts.slice,
    })
    local ok, err = server:start()
    Assert.is_true(ok, "start: " .. tostring(err))
    return server
end

--- 驱动到连接关闭（防护上限 200 轮）。
---@param server table
local function drain(server)
    for _ = 1, 200 do
        server:waitEvent()
        if #server._conns == 0 then
            return
        end
    end
    error("drain: connection never finished")
end

--- 从响应字节流拆状态码与正文。
---@param out string
---@return number code, string body, string head
local function parseResponse(out)
    local split = out:find("\r\n\r\n", 1, true)
    Assert.is_true(split ~= nil, "response missing header terminator")
    local head = out:sub(1, split - 1)
    local code = tonumber(head:match("^HTTP/%d%.%d (%d+)"))
    Assert.is_true(code ~= nil, "response missing status line: " .. head:sub(1, 60))
    return code, out:sub(split + 4), head
end

-- ── 静态页面/资源 + /api/config ───────────────────────

do
    -- 入口页：远程管理，链接两个功能页
    local client = newClient({ "GET / HTTP/1.1\r\nHost: x\r\n\r\n" })
    local server = serve(client, nil, {
        root = "/managed",
        home = "/managed/books",
        shortcuts = { { label = "书籍根目录", path = "/managed/books" } },
    })
    drain(server)
    local code, body, head = parseResponse(client:output())
    Assert.eq(code, 200)
    has(head, "text/html")
    has(body, "远程管理")
    has(body, "/file.html")
    has(body, "/input.html")
    has(body, "/clipboard.html")
    has(body, "/settings.html")
    has(body, "/logo.jpg")
    has(body, "Ankio")
    has(body, "https://ankio.net")
    Assert.is_true(client.closed, "Connection: close 后 socket 必须关闭")

    -- 静态资源：ctype 正确 + 内容命中；夜间模式媒体查询在 css 里
    local c_css = newClient({ "GET /style.css HTTP/1.1\r\n\r\n" })
    drain(serve(c_css))
    local _, b_css, h_css = parseResponse(c_css:output())
    has(h_css, "text/css")
    has(b_css, "--surface")
    has(b_css, "setting-row")
    has(b_css, "prefers-color-scheme: dark")

    local c_js = newClient({ "GET /js.js HTTP/1.1\r\n\r\n" })
    drain(serve(c_js))
    local _, b_js, h_js = parseResponse(c_js:output())
    has(h_js, "application/javascript")
    has(b_js, "jfetch")
    local c_file_js = newClient({ "GET /file.js HTTP/1.1\r\n\r\n" })
    drain(serve(c_file_js))
    local _, b_file_js = parseResponse(c_file_js:output())
    has(b_file_js, "Array.isArray(d.entries)")
    has(b_file_js, "webkitRelativePath")
    has(b_file_js, "webkitGetAsEntry")
    has(b_file_js, "dragenter")
    has(b_file_js, "/api/extract?path=")
    has(b_file_js, "日志不可用")

    local c_logo = newClient({ "GET /logo.jpg HTTP/1.1\r\n\r\n" })
    drain(serve(c_logo))
    local _, b_logo, h_logo = parseResponse(c_logo:output())
    has(h_logo, "image/jpeg")
    Assert.is_true(#b_logo > 100)

    local c_f = newClient({ "GET /file.html HTTP/1.1\r\n\r\n" })
    drain(serve(c_f))
    local _, b_f = parseResponse(c_f:output())
    has(b_f, "文件管理")
    has(b_f, "/logo.jpg")
    has(b_f, "ankio.net")
    Assert.is_nil(b_f:find("第 2 级目录为分类", 1, true))
    has(b_f, "file-main")
    has(b_f, "explorer-shell")
    has(b_f, "explorer-sidebar")
    has(b_f, 'id="parent"')
    has(b_f, 'id="pickfile"')
    has(b_f, 'id="pickfolder"')
    has(b_f, 'id="dropzone"')
    has(b_f, 'id="count"')
    has(b_f, 'id="folder"')
    has(b_f, "webkitdirectory")
    has(b_f, "/js.js")

    local c_i = newClient({ "GET /input.html HTTP/1.1\r\n\r\n" })
    drain(serve(c_i))
    local _, b_i = parseResponse(c_i:output())
    has(b_i, "远程输入")
    has(b_i, "/input.js")
    has(b_i, "ankio.net")
    Assert.is_nil(b_i:find("共享剪贴板", 1, true))

    local c_cb = newClient({ "GET /clipboard.html HTTP/1.1\r\n\r\n" })
    drain(serve(c_cb))
    local _, b_cb = parseResponse(c_cb:output())
    has(b_cb, "共享剪贴板")
    has(b_cb, "/clipboard.js")
    has(b_cb, "ankio.net")

    local c_cb_js = newClient({ "GET /clipboard.js HTTP/1.1\r\n\r\n" })
    drain(serve(c_cb_js))
    local _, b_cb_js, h_cb_js = parseResponse(c_cb_js:output())
    has(h_cb_js, "application/javascript")
    has(b_cb_js, "/api/clipboard")

    local c_s = newClient({ "GET /settings.html HTTP/1.1\r\n\r\n" })
    drain(serve(c_s))
    local _, b_s = parseResponse(c_s:output())
    has(b_s, "连接配置")
    has(b_s, "/settings.js")
    has(b_s, "ankio.net")

    -- 静态路由非 GET → 405；未知路径 → 404
    local c_p = newClient({ "POST /style.css HTTP/1.1\r\nContent-Length: 0\r\n\r\n" })
    drain(serve(c_p))
    Assert.eq((parseResponse(c_p:output())), 405)

    -- /api/config：实例配置免注入下发
    local c_cfg = newClient({ "GET /api/config HTTP/1.1\r\n\r\n" })
    drain(serve(c_cfg, nil, {
        root = "/managed",
        home = "/managed/books",
        shortcuts = {
            { label = "书籍根目录", path = "/managed/books" },
            {
                label = "KOReader 崩溃日志", path = "/managed/crash.log",
                kind = "file", missing = "尚未生成 KOReader 崩溃日志。",
            },
        },
    }))
    local _, b_cfg = parseResponse(c_cfg:output())
    local cfg = require("support.json_stub").decode(b_cfg)
    Assert.eq(cfg.root, "/managed")
    Assert.eq(cfg.home, "/managed/books")
    Assert.eq(cfg.shortcuts[1].label, "书籍根目录")
    Assert.eq(cfg.shortcuts[2].kind, "file")
    Assert.eq(cfg.shortcuts[2].missing, "尚未生成 KOReader 崩溃日志。")

    local dynamic = Server.new({ root = "/old", handlers = fakeHandlers({}) })
    dynamic:updateLayout({
        root = "/new",
        roots = { "/new", "/shots" },
        home = "/new/books",
        shortcuts = { { label = "截图", path = "/shots" } },
    })
    Assert.eq(dynamic.root, "/new")
    Assert.eq(dynamic.roots[2], "/shots")
    Assert.eq(dynamic.home, "/new/books")
    Assert.eq(dynamic.shortcuts[1].path, "/shots")
end

-- ── 来源校验 / DNS rebinding ───────────────────────────

do
    -- 静态资源免票（都是常量，且页面要先加载才能拿到 token 转发）
    local c_asset = newClient({ "GET /style.css HTTP/1.1\r\n\r\n" }, { no_token = true })
    drain(serve(c_asset))
    Assert.eq((parseResponse(c_asset:output())), 200)

    -- 无 token 也可访问，远程管理不再使用令牌
    local handlers, calls = fakeHandlers({ ["/"] = {} })
    local c_none = newClient({ "GET /api/list?path=/ HTTP/1.1\r\n\r\n" }, { no_token = true })
    drain(serve(c_none, handlers))
    Assert.eq((parseResponse(c_none:output())), 200)

    local c_bad = newClient({ "GET /api/list?path=/&t=nope HTTP/1.1\r\n\r\n" }, { no_token = true })
    drain(serve(c_bad, handlers))
    Assert.eq((parseResponse(c_bad:output())), 200)

    local c_del = newClient(
        { "POST /api/delete?path=/a HTTP/1.1\r\nContent-Length: 0\r\n\r\n" }, { no_token = true })
    drain(serve(c_del, handlers))
    Assert.eq((parseResponse(c_del:output())), 200)
    Assert.eq(calls.delete, "/a")

    -- 跨站写：Origin 与 Host 不一致 → 403（恶意页面 fetch 删文件）
    local c_cross = newClient({
        "POST /api/delete?path=/a HTTP/1.1\r\nHost: 192.168.1.5:9528\r\n" ..
        "Origin: http://evil.example\r\nContent-Length: 0\r\n\r\n",
    })
    drain(serve(c_cross, handlers))
    Assert.eq((parseResponse(c_cross:output())), 403)
    Assert.eq(calls.delete, "/a", "跨站请求被拒绝且不应再次调用 handler")

    -- 同源写放过
    local c_same = newClient({
        "POST /api/mkdir?path=/a/b HTTP/1.1\r\nHost: 192.168.1.5:9528\r\n" ..
        "Origin: http://192.168.1.5:9528\r\nContent-Length: 0\r\n\r\n",
    })
    drain(serve(c_same, handlers))
    Assert.eq((parseResponse(c_same:output())), 200)

    -- DNS rebinding：Host 是域名 → 403
    local c_rebind = newClient({ "GET /api/list?path=/ HTTP/1.1\r\nHost: evil.example\r\n\r\n" })
    drain(serve(c_rebind, handlers))
    Assert.eq((parseResponse(c_rebind:output())), 403)

    -- Origin: null（沙箱 iframe、data:/file: 页面）→ 403。曾经被当作「非浏览器」放过。
    local c_null = newClient({
        "POST /api/delete?path=/a HTTP/1.1\r\nHost: 192.168.1.5:9528\r\n" ..
        "Origin: null\r\nContent-Length: 0\r\n\r\n",
    })
    drain(serve(c_null, handlers))
    Assert.eq((parseResponse(c_null:output())), 403)
    Assert.eq(calls.delete, "/a", "Origin null 被拒绝且不应再次调用 handler")
end

-- ── GET /api/list ─────────────────────────────────────

do
    local handlers = fakeHandlers({
        ["/"] = {
            { name = "dl", dir = true, mtime = 1700000000 },
            { name = "a.txt", dir = false, size = 42, mtime = 1700000001 },
        },
    })
    local client = newClient({ "GET /api/list?path=/ HTTP/1.1\r\n\r\n" })
    drain(serve(client, handlers))
    local code, body, head = parseResponse(client:output())
    Assert.eq(code, 200)
    has(head, "application/json")
    local d = require("support.json_stub").decode(body)
    Assert.eq(d.path, "/")
    Assert.eq(d.parent, nil, "根目录无 parent")
    Assert.eq(d.entries[1].name, "dl")
    Assert.is_true(d.entries[1].dir)
    Assert.eq(d.entries[2].size, 42)

    -- 子目录有 parent
    local h2 = fakeHandlers({ ["/dl"] = {} })
    local c2 = newClient({ "GET /api/list?path=/dl HTTP/1.1\r\n\r\n" })
    drain(serve(c2, h2))
    local d2 = require("support.json_stub").decode(select(2, parseResponse(c2:output())))
    Assert.eq(d2.parent, "/")

    -- 非目录 → 404；相对路径归一化为 /
    local c3 = newClient({ "GET /api/list?path=/nope HTTP/1.1\r\n\r\n" })
    drain(serve(c3, handlers))
    Assert.eq((parseResponse(c3:output())), 404)
end

-- ── 路径边界与保护 ────────────────────────────────────

do
    local handlers, calls = fakeHandlers({
        ["/managed"] = {
            { name = "koreader", dir = true },
        },
    })
    handlers.is_protected = function(path)
        return path == "/managed/koreader"
    end

    -- 管理根没有 parent，受保护项由后端标记给页面隐藏操作。
    local c1 = newClient({ "GET /api/list?path=/managed HTTP/1.1\r\n\r\n" })
    drain(serve(c1, handlers, { root = "/managed" }))
    local d1 = require("support.json_stub").decode(select(2, parseResponse(c1:output())))
    Assert.is_nil(d1.parent)
    Assert.is_true(d1.entries[1].protected)

    -- 直接越界和通过 .. 越界都拒绝。
    local c2 = newClient({ "GET /api/list?path=/etc HTTP/1.1\r\n\r\n" })
    drain(serve(c2, handlers, { root = "/managed" }))
    local code2, ebody2 = parseResponse(c2:output())
    Assert.eq(code2, 403)
    -- 错误体必须是 JSON {"error": ...}（页面靠它显示真实原因，不再是裸文本）
    Assert.eq(require("support.json_stub").decode(ebody2).error, "Path outside managed roots")
    local c3 = newClient({ "GET /api/list?path=/managed/../etc HTTP/1.1\r\n\r\n" })
    drain(serve(c3, handlers, { root = "/managed" }))
    Assert.eq((parseResponse(c3:output())), 403)

    -- 慢目录扫描允许异步完成，连接在回调前保持 pending。
    local delayed_cb
    local delayed_handlers = fakeHandlers({ ["/managed"] = {} })
    delayed_handlers.list_dir = function(_, cb) delayed_cb = cb end
    local delayed_client = newClient({ "GET /api/list?path=/managed HTTP/1.1\r\n\r\n" })
    local delayed_server = serve(delayed_client, delayed_handlers, { root = "/managed" })
    delayed_server:waitEvent()
    Assert.eq(delayed_server._conns[1].state, "pending")
    Assert.eq(delayed_client:output(), "")
    delayed_cb({})
    drain(delayed_server)
    local delayed_code, delayed_body = parseResponse(delayed_client:output())
    Assert.eq(delayed_code, 200)
    has(delayed_body, '"entries":[]')

    -- 页面隐藏按钮不是保护；伪造 API 请求也必须被后端拦下。
    local c4 = newClient({
        "POST /api/delete?path=/managed/koreader HTTP/1.1\r\nContent-Length: 0\r\n\r\n",
    })
    drain(serve(c4, handlers, { root = "/managed" }))
    Assert.eq((parseResponse(c4:output())), 403)
    Assert.is_nil(calls.delete)
    local c5 = newClient({
        "POST /api/rename?path=/managed/koreader&to=/managed/other HTTP/1.1\r\nContent-Length: 0\r\n\r\n",
    })
    drain(serve(c5, handlers, { root = "/managed" }))
    Assert.eq((parseResponse(c5:output())), 403)
    Assert.is_nil(calls.rename)
end

-- ── 上传：happy path（分片送达 + pending 异步回调）─────

do
    local handlers, calls = fakeHandlers({ ["/inbox"] = {} })
    local client = newClient({
        "PUT /upload?dir=/inbox&name=x.bin HTTP/1.1\r\nContent-Length: 6\r\n\r\nabc",
        "def",
    })
    drain(serve(client, handlers))
    Assert.eq(calls.save.dir, "/inbox")
    Assert.eq(calls.save.name, "x.bin")
    Assert.eq(calls.save.content, "abcdef", "body 分片必须完整落盘")
    local code, body = parseResponse(client:output())
    Assert.eq(code, 200)
    Assert.eq(body, '{"ok":true}')
end

-- ── 上传：错误分支 ────────────────────────────────────

do
    -- 目录不存在 → 400
    local c1 = newClient({ "PUT /upload?dir=/nope&name=x HTTP/1.1\r\nContent-Length: 1\r\n\r\nZ" })
    drain(serve(c1))
    Assert.eq((parseResponse(c1:output())), 400)

    -- 文件名为空 → 400
    local handlers = fakeHandlers({ ["/inbox"] = {} })
    local c2 = newClient({ "PUT /upload?dir=/inbox HTTP/1.1\r\nContent-Length: 1\r\n\r\nZ" })
    drain(serve(c2, handlers))
    Assert.eq((parseResponse(c2:output())), 400)

    -- 文件名消毒：路径分隔符变下划线
    local h3, calls3 = fakeHandlers({ ["/inbox"] = {} })
    local c3 = newClient({ "PUT /upload?dir=/inbox&name=../evil/a.bin HTTP/1.1\r\nContent-Length: 1\r\n\r\nZ" })
    drain(serve(c3, h3))
    Assert.eq(calls3.save.name, ".._evil_a.bin")

    -- 无 Content-Length → 411
    local c4 = newClient({ "PUT /upload?dir=/inbox&name=x HTTP/1.1\r\n\r\n" })
    drain(serve(c4, fakeHandlers({ ["/inbox"] = {} })))
    Assert.eq((parseResponse(c4:output())), 411)

    -- chunked → 501
    local c5 = newClient({
        "PUT /upload?dir=/inbox&name=x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
    })
    drain(serve(c5, fakeHandlers({ ["/inbox"] = {} })))
    Assert.eq((parseResponse(c5:output())), 501)

    -- Content-Length 必须是十进制整数，且上传体积有硬上限。
    local c5b = newClient({
        "PUT /upload?dir=/inbox&name=x HTTP/1.1\r\nContent-Length: 1.5\r\n\r\nZ",
    })
    drain(serve(c5b, fakeHandlers({ ["/inbox"] = {} })))
    Assert.eq((parseResponse(c5b:output())), 400)
    local c5c = newClient({
        "PUT /upload?dir=/inbox&name=x HTTP/1.1\r\nContent-Length: 2147483649\r\n\r\n",
    })
    drain(serve(c5c, fakeHandlers({ ["/inbox"] = {} })))
    Assert.eq((parseResponse(c5c:output())), 413)
    local c5d = newClient({
        "PUT /upload?dir=/inbox&name=x HTTP/1.1\r\n"
            .. "Transfer-Encoding: chunked\r\nContent-Length: 1\r\n\r\nZ",
    })
    drain(serve(c5d, fakeHandlers({ ["/inbox"] = {} })))
    Assert.eq((parseResponse(c5d:output())), 501)

    -- save 失败 → 500
    local h6 = fakeHandlers({ ["/inbox"] = {} })
    h6.save = function(temp, _, _, cb)
        os.remove(temp)
        cb(nil, "disk full")
    end
    local c6 = newClient({ "PUT /upload?dir=/inbox&name=x HTTP/1.1\r\nContent-Length: 1\r\n\r\nZ" })
    drain(serve(c6, h6))
    local code6, body6 = parseResponse(c6:output())
    Assert.eq(code6, 500)
    has(body6, "disk full")
end

-- Expect: 100-continue 也必须走部分写缓冲，不能靠一次 send 碰运气。
do
    local handlers, calls = fakeHandlers({ ["/inbox"] = {} })
    local client = newClient({
        "PUT /upload?dir=/inbox&name=x HTTP/1.1\r\n"
            .. "Content-Length: 1\r\nExpect: 100-continue\r\n\r\nZ",
    }, { send_limit = 7 })
    drain(serve(client, handlers))
    has(client:output(), "HTTP/1.1 100 Continue\r\n\r\n")
    has(client:output(), "HTTP/1.1 200 OK\r\n")
    Assert.eq(calls.save.content, "Z")
end

-- ── 下载 ──────────────────────────────────────────────

do
    -- 命中：bytes + 附件头（resolve 指向真实文件，借用临时文件做真实 io）
    local real = os.tmpname()
    local f = io.open(real, "wb")
    f:write("BYTES0123")
    f:close()
    local handlers = fakeHandlers({})
    handlers.resolve_download = function(p)
        return p == "/dl/ok.bin" and real or nil
    end
    local c1 = newClient({ "GET /download?path=/dl/ok.bin HTTP/1.1\r\n\r\n" })
    drain(serve(c1, handlers))
    local code, body, head = parseResponse(c1:output())
    Assert.eq(code, 200)
    Assert.eq(body, "BYTES0123")
    has(head, "Content-Disposition: attachment")
    has(head, "Content-Length: 9")
    os.remove(real)

    -- 不是文件（目录/不存在）→ 404；相对路径 → 400
    local c2 = newClient({ "GET /download?path=/etc HTTP/1.1\r\n\r\n" })
    drain(serve(c2))
    Assert.eq((parseResponse(c2:output())), 404)
    local c3 = newClient({ "GET /download?path=etc/passwd HTTP/1.1\r\n\r\n" })
    drain(serve(c3))
    Assert.eq((parseResponse(c3:output())), 400)
end

-- ── mkdir / delete / rename / extract ─────────────────

do
    -- mkdir → 200 + 参数透传
    local h1, calls1 = fakeHandlers({})
    local c1 = newClient({ "POST /api/mkdir?path=/a/b HTTP/1.1\r\nContent-Length: 0\r\n\r\n" })
    drain(serve(c1, h1))
    Assert.eq((parseResponse(c1:output())), 200)
    Assert.eq(calls1.mkdir, "/a/b")

    -- delete → 200；删除 / 拒绝
    local h2, calls2 = fakeHandlers({})
    local c2 = newClient({ "POST /api/delete?path=/a/b HTTP/1.1\r\nContent-Length: 0\r\n\r\n" })
    drain(serve(c2, h2))
    Assert.eq((parseResponse(c2:output())), 200)
    Assert.eq(calls2.delete, "/a/b")
    local c2b = newClient({ "POST /api/delete?path=/ HTTP/1.1\r\nContent-Length: 0\r\n\r\n" })
    drain(serve(c2b, h2))
    Assert.eq((parseResponse(c2b:output())), 403)

    -- rename → 200 + 双参数
    local h3, calls3 = fakeHandlers({})
    local c3 = newClient({ "POST /api/rename?path=/a&to=/b HTTP/1.1\r\nContent-Length: 0\r\n\r\n" })
    drain(serve(c3, h3))
    Assert.eq((parseResponse(c3:output())), 200)
    Assert.eq(calls3.rename.from, "/a")
    Assert.eq(calls3.rename.to, "/b")

    -- 可预期业务错误使用 404/409，不冒充服务内部故障。
    h1.mkdir = function(_, cb) cb(nil, "already exists") end
    local c1b = newClient({ "POST /api/mkdir?path=/a/b HTTP/1.1\r\nContent-Length: 0\r\n\r\n" })
    drain(serve(c1b, h1))
    Assert.eq((parseResponse(c1b:output())), 409)
    h2.delete = function(_, cb) cb(nil, "not found") end
    local c2c = newClient({ "POST /api/delete?path=/a/b HTTP/1.1\r\nContent-Length: 0\r\n\r\n" })
    drain(serve(c2c, h2))
    Assert.eq((parseResponse(c2c:output())), 404)

    -- rename 缺 to → 400；目标冲突 → 409
    local c4 = newClient({ "POST /api/rename?path=/a HTTP/1.1\r\nContent-Length: 0\r\n\r\n" })
    drain(serve(c4, h3))
    Assert.eq((parseResponse(c4:output())), 400)
    h3.rename = function(_, _, cb)
        cb(nil, "target exists")
    end
    local c5 = newClient({ "POST /api/rename?path=/a&to=/b HTTP/1.1\r\nContent-Length: 0\r\n\r\n" })
    drain(serve(c5, h3))
    local code5, body5 = parseResponse(c5:output())
    Assert.eq(code5, 409)
    has(body5, "target exists")

    -- GET 变更接口 → 405
    local c6 = newClient({ "GET /api/delete?path=/a HTTP/1.1\r\n\r\n" })
    drain(serve(c6, h3))
    Assert.eq((parseResponse(c6:output())), 405)

    -- extract → 200 + 输出目录；格式/体积/冲突错误保留明确语义。
    local h4, calls4 = fakeHandlers({})
    local c7 = newClient({ "POST /api/extract?path=/a/books.zip HTTP/1.1\r\nContent-Length: 0\r\n\r\n" })
    drain(serve(c7, h4))
    local code7, body7 = parseResponse(c7:output())
    Assert.eq(code7, 200)
    Assert.eq(calls4.extract, "/a/books.zip")
    has(body7, '"/a/books"')

    h4.extract = function(_, cb) cb(nil, "unsafe archive path") end
    local c8 = newClient({ "POST /api/extract?path=/a/books.zip HTTP/1.1\r\nContent-Length: 0\r\n\r\n" })
    drain(serve(c8, h4))
    Assert.eq((parseResponse(c8:output())), 400)
    h4.extract = function(_, cb) cb(nil, "archive too large") end
    local c9 = newClient({ "POST /api/extract?path=/a/books.zip HTTP/1.1\r\nContent-Length: 0\r\n\r\n" })
    drain(serve(c9, h4))
    Assert.eq((parseResponse(c9:output())), 413)
    h4.extract = function(_, cb) cb(nil, "target exists") end
    local c10 = newClient({ "POST /api/extract?path=/a/books.zip HTTP/1.1\r\nContent-Length: 0\r\n\r\n" })
    drain(serve(c10, h4))
    Assert.eq((parseResponse(c10:output())), 409)
    local c11 = newClient({ "GET /api/extract?path=/a/books.zip HTTP/1.1\r\n\r\n" })
    drain(serve(c11, h4))
    Assert.eq((parseResponse(c11:output())), 405)
end

-- ── 路由杂项 ──────────────────────────────────────────

do
    -- 未知路径 → 404
    local c1 = newClient({ "GET /nope HTTP/1.1\r\n\r\n" })
    drain(serve(c1))
    Assert.eq((parseResponse(c1:output())), 404)

    -- 方法不符 → 405
    local c2 = newClient({ "POST /api/list HTTP/1.1\r\nContent-Length: 0\r\n\r\n" })
    drain(serve(c2))
    Assert.eq((parseResponse(c2:output())), 405)

    -- 坏请求行 → 400
    local c3 = newClient({ "GARBAGE LINE\r\n\r\n" })
    drain(serve(c3))
    Assert.eq((parseResponse(c3:output())), 400)

    -- bind 失败
    bind_opts = { err = "address in use" }
    local s = Server.new({ port = 1, root = "/", token = TOKEN, handlers = {} })
    local ok, err = s:start()
    Assert.is_false(ok)
    Assert.eq(err, "address in use")
    bind_opts = nil
end

-- ── 增量语义：slice=0 一轮一动，大 body 跨 waitEvent ────

do
    local handlers, calls = fakeHandlers({ ["/inbox"] = {} })
    local client = newClient({
        "PUT /upload?dir=/inbox&name=big.bin HTTP/1.1\r\nContent-Length: 6\r\n\r\n",
        "ab",
        "cd",
        "ef",
    })
    local server = serve(client, handlers, { slice = 0 })
    server:waitEvent() -- 第 1 轮：只读到 headers
    Assert.is_nil(calls.save)
    server:waitEvent() -- 第 2 轮：ab
    Assert.is_nil(calls.save)
    server:waitEvent() -- 第 3 轮：cd
    Assert.is_nil(calls.save)
    drain(server) -- ef → 收尾 + 响应
    Assert.eq(calls.save.content, "abcdef")
    Assert.eq((parseResponse(client:output())), 200)
end

-- ── 部分写（EAGAIN）续发不丢字节 ──────────────────────

do
    local client = newClient({ "GET / HTTP/1.1\r\n\r\n" }, { send_limit = 7 })
    drain(serve(client))
    local code, body = parseResponse(client:output())
    Assert.eq(code, 200)
    has(body, "文件管理")
end

-- ── 空闲超时强杀 ──────────────────────────────────────

do
    local client = newClient({ "GET / HTTP/1.1\r\n" }) -- 头没给完就沉默
    local server = serve(client)
    server:waitEvent()
    Assert.eq(#server._conns, 1)
    fake_now = fake_now + 200
    server:waitEvent()
    Assert.eq(#server._conns, 0, "空闲超时应强杀")
    Assert.is_true(client.closed)
end

-- ── stop 清理活跃连接 ─────────────────────────────────

do
    local client = newClient({ "GET / HTTP/1.1\r\n" })
    local server = serve(client)
    server:waitEvent()
    server:stop()
    Assert.is_true(client.closed)
    Assert.eq(#server._conns, 0)
end


-- ── 远程输入（光标处追加）──────────────────────────────

do
    -- GET 激活状态：默认未激活 / 覆盖为激活
    local c1 = newClient({ "GET /api/input HTTP/1.1\r\n\r\n" })
    drain(serve(c1))
    local d1 = require("support.json_stub").decode(select(2, parseResponse(c1:output())))
    Assert.is_false(d1.active)

    -- 激活时带设备输入框全文（网页端光标预览）
    local h2 = fakeHandlers({})
    h2.get_input = function()
        return { active = true, text = "设备上已有文本" }
    end
    local c2 = newClient({ "GET /api/input HTTP/1.1\r\n\r\n" })
    drain(serve(c2, h2))
    local d2 = require("support.json_stub").decode(select(2, parseResponse(c2:output())))
    Assert.is_true(d2.active)
    Assert.eq(d2.text, "设备上已有文本", "GET 必须带设备当前文本")

    -- POST：分片送达的中文整段，完整注入
    local h3, calls3 = fakeHandlers({})
    local text = "第一段话。\n第二段话：中文 English 123"
    local c3 = newClient({
        "POST /api/input HTTP/1.1\r\nContent-Length: " .. #text .. "\r\n\r\n" .. text:sub(1, 10),
        text:sub(11),
    })
    drain(serve(c3, h3))
    Assert.eq(calls3.input, text, "text_mode body 必须完整拼接")
    Assert.eq((parseResponse(c3:output())), 200)

    -- POST 空 body = 无操作，不碰 handler，直接 200
    local h4, calls4 = fakeHandlers({})
    local c4 = newClient({ "POST /api/input HTTP/1.1\r\nContent-Length: 0\r\n\r\n" })
    drain(serve(c4, h4))
    Assert.is_nil(calls4.input)
    Assert.eq((parseResponse(c4:output())), 200)

    -- POST：无激活输入框 → 409
    local h5 = fakeHandlers({})
    h5.set_input = function()
        return nil, "no active input"
    end
    local c5 = newClient({ "POST /api/input HTTP/1.1\r\nContent-Length: 2\r\n\r\nhi" })
    drain(serve(c5, h5))
    Assert.eq((parseResponse(c5:output())), 409)

    -- POST：无 Content-Length → 411；超限 → 413
    local c6 = newClient({ "POST /api/input HTTP/1.1\r\n\r\n" })
    drain(serve(c6))
    Assert.eq((parseResponse(c6:output())), 411)
    local c7 = newClient({ "POST /api/input HTTP/1.1\r\nContent-Length: 300000\r\n\r\n" })
    drain(serve(c7))
    Assert.eq((parseResponse(c7:output())), 413)
    local c7b = newClient({ "POST /api/input HTTP/1.1\r\nContent-Length: 1.5\r\n\r\nx" })
    drain(serve(c7b))
    Assert.eq((parseResponse(c7b:output())), 400)

    -- GET 用错方法组合外的动词 → 405
    local c8 = newClient({ "DELETE /api/input HTTP/1.1\r\n\r\n" })
    drain(serve(c8))
    Assert.eq((parseResponse(c8:output())), 405)
end

-- ── 共享剪贴板（设备最后复制的文本）────────────────────

do
    -- GET：默认空剪贴板
    local c1 = newClient({ "GET /api/clipboard HTTP/1.1\r\n\r\n" })
    drain(serve(c1))
    local d1 = require("support.json_stub").decode(select(2, parseResponse(c1:output())))
    Assert.eq(d1.text, "")

    -- GET：读到设备端复制过的文本（阅读划线复制等经 handler 镜像进来）
    local h2, calls2 = fakeHandlers({})
    calls2.clipboard = "阅读里划的一段话"
    local c2 = newClient({ "GET /api/clipboard HTTP/1.1\r\n\r\n" })
    drain(serve(c2, h2))
    local d2 = require("support.json_stub").decode(select(2, parseResponse(c2:output())))
    Assert.eq(d2.text, "阅读里划的一段话")

    -- POST：网页整段写入设备剪贴板（分片送达，完整拼接）
    local h3, calls3 = fakeHandlers({})
    local text = "网页复制的第一行\n第二行：中文 English 123"
    local c3 = newClient({
        "POST /api/clipboard HTTP/1.1\r\nContent-Length: " .. #text .. "\r\n\r\n" .. text:sub(1, 9),
        text:sub(10),
    })
    drain(serve(c3, h3))
    Assert.eq(calls3.clipboard, text, "text_mode body 必须完整拼接")
    Assert.eq((parseResponse(c3:output())), 200)

    -- POST 空 body = 清空设备剪贴板
    local h4, calls4 = fakeHandlers({})
    calls4.clipboard = "旧内容"
    local c4 = newClient({ "POST /api/clipboard HTTP/1.1\r\nContent-Length: 0\r\n\r\n" })
    drain(serve(c4, h4))
    Assert.eq(calls4.clipboard, "", "空 body 必须清空剪贴板")
    Assert.eq((parseResponse(c4:output())), 200)

    -- 无 Content-Length → 411；超限 → 413；多余动词 → 405
    local c5 = newClient({ "POST /api/clipboard HTTP/1.1\r\n\r\n" })
    drain(serve(c5))
    Assert.eq((parseResponse(c5:output())), 411)
    local c6 = newClient({ "POST /api/clipboard HTTP/1.1\r\nContent-Length: 300000\r\n\r\n" })
    drain(serve(c6))
    Assert.eq((parseResponse(c6:output())), 413)
    local c7 = newClient({ "DELETE /api/clipboard HTTP/1.1\r\n\r\n" })
    drain(serve(c7))
    Assert.eq((parseResponse(c7:output())), 405)
end

-- ── 远程配置 ───────────────────────────────────────────
-- 必须 stub utils.settings：POST 会落盘，连沙箱配置也不该被这条用例改。

do
    local store = {
        ai = { ai_endpoint = "https://old.example/v1", ai_api_key = "sk-real", ai_model = "old" },
        moon = { base_url = "https://moon.test", token = "bk" },
        zlib = { email = "", password = "", base_url = nil },
    }
    package.preload["utils.settings"] = function()
        return {
            get = function(section)
                return store[section]
            end,
            getSource = function(id)
                return store[id]
            end,
            saveSection = function(section, cfg)
                store[section] = cfg
            end,
            saveSource = function(id, cfg)
                store[id] = cfg
            end,
        }
    end
    package.preload["source.registry"] = function()
        return { invalidate = function() end }
    end
    for _, name in ipairs({ "utils.settings", "source.registry", "remote.settings" }) do
        package.loaded[name] = nil
    end

    local c1 = newClient({ "GET /api/settings HTTP/1.1\r\n\r\n" })
    drain(serve(c1))
    local code, body = parseResponse(c1:output())
    Assert.eq(code, 200)
    local d = require("support.json_stub").decode(body)
    Assert.not_nil(d.ai)
    Assert.eq(d.ai.ai_endpoint, "https://old.example/v1")
    Assert.eq(d.ai.ai_api_key, "******")
    Assert.not_nil(d.moon)
    Assert.is_nil(d.rss)

    local payload = '{"ai":{"ai_endpoint":"https://cfg.test/v1","ai_api_key":"******","ai_model":"m"}}'
    local c2 = newClient({
        "POST /api/settings HTTP/1.1\r\nContent-Length: " .. #payload .. "\r\n\r\n" .. payload,
    })
    drain(serve(c2))
    Assert.eq((parseResponse(c2:output())), 200)
    Assert.eq(store.ai.ai_endpoint, "https://cfg.test/v1")
    Assert.eq(store.ai.ai_model, "m")
    Assert.eq(store.ai.ai_api_key, "sk-real")

    local c4 = newClient({ "DELETE /api/settings HTTP/1.1\r\n\r\n" })
    drain(serve(c4))
    Assert.eq((parseResponse(c4:output())), 405)

    local c5 = newClient({ "POST /api/settings HTTP/1.1\r\nContent-Length: 300000\r\n\r\n" })
    drain(serve(c5))
    Assert.eq((parseResponse(c5:output())), 413)

    for _, name in ipairs({ "utils.settings", "source.registry", "remote.settings" }) do
        package.preload[name] = nil
        package.loaded[name] = nil
    end
end
