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

--- GET /api/list?path=：列目录，逐项标注 protected。
--- path 缺省列 server.root；非 GET 405，越界 403，非目录/不存在 404。
---@param conn table
---@param method string
---@param path string|nil 目标目录绝对路径
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

--- GET /download?path=：以 attachment 流式下发单个普通文件。
--- 非 GET 405，路径非法 400，越界 403，不是文件或打开失败 404。
---@param conn table
---@param method string
---@param path string|nil 目标文件绝对路径
---@param inline string|nil 图片预览时省略附件头
function File.download(self, conn, method, path, inline)
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
    local ext = name:lower():match("(%.[^.]*)$")
    local ctype = ({
        [".png"] = "image/png", [".jpg"] = "image/jpeg", [".jpeg"] = "image/jpeg",
        [".gif"] = "image/gif", [".webp"] = "image/webp", [".bmp"] = "image/bmp",
    })[ext] or "application/octet-stream"
    local extra = nil
    if inline ~= "1" then
        extra = { "Content-Disposition: attachment; filename*=UTF-8''" .. Text.urlEncode(name) }
    end
    return self:_queueResponse(conn, {
        code = 200,
        ctype = ctype,
        extra = extra,
        file = file,
        size = size,
    })
end

--- PUT|POST /upload?dir=&name=（raw body 流式落盘，body 读取在 server 状态机）。
--- 校验通过后开临时文件、把连接切到 body 状态；带 Expect: 100-continue 先回 interim。
--- 方法不符 405，dir/name 非法 400，越界 403，chunked 501，缺 Content-Length 411，开文件失败 500。
---@param conn table
---@param method string
---@param headers table 已小写化的请求头
---@param dir string|nil 落位目录绝对路径
---@param name string|nil 文件名（斜杠会被替换成下划线）
---@param conflict string|nil 重名策略：缺省 ask，先 409 让客户端选择
---@return true|nil true=已进 body 状态；nil=已排错误响应
function File.upload(self, conn, method, headers, dir, name, conflict)
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
    conflict = conflict or "ask"
    if conflict ~= "ask" and conflict ~= "overwrite" and conflict ~= "skip" and conflict ~= "rename" then
        return self:_fail(conn, 400, "Bad conflict policy")
    end
    if conflict == "ask" and self.handlers.path_exists
        and self.handlers.path_exists(dir .. "/" .. name) then
        return self:_fail(conn, 409, "File exists")
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
    conn.conflict = conflict
    conn.remaining = len
    conn.state = "body"
    return true
end

--- POST /api/mkdir|delete?path=（无请求体的单路径变更操作公共壳）。
--- 非 POST 405，路径非法 400，越界/删 root 或受保护路径 403，handler 失败 500。
---@param conn table
---@param method string
---@param path string|nil 目标绝对路径
---@param fn fun(path: string): boolean|nil, any 实际变更操作（handlers.mkdir / handlers.delete）
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

--- POST /api/rename?path=&to=：重命名/移动，源与目标都必须在 managed roots 内。
--- 非 POST 405，路径非法 400，越界或源是 root、源/目标受保护 403，handler 失败 500。
---@param conn table
---@param method string
---@param query table 查询串，取 path（源）与 to（目标）
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
