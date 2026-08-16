--[[--
文件管理路由：列表 / 下载 / 上传 / mkdir / delete / rename + 页面片段。

函数签名对齐 Server 方法（首参 self=server），由 remote.server 装配到
Server._route* 上；只依赖 server 暴露的 _fail/_queueResponse/_safePath/
_isRoot/cleanPath/handlers，不反向 require server（防循环）。

@module koplugin.book.remote.file
--]]

local JSON = require("json")
local Text = require("utils.text")

local File = {}

-- ── 路由 ─────────────────────────────────────────────

--- GET /api/list?path=
function File.list(self, conn, method, path)
    if method ~= "GET" then
        return self:_fail(conn, 405, "Method Not Allowed")
    end
    local dir
    if path == nil or path == "" then
        dir = self.root
    else
        dir = self:_safePath(path)
        if not dir then
            return self:_fail(conn, 403, "Path outside managed roots")
        end
    end
    local entries, err = self.handlers.list_dir(dir)
    if not entries then
        return self:_fail(conn, 404, err)
    end
    for _, entry in ipairs(entries) do
        entry.protected = self.handlers.is_protected(dir .. "/" .. entry.name)
    end
    return self:_queueResponse(conn, {
        code = 200,
        ctype = "application/json; charset=utf-8",
        body = JSON.encode({
            path = dir,
            parent = self:_parent(dir),
            entries = entries,
        }),
    })
end

--- GET /download?path=
function File.download(self, conn, method, path)
    if method ~= "GET" then
        return self:_fail(conn, 405, "Method Not Allowed")
    end
    local target = self.cleanPath(path)
    if not target then
        return self:_fail(conn, 400, "Bad path")
    end
    target = self:_safePath(target)
    if not target then
        return self:_fail(conn, 403, "Path outside managed roots")
    end
    local real = self.handlers.resolve_download(target)
    if not real then
        return self:_fail(conn, 404, "Not a file")
    end
    local file = io.open(real, "rb")
    if not file then
        return self:_fail(conn, 404, "File gone")
    end
    local size = file:seek("end") or 0
    file:seek("set", 0)
    local name = real:match("([^/]+)$") or "file"
    return self:_queueResponse(conn, {
        code = 200,
        ctype = "application/octet-stream",
        extra = { "Content-Disposition: attachment; filename*=UTF-8''" .. Text.urlEncode(name) },
        file = file,
        size = size,
    })
end

--- PUT|POST /upload?dir=&name=（raw body 流式落盘，body 读取在 server 状态机）
function File.upload(self, conn, method, headers, dir, name)
    if method ~= "PUT" and method ~= "POST" then
        return self:_fail(conn, 405, "Method Not Allowed")
    end
    dir = self.cleanPath(dir)
    if not dir then
        return self:_fail(conn, 400, "Bad dir")
    end
    dir = self:_safePath(dir)
    if not dir then
        return self:_fail(conn, 403, "Path outside managed roots")
    end
    if not self.handlers.list_dir(dir) then
        return self:_fail(conn, 400, "Bad dir")
    end
    name = Text.trim(type(name) == "string" and name:gsub("[/\\]", "_") or "")
    if name == "" or name == "." or name == ".." then
        return self:_fail(conn, 400, "Bad name")
    end
    local len = tonumber(headers["content-length"] or "")
    if headers["transfer-encoding"] and not len then
        return self:_fail(conn, 501, "Chunked not supported")
    end
    if not len or len < 1 then
        return self:_fail(conn, 411, "Content-Length required")
    end
    local temp = self.handlers.temp_path(name)
    local file, ferr = io.open(temp, "wb")
    if not file then
        return self:_fail(conn, 500, ferr)
    end
    -- curl 大文件带 Expect: 100-continue，先发 interim（25 字节，零超时发出即可；
    -- 偶发 EAGAIN 时 curl 1s 后也会自行发 body，不死锁）
    local expect = headers["expect"]
    if type(expect) == "string" and expect:lower():find("100%-continue") then
        conn.sock:send("HTTP/1.1 100 Continue\r\n\r\n")
    end
    conn.file = file
    conn.temp = temp
    conn.dir = dir
    conn.name = name
    conn.remaining = len
    conn.state = "body"
    return true
end

--- POST /api/mkdir|delete?path=（无请求体的单路径变更操作公共壳）
function File.mutate(self, conn, method, path, fn)
    if method ~= "POST" then
        return self:_fail(conn, 405, "Method Not Allowed")
    end
    local target = self.cleanPath(path)
    if not target then
        return self:_fail(conn, 400, "Bad path")
    end
    target = self:_safePath(target)
    if not target then
        return self:_fail(conn, 403, "Path outside managed roots")
    end
    if fn == self.handlers.delete
        and (self:_isRoot(target) or self.handlers.is_protected(target)) then
        return self:_fail(conn, 403, "Protected path")
    end
    local ok, err = fn(target)
    if not ok then
        return self:_fail(conn, 500, err)
    end
    return self:_queueResponse(conn, {
        code = 200, ctype = "application/json; charset=utf-8", body = '{"ok":true}',
    })
end

--- POST /api/rename?path=&to=
function File.rename(self, conn, method, query)
    if method ~= "POST" then
        return self:_fail(conn, 405, "Method Not Allowed")
    end
    local from, to = self.cleanPath(query.path), self.cleanPath(query.to)
    if not from or not to then
        return self:_fail(conn, 400, "Bad path")
    end
    from, to = self:_safePath(from), self:_safePath(to)
    if not from or not to then
        return self:_fail(conn, 403, "Path outside managed roots")
    end
    if self:_isRoot(from) or self.handlers.is_protected(from) or self.handlers.is_protected(to) then
        return self:_fail(conn, 403, "Protected path")
    end
    local ok, err = self.handlers.rename(from, to)
    if not ok then
        return self:_fail(conn, 500, err)
    end
    return self:_queueResponse(conn, {
        code = 200, ctype = "application/json; charset=utf-8", body = '{"ok":true}',
    })
end

return File
