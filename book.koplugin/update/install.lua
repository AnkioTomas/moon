--[[--
插件更新包校验与目录换位。

ZIP 必须只包含一个 book.koplugin/ 目录。新目录完整解压、校验后才与
当前插件目录换位；旧目录保留为同级 .book.koplugin-backup。

@module koplugin.book.update.install
--]]

local lfs = require("libs/libkoreader-lfs")

local Install = {}

Install.MAX_ARCHIVE_BYTES = 100 * 1024 * 1024
Install.MAX_ENTRIES = 5000

local function attributes(path)
    if lfs.symlinkattributes then return lfs.symlinkattributes(path) end
    return lfs.attributes(path)
end

local function removeTree(path)
    local attr = attributes(path)
    if not attr then return true end
    if attr.mode ~= "directory" then return os.remove(path) end
    local iter, state = lfs.dir(path)
    if not iter then return nil, state end
    for name in iter, state do
        if name ~= "." and name ~= ".." then
            local ok, err = removeTree(path .. "/" .. name)
            if not ok then return nil, err end
        end
    end
    return lfs.rmdir(path)
end

local function safeEntry(path)
    local prefix = "book.koplugin/"
    return type(path) == "string"
        and (path == "book.koplugin" or path:sub(1, #prefix) == prefix)
        and not path:find("\\", 1, true)
        and not path:match("/%.%./")
        and not path:match("/%.%.$")
end

local function fileSha256(path)
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    local hash = require("ffi/sha2").sha256()
    while true do
        local chunk, read_err = file:read(256 * 1024)
        if not chunk then
            file:close()
            if read_err then return nil, read_err end
            return hash()
        end
        hash(chunk)
    end
end

local function validateLuaTree(path)
    local iter, state = lfs.dir(path)
    if not iter then return nil, state end
    for name in iter, state do
        if name ~= "." and name ~= ".." then
            local child = path .. "/" .. name
            local attr = attributes(child)
            if not attr then
                return nil, "missing extracted entry: " .. name
            elseif attr.mode == "directory" then
                local ok, err = validateLuaTree(child)
                if not ok then return nil, err end
            elseif attr.mode == "file" and name:match("%.lua$") then
                local chunk, err = loadfile(child)
                if not chunk then return nil, err end
            elseif attr.mode ~= "file" then
                return nil, "unsupported extracted entry: " .. name
            end
        end
    end
    return true
end

local function readPackagedVersion(root)
    local file = io.open(root .. "/bookversion.lua", "rb")
    if not file then return nil, "archive has no bookversion.lua" end
    local body = file:read(256)
    file:close()
    local version = body and body:match('^return%s+"([%w%.%+%-]+)"%s*$')
    if not version then return nil, "invalid packaged version" end
    return version
end

local function extractArchive(archive, staging)
    local reader = require("ffi/archiver").Reader:new()
    local function fail(err)
        reader:close()
        removeTree(staging)
        return nil, err
    end
    if not reader:open(archive) then
        return fail(reader.err or "cannot open update archive")
    end
    local count, total = 0, 0
    for entry in reader:iterate() do
        count = count + 1
        if count > Install.MAX_ENTRIES then return fail("too many archive entries") end
        if not safeEntry(entry.path) then return fail("unsafe archive path") end
        if entry.mode ~= "file" and entry.mode ~= "directory" then
            return fail("unsupported archive entry")
        end
        if entry.mode == "file" then
            total = total + math.max(0, tonumber(entry.size) or 0)
            if total > Install.MAX_ARCHIVE_BYTES then return fail("archive too large") end
        end
        if not reader:extractToPath(entry.path, staging .. "/" .. entry.path) then
            return fail(reader.err or "archive extraction failed")
        end
    end
    local err = reader.err
    reader:close()
    if err then
        removeTree(staging)
        return nil, err
    end
    return true
end

--- 校验并安装更新包。
---@param archive string ZIP 路径
---@param plugin_root string 当前 book.koplugin 目录
---@param version string 期望版本
---@param expected_sha256 string 下载包 SHA-256
---@return boolean|nil, string|nil
function Install.run(archive, plugin_root, version, expected_sha256)
    plugin_root = tostring(plugin_root or ""):gsub("/+$", "")
    expected_sha256 = tostring(expected_sha256 or ""):lower()
    if plugin_root == "" or not lfs.attributes(plugin_root, "mode") then
        return nil, "plugin directory not found"
    end
    if not expected_sha256:match("^[%da-f]+$") or #expected_sha256 ~= 64 then
        return nil, "invalid update checksum"
    end
    local archive_attr = lfs.attributes(archive)
    if not archive_attr or archive_attr.mode ~= "file" or archive_attr.size <= 0 then
        return nil, "update archive not found"
    end
    if archive_attr.size > Install.MAX_ARCHIVE_BYTES then return nil, "archive too large" end
    local digest, digest_err = fileSha256(archive)
    if not digest then return nil, digest_err end
    if digest:lower() ~= expected_sha256 then return nil, "update checksum mismatch" end

    local parent = plugin_root:match("^(.*)/[^/]+$")
    if not parent then return nil, "invalid plugin directory" end
    local staging = parent .. "/.book.koplugin-update"
    local staged_plugin = staging .. "/book.koplugin"
    local backup = parent .. "/.book.koplugin-backup"
    local ok, err = removeTree(staging)
    if not ok then return nil, err end
    if not lfs.mkdir(staging) then return nil, "cannot create update staging directory" end

    ok, err = extractArchive(archive, staging)
    if not ok then return nil, err end
    local packaged_version
    packaged_version, err = readPackagedVersion(staged_plugin)
    if packaged_version ~= version then
        removeTree(staging)
        return nil, err or "update version mismatch"
    end
    ok, err = validateLuaTree(staged_plugin)
    if not ok then
        removeTree(staging)
        return nil, err
    end

    ok, err = removeTree(backup)
    if not ok then
        removeTree(staging)
        return nil, err
    end
    ok, err = os.rename(plugin_root, backup)
    if not ok then
        removeTree(staging)
        return nil, err or "cannot back up current plugin"
    end
    ok, err = os.rename(staged_plugin, plugin_root)
    if not ok then
        local restored, restore_err = os.rename(backup, plugin_root)
        removeTree(staging)
        if not restored then
            return nil, "install failed and rollback failed: " .. tostring(restore_err)
        end
        return nil, err or "cannot install update"
    end
    removeTree(staging)
    return true
end

return Install
