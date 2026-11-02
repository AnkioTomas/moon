--[[--
插件更新包校验与目录换位。

在线更新的包体唯一信任根是调用方传入的 SHA-256（来自 Release 接口给的资产 digest）。
镜像只搬运字节。校验通过即视为 CI 产物原样，不再逐条审查 ZIP 内容。远程管理上传的包没有校验值：上传者本来就能经文件管理改写插件目录，
解压后顶层恰好一个以 .koplugin 结尾的目录就装进插件目录。调用方可经 opts.verify 加自己的体检。
新目录完整解压后才换位；旧目录保留为同级 .<目录名>-backup。

@module koplugin.book.utils.plugin_install
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
---@param parent string 插件目录；新插件装成 <parent>/<名>
---@param expected_sha256 string|nil 小写十六进制 SHA-256；nil = 用户本地上传的包，没有可信校验值
---@param opts { name: string|nil, verify: (fun(name: string, staging: string): string|nil)|nil }|nil
---   name：要求的顶层插件目录名；有校验值时必填，没有时只做一致性检查（缺省取包内唯一的 .koplugin）。
---   verify：解压后、换位前的额外检查，返回错误串即拒绝（插件自己的体检，这里不认识任何具体插件）。
---@return boolean|nil ok
---@return string|nil detail 成功时是插件目录名，失败时是错误
function Install.run(archive, parent, expected_sha256, opts)
    opts = opts or {}
    local ok, err = true, nil
    if expected_sha256 then
        local digest
        digest, err = fileSha256(archive)
        if not digest then return nil, err end
        if digest ~= expected_sha256 then return nil, "update checksum mismatch" end
    end

    -- 暂存目录跟着目标名走：不同插件的更新可以同时在途，互不清掉对方解到一半的包。
    local staging = parent .. "/." .. (opts.name or "upload") .. "-update"
    ok, err = removeTree(staging)
    if ok then ok, err = extract(archive, staging) end

    local name = opts.name
    if ok and not (expected_sha256 and name) then
        local found
        found, err = pluginDir(staging)
        if not found then
            ok = nil
        elseif name and found ~= name then
            ok, err = nil, "not a koplugin archive"
        else
            name = found
        end
    end
    if ok and lfs.attributes(staging .. "/" .. name, "mode") ~= "directory" then
        ok, err = nil, "not a koplugin archive"
    end
    if ok and opts.verify then
        err = opts.verify(name, staging)
        if err then ok = nil end
    end

    local dest = ok and (parent .. "/" .. name)
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
