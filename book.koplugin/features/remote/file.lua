--[[--
文件管理路由：列表 / 下载 / 上传 / mkdir / delete / rename / 解压 / 复制 / 移动 / 属性 / 文本写入 / 打包下载。

函数签名对齐 Server 方法（首参 self=server），由 features.remote.server 装配到
Server._route* 上；只依赖 server 暴露的 _fail/_queueResponse/jsonResp/errorResp/
_safePath/_isRoot/cleanPath/handlers，不反向 require server（防循环）。

@module koplugin.book.features.remote.file
--]]

local JSON = require("json")
local Text = require("utils.text")
local logger = require("utils.log")

local File = {}

-- FAT32 单文件上限以下留出余量；更大的文件不适合经阅读器缓存中转。
File.MAX_UPLOAD_BYTES = 2 * 1024 * 1024 * 1024

--- handler 错误串 → HTTP 状态码；不在表里的都是 500。
local ERROR_CODES = {
    ["protected path"] = 403,
    ["path outside managed roots"] = 403,
    ["not found"] = 404,
    ["already exists"] = 409,
    ["target exists"] = 409,
    ["target is not a file"] = 409,
    ["archive too large"] = 413,
    ["not a zip archive"] = 400,
    ["unsafe archive path"] = 400,
    ["unsupported archive entry"] = 400,
    ["too many archive entries"] = 400,
    ["target inside source"] = 400,
    ["too many entries"] = 413,
    ["file too large"] = 413,
}

-- 不走 utils/image：它认 .svg，同源 inline 下发 SVG 等于把脚本放进管理页的源里。
local IMAGE_TYPES = {
    [".png"] = "image/png", [".jpg"] = "image/jpeg", [".jpeg"] = "image/jpeg",
    [".gif"] = "image/gif", [".webp"] = "image/webp", [".bmp"] = "image/bmp",
    -- 媒体预览：音视频 inline 播放（不会被当成页面执行）。
    [".mp4"] = "video/mp4", [".m4v"] = "video/mp4", [".webm"] = "video/webm",
    [".mp3"] = "audio/mpeg", [".m4a"] = "audio/mp4", [".ogg"] = "audio/ogg",
    [".wav"] = "audio/wav", [".flac"] = "audio/flac",
}

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

--- 查询串路径 → managed roots 内的规范路径；非法已排 400、越界已排 403，返回 nil。
---@param conn table
---@param path string|nil
---@param bad string 400 的错误说明
---@return string|nil
local function resolveTarget(self, conn, path, bad)
    local target = self.cleanPath(path)
    if not target then
        return self:_fail(conn, 400, bad)
    end
    target = self:_safePath(target)
    if not target then
        return self:_fail(conn, 403, "Path outside managed roots")
    end
    return target
end

--- 变更类 handler 的回调：连接已死丢弃；失败按错误语义映射状态码；
--- 成功回 ok（handler 给出产物路径时一并带上）。
---@param conn table
---@param op string 日志用操作描述
---@return fun(ok: boolean|nil, err: any, output: string|nil)
local function mutationDone(self, conn, op)
    return function(ok, err, output)
        if conn.dead then return end
        if not ok then
            logger.warn("book remote mutate failed", op, err)
            conn.resp = self.errorResp(ERROR_CODES[err] or 500, err)
            return
        end
        logger.dbg("book remote mutate done", op)
        conn.resp = self.jsonResp(200, output and JSON.encode({ ok = true, path = output }) or '{"ok":true}')
    end
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
            conn.resp = self.errorResp(404, err)
            return
        end
        for _idx, entry in ipairs(entries) do
            entry.protected = self.handlers.is_protected(dir .. "/" .. entry.name)
        end
        conn.resp = self.jsonResp(200, listBody(dir, self:_parent(dir), entries))
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
    local target = resolveTarget(self, conn, path, "Bad path")
    if not target then
        return
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
    local ctype = IMAGE_TYPES[name:lower():match("(%.[^.]*)$")] or "application/octet-stream"
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
--- 校验目标后交给 server:_acceptFile 流式落盘，收齐再由 handlers.save 落位。
--- 方法不符 405，dir/name 非法 400，越界 403，其余长度类错误见 _acceptFile。
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
    dir = resolveTarget(self, conn, dir, "Bad dir")
    if not dir then
        return
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
    if conflict == "ask" and self.handlers.path_exists(dir .. "/" .. name) then
        return self:_fail(conn, 409, "File exists")
    end
    return self:_acceptFile(conn, headers, File.MAX_UPLOAD_BYTES, function(temp, reply)
        self.handlers.save(temp, dir, name, function(ok, err)
            if not ok then
                logger.warn("book remote upload failed", dir, name, err)
                return reply(self.errorResp(500, "Save failed: " .. tostring(err)))
            end
            logger.dbg("book remote upload saved", dir, name, conflict)
            reply(self.jsonResp(200, '{"ok":true}'))
        end, conflict)
    end)
end

--- POST /api/mkdir|delete?path=（无请求体的单路径变更操作公共壳）。
--- 非 POST 405，路径非法 400，越界/删 root 或受保护路径 403；
--- 不存在 404、冲突 409，其余 handler 失败 500。
---@param conn table
---@param method string
---@param path string|nil 目标绝对路径
---@param op "mkdir"|"delete" handlers 里的同名操作
function File.mutate(self, conn, method, path, op)
    if method ~= "POST" then
        return self:_fail(conn, 405, "Method Not Allowed")
    end
    local target = resolveTarget(self, conn, path, "Bad path")
    if not target then
        return
    end
    if op == "delete" and (self:_isRoot(target) or self.handlers.is_protected(target)) then
        return self:_fail(conn, 403, "Protected path")
    end
    conn.state = "pending"
    self.handlers[op](target, mutationDone(self, conn, op .. " " .. target))
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
    self.handlers.rename(from, to, mutationDone(self, conn, "rename " .. from .. " " .. to))
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
    local target = resolveTarget(self, conn, path, "Bad path")
    if not target then
        return
    end
    conn.state = "pending"
    self.handlers.extract(target, mutationDone(self, conn, "extract " .. target))
    return true
end

-- ── 复制 / 移动 / 属性 / 文本写入 / 打包下载 ──────────────

local CONFLICTS = { ask = true, skip = true, rename = true, overwrite = true }

--- POST /api/copy|move?path=&to=&conflict=：复制或移动一个条目到完整目标路径。
--- conflict 缺省 ask（目标存在回 409，由网页选择保留两份 / 替换 / 跳过）。
--- 非 POST 405，路径非法 400，越界 403；移动的源、任一目标受保护 403。
---@param conn table
---@param method string
---@param query table
---@param op "copy"|"move"
function File.transfer(self, conn, method, query, op)
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
    local conflict = query.conflict or "ask"
    if not CONFLICTS[conflict] then
        return self:_fail(conn, 400, "Bad conflict policy")
    end
    if self:_isRoot(to) or self.handlers.is_protected(to)
        or (op == "move" and (self:_isRoot(from) or self.handlers.is_protected(from))) then
        return self:_fail(conn, 403, "Protected path")
    end
    conn.state = "pending"
    self.handlers.transfer(op, from, to, conflict, mutationDone(self, conn, op .. " " .. from .. " " .. to))
    return true
end

--- GET /api/stat?path=：属性（类型、大小、时间、权限、属主、链接目标；目录含统计）。
---@param conn table
---@param method string
---@param path string|nil
function File.stat(self, conn, method, path)
    if method ~= "GET" then
        return self:_fail(conn, 405, "Method Not Allowed")
    end
    local target = resolveTarget(self, conn, path, "Bad path")
    if not target then
        return
    end
    conn.state = "pending"
    self.handlers.stat(target, function(info, err)
        if conn.dead then return end
        if not info then
            conn.resp = self.errorResp(ERROR_CODES[err] or 500, err)
            return
        end
        conn.resp = self.jsonResp(200, JSON.encode(info))
    end)
    return true
end

File.MAX_TEXT_BYTES = 4 * 1024 * 1024

--- POST /api/write?path=[&create=1]：请求体原样写成文本文件（编辑器保存 / 新建空文件）。
--- create=1 时目标已存在回 409。体积上限 MAX_TEXT_BYTES。
---@param conn table
---@param method string
---@param headers table
---@param query table
function File.write(self, conn, method, headers, query)
    if method ~= "POST" then
        return self:_fail(conn, 405, "Method Not Allowed")
    end
    local target = resolveTarget(self, conn, query.path, "Bad path")
    if not target then
        return
    end
    if self:_isRoot(target) or self.handlers.is_protected(target) then
        return self:_fail(conn, 403, "Protected path")
    end
    local create = query.create == "1"
    return self:_acceptText(conn, headers, File.MAX_TEXT_BYTES, function(server, c, text)
        c.state = "pending"
        server.handlers.write_text(target, text, create, mutationDone(server, c, "write " .. target))
    end)
end

File.ZIP_BODY_LIMIT = 256 * 1024
File.MAX_ZIP_ITEMS = 1000

--- 打包请求体收尾：{"paths":[...],"name":"x.zip"} → 后台建 zip，回 {"id":...}，再由 GET 取走。
---@param conn table
---@param text string
local function finishZip(self, conn, text)
    local payload = JSON.decode(text ~= "" and text or "{}")
    local list = type(payload) == "table" and payload.paths
    if type(list) ~= "table" or #list == 0 or #list > File.MAX_ZIP_ITEMS then
        return self:_fail(conn, 400, "Bad paths")
    end
    local paths = {}
    for i, p in ipairs(list) do
        local target = type(p) == "string" and self.cleanPath(p)
        if not target then
            return self:_fail(conn, 400, "Bad path")
        end
        target = self:_safePath(target)
        if not target then
            return self:_fail(conn, 403, "Path outside managed roots")
        end
        paths[i] = target
    end
    local name = type(payload.name) == "string" and payload.name:gsub("[/\\%c\"]", "_") or ""
    if name == "" then
        name = "moon-files.zip"
    elseif not name:lower():match("%.zip$") then
        name = name .. ".zip"
    end
    conn.state = "pending"
    self.handlers.zip(paths, function(output, err)
        if conn.dead then
            if output then os.remove(output) end
            return
        end
        if not output then
            logger.warn("book remote zip failed", err)
            conn.resp = self.errorResp(ERROR_CODES[err] or 500, err)
            return
        end
        -- 只留最近一个未取走的包：新包替换旧包，旧临时文件当场删。
        if self._zip and self._zip.path ~= output then
            os.remove(self._zip.path)
        end
        self._zip_seq = (self._zip_seq or 0) + 1
        local id = tostring(os.time()) .. "-" .. self._zip_seq
        self._zip = { id = id, path = output, name = name }
        conn.resp = self.jsonResp(200, JSON.encode({ id = id, name = name }))
    end)
    return true
end

--- POST /api/zip 建包；GET /api/zip?id= 以附件下发并删除临时包（打开后即 unlink，发完自动回收）。
---@param conn table
---@param method string
---@param headers table
---@param query table
function File.zip(self, conn, method, headers, query)
    if method == "POST" then
        return self:_acceptText(conn, headers, File.ZIP_BODY_LIMIT, finishZip)
    end
    if method ~= "GET" then
        return self:_fail(conn, 405, "Method Not Allowed")
    end
    local pending = self._zip
    if not pending or pending.id ~= query.id then
        return self:_fail(conn, 404, "Archive expired")
    end
    self._zip = nil
    local file = io.open(pending.path, "rb")
    os.remove(pending.path)
    if not file then
        return self:_fail(conn, 404, "Archive gone")
    end
    local size = file:seek("end") or 0
    file:seek("set", 0)
    return self:_queueResponse(conn, {
        code = 200,
        ctype = "application/zip",
        extra = { "Content-Disposition: attachment; filename*=UTF-8''" .. Text.urlEncode(pending.name) },
        file = file,
        size = size,
    })
end

return File
