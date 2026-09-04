--[[--
文件管理路由：列表 / 下载 / 上传 / mkdir / delete / rename + 页面片段。

函数签名对齐 Server 方法（首参 self=server），由 remote.server 装配到
Server._route* 上；只依赖 server 暴露的 _fail/_queueResponse/_safePath/
_isRoot/cleanPath/handlers，不反向 require server（防循环）。

@module koplugin.book.remote.file
--]]

local JSON = require("json")
local Text = require("utils.text")
local logger = require("utils.log")

local File = {}

-- FAT32 单文件上限以下留出余量；更大的文件不适合经阅读器缓存中转。
File.MAX_UPLOAD_BYTES = 2 * 1024 * 1024 * 1024

---@param err any
---@return number
local function mutationErrorCode(err)
    err = tostring(err or "")
    if err == "protected path" or err == "path outside managed roots" then
        return 403
    end
    if err == "not found" then
        return 404
    end
    if err == "already exists" or err == "target exists" or err == "target is not a file" then
        return 409
    end
    if err == "archive too large" then
        return 413
    end
    if err == "not a zip archive" or err == "unsafe archive path"
        or err == "unsupported archive entry" or err == "too many archive entries"
    then
        return 400
    end
    return 500
end

---@param path string
---@param parent string|nil
---@param entries table[]
---@return string
local function listBody(path, parent, entries)
    return '{"path":' .. JSON.encode(path)
        .. ',"parent":' .. (parent and JSON.encode(parent) or "null")
        .. ',"entries":' .. (#entries == 0 and "[]" or JSON.encode(entries))
        .. "}"
end

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
    conn.state = "pending"
    self.handlers.list_dir(dir, function(entries, err)
        if conn.dead then return end
        if not entries then
            conn.resp = {
                code = 404,
                ctype = "application/json; charset=utf-8",
                body = JSON.encode({ error = tostring(err) }),
            }
            return
        end
        for _, entry in ipairs(entries) do
            entry.protected = self.handlers.is_protected(dir .. "/" .. entry.name)
        end
        conn.resp = {
            code = 200,
            ctype = "application/json; charset=utf-8",
            body = listBody(dir, self:_parent(dir), entries),
        }
    end)
    return true
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
    if not self.handlers.is_dir(dir) then
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
    if headers["transfer-encoding"] then
        return self:_fail(conn, 501, "Chunked not supported")
    end
    local len, len_err = self:_contentLength(headers)
    if len_err == "missing" then
        return self:_fail(conn, 411, "Content-Length required")
    end
    if not len then
        return self:_fail(conn, 400, "Invalid Content-Length")
    end
    if len < 1 then
        return self:_fail(conn, 411, "Content-Length required")
    end
    if len > File.MAX_UPLOAD_BYTES then
        return self:_fail(conn, 413, "Upload too large")
    end
    local temp = self.handlers.temp_path(name)
    local file, ferr = io.open(temp, "wb")
    if not file then
        return self:_fail(conn, 500, ferr)
    end
    conn.file = file
    conn.temp = temp
    conn.dir = dir
    conn.name = name
    conn.conflict = conflict
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

--- POST /api/mkdir|delete?path=（无请求体的单路径变更操作公共壳）。
--- 非 POST 405，路径非法 400，越界/删 root 或受保护路径 403；
--- 不存在 404、冲突 409，其余 handler 失败 500。
---@param conn table
---@param method string
---@param path string|nil 目标绝对路径
---@param fn fun(path: string, cb: fun(ok: boolean|nil, err: any)) 实际变更操作
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
    local op = fn == self.handlers.delete and "delete" or "mkdir"
    conn.state = "pending"
    fn(target, function(ok, err)
        if conn.dead then return end
        if not ok then
            logger.warn("book remote mutate failed", op, target, err)
            conn.resp = {
                code = mutationErrorCode(err),
                ctype = "application/json; charset=utf-8",
                body = JSON.encode({ error = tostring(err) }),
            }
            return
        end
        logger.dbg("book remote mutate done", op, target)
        conn.resp = {
            code = 200, ctype = "application/json; charset=utf-8", body = '{"ok":true}',
        }
    end)
    return true
end

--- POST /api/rename?path=&to=：重命名/移动，源与目标都必须在 managed roots 内。
--- 非 POST 405，路径非法 400，越界或源是 root、源/目标受保护 403；
--- 不存在 404、冲突 409，其余 handler 失败 500。
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
    conn.state = "pending"
    self.handlers.rename(from, to, function(ok, err)
        if conn.dead then return end
        if not ok then
            logger.warn("book remote mutate failed", "rename", from, to, err)
            conn.resp = {
                code = mutationErrorCode(err),
                ctype = "application/json; charset=utf-8",
                body = JSON.encode({ error = tostring(err) }),
            }
            return
        end
        logger.dbg("book remote mutate done", "rename", from, to)
        conn.resp = {
            code = 200, ctype = "application/json; charset=utf-8", body = '{"ok":true}',
        }
    end)
    return true
end

--- POST /api/extract?path=：把 ZIP 解压到同目录下的同名文件夹。
---@param conn table
---@param method string
---@param path string|nil
function File.extract(self, conn, method, path)
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
    conn.state = "pending"
    self.handlers.extract(target, function(ok, err, output)
        if conn.dead then return end
        if not ok then
            logger.warn("book remote extract failed", target, err)
            conn.resp = {
                code = mutationErrorCode(err),
                ctype = "application/json; charset=utf-8",
                body = JSON.encode({ error = tostring(err) }),
            }
            return
        end
        conn.resp = {
            code = 200,
            ctype = "application/json; charset=utf-8",
            body = JSON.encode({ ok = true, path = output }),
        }
    end)
    return true
end

return File
