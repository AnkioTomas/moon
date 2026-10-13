--[[--
插件更新包校验与目录换位。

包体的唯一信任根是 Release 接口（api.ankio.net 转发的 GitHub API）给的 SHA-256：校验通过即视为 CI 产物原样，
不再逐条审查 ZIP 内容。远程管理上传的包没有校验值：上传者本来就能经文件管理改写插件目录，这里只认包里有月读插件目录。
新目录完整解压后才与当前插件目录换位；旧目录保留为同级 .book.koplugin-backup。

@module koplugin.book.features.update.install
--]]

local lfs = require("libs/libkoreader-lfs")

local Install = {}

local function removeTree(path)
    local attr = lfs.symlinkattributes(path)
    if not attr then return true end
    if attr.mode ~= "directory" then return os.remove(path) end
    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            local ok, err = removeTree(path .. "/" .. name)
            if not ok then return nil, err end
        end
    end
    return lfs.rmdir(path)
end

local function fileSha256(path)
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    local hash = require("ffi/sha2").sha256()
    for chunk in function() return file:read(256 * 1024) end do
        hash(chunk)
    end
    file:close()
    return hash()
end

local function extract(archive, staging)
    if not lfs.mkdir(staging) then return nil, "cannot create update staging directory" end
    local reader = require("ffi/archiver").Reader:new()
    if not reader:open(archive) then return nil, reader.err or "cannot open update archive" end
    local ok = true
    for entry in reader:iterate() do
        ok = reader:extractToPath(entry.path, staging .. "/" .. entry.path)
        if not ok then break end
    end
    local err = reader.err
    reader:close()
    if not ok or err then return nil, err or "archive extraction failed" end
    return true
end

--- 校验并安装更新包（跑在 workers.job 子进程里）。
---@param archive string ZIP 路径
---@param plugin_root string 当前 book.koplugin 目录
---@param expected_sha256 string|nil 小写十六进制 SHA-256；nil = 用户本地上传的包，没有可信校验值
---@return boolean|nil, string|nil
function Install.run(archive, plugin_root, expected_sha256)
    local ok, err
    if expected_sha256 then
        local digest
        digest, err = fileSha256(archive)
        if not digest then return nil, err end
        if digest ~= expected_sha256 then return nil, "update checksum mismatch" end
    end

    local parent = plugin_root:match("^(.*)/[^/]+$")
    local staging = parent .. "/.book.koplugin-update"
    local backup = parent .. "/.book.koplugin-backup"
    ok, err = removeTree(staging)
    if ok then ok, err = extract(archive, staging) end
    -- 换位前认包：上传的任意 ZIP 只要不是月读插件，当前目录一个字节都不动。
    if ok and lfs.attributes(staging .. "/book.koplugin/bookversion.lua", "mode") ~= "file" then
        ok, err = nil, "not a moon plugin archive"
    end
    if ok then ok, err = removeTree(backup) end
    if ok then ok, err = os.rename(plugin_root, backup) end
    if not ok then
        removeTree(staging)
        return nil, err
    end
    -- 包里没有 book.koplugin/ 时这里失败并回滚，当前目录原样恢复。
    ok, err = os.rename(staging .. "/book.koplugin", plugin_root)
    if not ok then
        local restored, restore_err = os.rename(backup, plugin_root)
        removeTree(staging)
        if not restored then return nil, "install failed and rollback failed: " .. tostring(restore_err) end
        return nil, err
    end
    removeTree(staging)
    return true
end

return Install
