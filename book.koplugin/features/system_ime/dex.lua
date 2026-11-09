--[[--
dex 安装：运行时校验、私有缓存、原子替换、只读。

Android 14+ 要求动态加载的 dex 在加载时是只读的；上一次运行写好的
`chmod 444` 文件不能直接 `io.open(dest, "wb")` 覆盖，否则会 EACCES，
表现为「重启一次之后系统输入法就再也装不上」。这里统一先写临时文件，
再 rename 原子替换；内容相同则直接复用。

只读取插件目录里的 dex，不联网下载。哈希不符 / 缺失时返回 nil, err，
由上层写 `last_status=not_ready` 并回退内置键盘。

@module koplugin.book.features.system_ime.dex
--]]

local Dex = {}

local CHUNK = 256 * 1024

local function shellQuote(path)
    return "'" .. tostring(path):gsub("'", "'\\''") .. "'"
end

--- 只读权限：Android 14+ 动态代码加载的硬要求。
---@param path string
function Dex.chmod(path)
    pcall(os.execute, "chmod 444 " .. shellQuote(path) .. " 2>/dev/null")
end

--- 校验文件 SHA-256（小写十六进制）。
---@param path string
---@param expected string
---@return boolean|nil ok
---@return string|nil err
function Dex.verify(path, expected)
    if type(expected) ~= "string" or expected == "" then
        return nil, "missing expected sha256"
    end
    local file = io.open(path, "rb")
    if not file then return nil, "dex missing" end
    local ok, sha2 = pcall(require, "ffi/sha2")
    if not ok or type(sha2) ~= "table" or type(sha2.sha256) ~= "function" then
        file:close()
        return nil, "sha256 unavailable"
    end
    local hash = sha2.sha256()
    for chunk in function() return file:read(CHUNK) end do
        hash(chunk)
    end
    file:close()
    local digest = hash()
    if type(digest) ~= "string" or digest:lower() ~= expected:lower() then
        return nil, "sha256 mismatch"
    end
    return true
end

--- 校验来源 dex，复制到目标路径；目标已存在且内容相同时只补 chmod。
---@param source string 插件目录里的 classes.dex
---@param dest string 应用私有 cache 内的副本
---@param expected string 固定哈希
---@return string|nil path
---@return string|nil err
function Dex.stage(source, dest, expected)
    local ok, err = Dex.verify(source, expected)
    if not ok then return nil, err end

    local src = io.open(source, "rb")
    if not src then return nil, "dex missing" end
    local bytes = src:read("*a")
    src:close()
    if not bytes or #bytes == 0 then return nil, "empty dex" end

    local same = false
    local current = io.open(dest, "rb")
    if current then
        same = current:read("*a") == bytes
        current:close()
    end

    if not same then
        local temporary = dest .. ".tmp"
        pcall(os.remove, temporary)
        local out = io.open(temporary, "wb")
        if not out then return nil, "cannot write dex" end
        local wrote = out:write(bytes)
        local closed = out:close()
        if not wrote or not closed then
            pcall(os.remove, temporary)
            return nil, "cannot write dex"
        end
        -- 目标可能是上次留下的 444 文件，部分平台 rename 不覆盖，先删再换。
        pcall(os.remove, dest)
        local renamed, rename_err = os.rename(temporary, dest)
        if not renamed then
            pcall(os.remove, temporary)
            return nil, "cannot replace dex: " .. tostring(rename_err)
        end
    end

    Dex.chmod(dest)
    return dest
end

return Dex
