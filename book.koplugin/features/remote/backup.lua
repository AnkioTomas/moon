--[[--
备份与恢复：GET /api/backup 下载整个 .moon 目录的 zip，POST /api/backup 上传恢复。

范围：.moon 下除日志与缓存外的全部内容（book.sqlite3 书库 / 笔记 / 进度 / 统计、settings/ 全部配置，
**含登录态、Cookie、令牌、API Key、WebDAV 密码、锁屏密码哈希**——备份等同账号凭据，由用户自己保管）、
锁屏资源、字体、输入法词库。不含：book.log*、cache/（可重新下载）、backups/（补丁原文件，与 KOReader 版本绑定）、
sqlite 的 -wal / -shm（下载前主进程已 checkpoint，只带主库文件）。

恢复先整包解到 .moon/restore.part，校验通过（带 MARKER、路径安全）后逐个顶层条目整体替换（fonts 例外：主进程 mmap 着字体，只补缺不删，见 mergeFonts），失败不动现有数据。
文件系统部分跑在 IO 子进程里；关库、重载配置与重启由调用方（init.lua）在主进程完成。

ffi/archiver 的 Writer / Reader 与 lfs 由调用方传入，离线测试可替身。

@module koplugin.book.features.remote.backup
--]]

local Backup = {}

Backup.MARKER = "moon-backup.txt"
Backup.MAX_BYTES = 4 * 1024 * 1024 * 1024
Backup.MAX_ENTRIES = 200000
Backup.STAGING = "restore.part"

--- 相对 .moon 的路径是否不进备份。
---@param rel string
---@return boolean
function Backup.skip(rel)
    local top = rel:match("^[^/]+")
    return top == "cache" or top == "backups" or top == Backup.STAGING
        or rel:match("^book%.log") ~= nil
        or rel:match("%-wal$") ~= nil or rel:match("%-shm$") ~= nil
end

--- 备份文件名 moon-backup-YYYYMMDD-HHMM.zip
---@return string
function Backup.fileName()
    return os.date("moon-backup-%Y%m%d-%H%M.zip") --[[@as string]]
end

---@param lfs table
---@param root string
---@return { name: string, path: string }[]
function Backup.collect(lfs, root)
    local out = {}
    local function walk(dir, prefix)
        for child in lfs.dir(dir) do
            if child ~= "." and child ~= ".." then
                local rel, path = prefix .. child, dir .. "/" .. child
                local attr = lfs.symlinkattributes(path)
                if attr and not Backup.skip(rel) then
                    if attr.mode == "directory" then
                        walk(path, rel .. "/")
                    elseif attr.mode == "file" then
                        out[#out + 1] = { name = rel, path = path }
                    end
                end
            end
        end
    end
    if lfs.attributes(root, "mode") == "directory" then walk(root, "") end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

--- 把 .moon 打成 zip。
---@param output string
---@param root string
---@param Writer table ffi/archiver 的 Writer 类
---@param lfs table
---@return string|nil output, string|nil err
function Backup.build(output, root, Writer, lfs)
    local files = Backup.collect(lfs, root)
    local writer = Writer:new()
    if not writer:open(output, "zip") then
        return nil, writer.err or "cannot create archive"
    end
    writer:setZipCompression("deflate")
    local function fail()
        local err = writer.err
        writer:close()
        os.remove(output)
        return nil, err or "archive write failed"
    end
    local now = os.time()
    local mark = string.format("moon-backup 1\ncreated=%d\n", now)
    if not writer:addFileFromMemory(Backup.MARKER, mark, now) then return fail() end
    for _idx, file in ipairs(files) do
        -- addPath 正常结束时内部状态是 EOF，返回值为假；只有 err 非空才是真失败
        if not writer:addPath(file.name, file.path, false) and writer.err then return fail() end
    end
    writer:close()
    require("features.remote.logs").fixPerms(output)
    return output
end

---@param lfs table
---@param path string
local function rmtree(lfs, path)
    local attr = lfs.symlinkattributes(path)
    if not attr then return end
    if attr.mode == "directory" then
        for child in lfs.dir(path) do
            if child ~= "." and child ~= ".." then rmtree(lfs, path .. "/" .. child) end
        end
        lfs.rmdir(path)
    else
        os.remove(path)
    end
end

--- 清除全部配置：删 settings 目录整棵树与给定文件（crash.log 等），书库、字体、词库不动。
---@param lfs table
---@param settings_dir string
---@param files string[]
---@return boolean ok
function Backup.clearConfig(lfs, settings_dir, files)
    rmtree(lfs, settings_dir)
    for _idx, path in ipairs(files) do os.remove(path) end
    return true
end

--- 条目路径必须是相对、不含 .. 的 / 分隔路径。
---@param path any
---@return boolean
local function safe(path)
    return type(path) == "string" and path ~= ""
        and path:sub(1, 1) ~= "/" and not path:find("\\", 1, true) and not path:match("^%a:")
        and path ~= ".." and not path:match("^%.%./") and not path:match("/%.%./") and not path:match("/%.%.$")
end

--- 字体由主进程的 FreeType / CRE 一直 mmap 着，整目录删掉再换会让主进程在下一次绘制时 SIGBUS
--- （KOReader 在恢复中途崩溃）。字体按 id 命名、内容固定：已有的原样保留，只补备份里多出来的。
---@param lfs table
---@param from string
---@param to string
local function mergeFonts(lfs, from, to)
    for file in lfs.dir(from) do
        if file ~= "." and file ~= ".." and not lfs.attributes(to .. "/" .. file, "mode") then
            os.rename(from .. "/" .. file, to .. "/" .. file)
        end
    end
end

--- 整体替换一个顶层条目。
---@return boolean|nil moved, string|nil err
local function replace(lfs, from, dest, name)
    rmtree(lfs, dest)
    if name:match("%.sqlite3$") then -- 旧库的 WAL 套不到新库上
        os.remove(dest .. "-wal")
        os.remove(dest .. "-shm")
    end
    return os.rename(from, dest)
end

--- 解包并替换 .moon 对应条目。
---@param archive string
---@param root string
---@param Reader table ffi/archiver 的 Reader 类
---@param lfs table
---@return string[]|nil restored 被替换的顶层条目名
---@return string|nil err
function Backup.restore(archive, root, Reader, lfs)
    local staging = root .. "/" .. Backup.STAGING
    rmtree(lfs, staging)
    if not lfs.mkdir(staging) then return nil, "cannot create staging" end
    local reader = Reader:new()
    local function fail(err)
        reader:close()
        rmtree(lfs, staging)
        return nil, err
    end
    if not reader:open(archive) then return fail("not a moon backup") end
    local count = 0
    for entry in reader:iterate() do
        count = count + 1
        if count > Backup.MAX_ENTRIES then return fail("too many archive entries") end
        if not safe(entry.path) then return fail("unsafe archive path") end
        if entry.mode ~= "file" and entry.mode ~= "directory" then return fail("unsupported archive entry") end
        if not Backup.skip(entry.path) and not reader:extractToPath(entry.path, staging .. "/" .. entry.path) then
            return fail(reader.err or "archive extraction failed")
        end
    end
    local iterate_err = reader.err
    reader:close()
    if iterate_err then
        rmtree(lfs, staging)
        return nil, iterate_err
    end
    if lfs.attributes(staging .. "/" .. Backup.MARKER, "mode") ~= "file" then
        rmtree(lfs, staging)
        return nil, "not a moon backup"
    end
    os.remove(staging .. "/" .. Backup.MARKER)

    local names = {}
    for name in lfs.dir(staging) do
        if name ~= "." and name ~= ".." then names[#names + 1] = name end
    end
    table.sort(names)
    if #names == 0 then
        rmtree(lfs, staging)
        return nil, "backup is empty"
    end
    for _idx, name in ipairs(names) do
        local dest = root .. "/" .. name
        if name == "fonts" and lfs.attributes(dest, "mode") == "directory" then
            mergeFonts(lfs, staging .. "/" .. name, dest)
        else
            local moved, err = replace(lfs, staging .. "/" .. name, dest, name)
            if not moved then
                rmtree(lfs, staging)
                return nil, err
            end
        end
    end
    rmtree(lfs, staging)
    return names
end

local ERROR_CODES = {
    ["not a moon backup"] = 400,
    ["unsafe archive path"] = 400,
    ["unsupported archive entry"] = 400,
    ["too many archive entries"] = 400,
    ["backup is empty"] = 400,
}

--- 路由：GET 下载、POST 上传恢复（恢复成功后设备提示并重启，由 handlers.restore_backup 负责）。
---@param conn table
---@param method string
---@param headers table
function Backup.route(self, conn, method, headers)
    if method == "GET" then
        return self:_sendBuiltZip(conn, self.handlers.backup_zip, Backup.fileName())
    end
    if method ~= "POST" then
        return self:_fail(conn, 405, "Method Not Allowed")
    end
    return self:_acceptFile(conn, headers, Backup.MAX_BYTES, function(temp, reply)
        self.handlers.restore_backup(temp, function(ok, err)
            if not ok then
                return reply(self.errorResp(ERROR_CODES[err] or 500, err))
            end
            reply(self.jsonResp(200, '{"ok":true}'))
        end)
    end)
end

--- 路由：POST /api/reset 清除全部配置与 crash.log，设备提示后重启（由 handlers.reset_config 负责）。
---@param conn table
---@param method string
function Backup.reset(self, conn, method)
    if method ~= "POST" then
        return self:_fail(conn, 405, "Method Not Allowed")
    end
    self.handlers.reset_config(function(ok, err)
        if not ok then
            return self:_fail(conn, 500, err)
        end
        return self:_json(conn, 200, '{"ok":true}')
    end)
end

return Backup
