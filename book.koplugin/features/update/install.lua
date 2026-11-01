--[[--
插件更新包校验与目录换位。

包体的唯一信任根是 Release 接口（api.ankio.net 转发的 GitHub API）给的 SHA-256：校验通过即视为 CI 产物原样，
不再逐条审查 ZIP 内容，并且只安装 book.koplugin。远程管理上传的包没有校验值：上传者本来就能经文件管理改写插件目录，
解压后顶层恰好一个以 .koplugin 结尾的目录就装进插件目录（与 book.koplugin 同级）。替换正在跑的 book.koplugin 时仍要有
bookversion.lua，避免空壳盖掉月读。新目录完整解压后才换位；旧目录保留为同级 .<目录名>-backup。

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

--- 暂存根下唯一的插件目录。只认顶层、名字以 .koplugin 结尾的真实目录。
---@param staging string
---@return string|nil name
---@return string|nil err
local function pluginDir(staging)
    local found
    for name in lfs.dir(staging) do
        if name:sub(-#".koplugin") == ".koplugin"
            and lfs.symlinkattributes(staging .. "/" .. name, "mode") == "directory" then
            if found then return nil, "multiple koplugin directories" end
            found = name
        end
    end
    if not found then return nil, "not a koplugin archive" end
    return found
end

--- 校验并安装更新包（跑在 workers.job 子进程里）。
---@param archive string ZIP 路径
---@param plugin_root string 当前 book.koplugin 目录；其它插件装到它的同级
---@param expected_sha256 string|nil 小写十六进制 SHA-256；nil = 用户本地上传的包，没有可信校验值
---@return boolean|nil ok
---@return string|nil detail 成功时是插件目录名，失败时是错误
function Install.run(archive, plugin_root, expected_sha256)
    local ok, err = true, nil
    if expected_sha256 then
        local digest
        digest, err = fileSha256(archive)
        if not digest then return nil, err end
        if digest ~= expected_sha256 then return nil, "update checksum mismatch" end
    end

    local parent = plugin_root:match("^(.*)/[^/]+$")
    local staging = parent .. "/.book.koplugin-update"
    ok, err = removeTree(staging)
    if ok then ok, err = extract(archive, staging) end

    local name
    if ok and expected_sha256 then
        name = "book.koplugin"
        if lfs.attributes(staging .. "/book.koplugin/bookversion.lua", "mode") ~= "file" then
            ok, err = nil, "not a moon plugin archive"
        end
    elseif ok then
        name, err = pluginDir(staging)
        if not name then
            ok = nil
        elseif name == "book.koplugin"
            and lfs.attributes(staging .. "/book.koplugin/bookversion.lua", "mode") ~= "file" then
            ok, err = nil, "not a moon plugin archive"
        end
    end

    -- 月读换掉的是正在跑的这份目录；其它插件是它的同级。
    local dest = ok and (name == "book.koplugin" and plugin_root or parent .. "/" .. name)
    local backup = name and (parent .. "/." .. name .. "-backup")
    local had = ok and lfs.symlinkattributes(dest) ~= nil
    if ok and had then ok, err = removeTree(backup) end
    if ok and had then ok, err = os.rename(dest, backup) end
    if not ok then
        removeTree(staging)
        return nil, err
    end
    ok, err = os.rename(staging .. "/" .. name, dest)
    if not ok then
        local restored, restore_err
        if had then restored, restore_err = os.rename(backup, dest) end
        removeTree(staging)
        if had and not restored then
            return nil, "install failed and rollback failed: " .. tostring(restore_err)
        end
        return nil, err
    end
    removeTree(staging)
    return true, name
end

return Install
