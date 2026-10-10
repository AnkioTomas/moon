--[[--
核心文件补丁管理器（纯 Lua，零 UI 依赖）。

补丁目录由调用方给出（如 `features/animation/patches`）：其中 `definition.lua`
描述要改哪些文件、在哪个锚点前插入什么，以及要随运行时补丁目录一起分发的静态文件，
静态文件与 definition.lua 同目录。

安装前先备份原文件到 `$DATA/.moon/backups/patches/<definition.name>/`，恢复时从备份
回写。锚点匹配不到或备份缺失时直接失败，绝不猜测写入。

@module koplugin.book.patch.manager
--]]

local Manager = {}

local _install_dir
local _backups_root
local _patches_dir

--- 延迟取 lfs（本模块零 UI 依赖，离线测试才能直接 require）。
---@return table
local function lfs()
    return require("libs/libkoreader-lfs")
end

--- 延迟取 utils.paths。
---@return table
local function paths()
    return require("utils.paths")
end

---@param path string
---@return string|nil content
---@return string|nil err
local function readFile(path)
    local fh, err = io.open(path, "rb")
    if not fh then return nil, err or ("cannot open " .. path) end
    local content = fh:read("*a")
    fh:close()
    return content
end

--- 写临时文件后 rename，避免半写留下损坏文件。
---@param path string
---@param content string
---@return boolean|nil ok
---@return string|nil err
local function writeFile(path, content)
    local dir = path:match("(.+)/[^/]+$")
    if dir then paths().ensureDir(dir) end
    local tmp = path .. ".tmp"
    local fh, err = io.open(tmp, "wb")
    if not fh then return nil, err or ("cannot open " .. tmp) end
    local ok, werr = fh:write(content)
    -- close 也要判：写入走缓冲，磁盘满 / 断电前的 flush 失败只在 close 时报出来。
    -- 不判就会把半截文件 rename 成正式补丁，KOReader 下次启动直接加载坏文件。
    local cok, cerr = fh:close()
    if not ok or not cok then
        os.remove(tmp)
        return nil, werr or cerr or "write failed"
    end
    local rok, rerr = os.rename(tmp, path)
    if not rok then
        os.remove(tmp)
        return nil, rerr
    end
    return true
end

---@param path string
---@return boolean
local function fileExists(path)
    return lfs().attributes(path, "mode") == "file"
end

---@param src string
---@param dst string
---@return boolean|nil ok
---@return string|nil err
local function copyFile(src, dst)
    local content, err = readFile(src)
    if content == nil then return nil, err end
    return writeFile(dst, content)
end

--- 覆盖默认路径，仅供测试注入临时目录隔离副作用；生产环境不调用。
---@param opts table
---   - install_dir string|nil KOReader 安装目录，缺省 lfs.currentdir()
---   - backups_root string|nil 补丁备份根，缺省 $DATA/.moon/backups/patches
---   - patches_dir string|nil 运行时补丁目录，缺省 DataStorage:getPatchesDir()
function Manager.configure(opts)
    _install_dir = opts.install_dir
    _backups_root = opts.backups_root
    _patches_dir = opts.patches_dir
end

--- KOReader 安装目录（被补丁的核心文件所在），未注入时取当前工作目录。
---@return string
local function installDir()
    return _install_dir or lfs().currentdir()
end

--- 某补丁的原文件备份目录。改 definition.name 会找不到已有备份。
---@param name string definition.name
---@return string
local function backupDir(name)
    if _backups_root then
        return _backups_root .. "/" .. name
    end
    return paths().patchBackupDir(name)
end

--- KOReader 运行时补丁目录（静态补丁文件分发到这里）。
---@return string
local function patchesDir()
    return _patches_dir or require("datastorage"):getPatchesDir()
end

--- 加载并校验补丁定义。
---@param dir string 补丁目录（含 definition.lua）
---@return table|nil def
---@return string|nil err
function Manager.loadDefinition(dir)
    local path = dir .. "/definition.lua"
    local chunk, lerr = loadfile(path)
    if not chunk then
        return nil, "cannot load " .. path .. ": " .. tostring(lerr)
    end
    local ok, def = pcall(chunk)
    if not ok then
        return nil, "definition error in " .. path .. ": " .. tostring(def)
    end
    if type(def) ~= "table" then
        return nil, "definition must return a table"
    end
    -- name 拼进备份路径，只许安全字符。
    if type(def.name) ~= "string" or def.name == "" or def.name:find("[^%w%._%-]") then
        return nil, "invalid definition.name: " .. tostring(def.name)
    end
    def.files = type(def.files) == "table" and def.files or {}
    def.patches = type(def.patches) == "table" and def.patches or {}
    for _idx, f in ipairs(def.files) do
        if type(f.path) ~= "string" or f.path == "" then
            return nil, "file.path required"
        end
        if type(f.anchor) ~= "string" or f.anchor == "" then
            return nil, "file.anchor required"
        end
        if type(f.sentinel) ~= "string" or f.sentinel == "" then
            return nil, "file.sentinel required"
        end
        if type(f.content) ~= "string" then
            return nil, "file.content required"
        end
    end
    return def
end

--- 安装补丁：先备份，再按锚点插入，最后分发运行时补丁文件。
---@param dir string 补丁目录（含 definition.lua）
---@return table { ok = true, changed = boolean } | { ok = false, err = string }
function Manager.install(dir)
    local def, derr = Manager.loadDefinition(dir)
    if not def then return { ok = false, err = derr } end

    -- 先只读校验，任何一处不满足都不落盘。
    local targets = {}
    local changed = false
    for _idx, f in ipairs(def.files) do
        local path = installDir() .. "/" .. f.path
        local content, rerr = readFile(path)
        if content == nil then
            return { ok = false, err = "cannot read " .. path .. ": " .. tostring(rerr) }
        end
        local needs = not content:find(f.sentinel, 1, true)
        if needs then
            if not content:find(f.anchor, 1, true) then
                return { ok = false, err = "anchor not found in " .. path }
            end
            changed = true
        end
        targets[#targets + 1] = { f = f, path = path, content = content, needs = needs }
    end

    for _idx, name in ipairs(def.patches) do
        local src = dir .. "/" .. name
        if not fileExists(src) then
            return { ok = false, err = "missing patch payload: " .. dir .. "/" .. name }
        end
        -- 只看存在会把旧负载冻死：源文件改过也永远不重拷。
        if readFile(src) ~= readFile(patchesDir() .. "/" .. name) then
            changed = true
        end
    end

    if not changed then
        return { ok = true, changed = false }
    end

    local bdir = backupDir(def.name)

    -- 备份永远是「未打补丁时的基线」；目标当前未打补丁就刷新为当前内容，
    -- 这样 KOReader 升级覆盖后重新安装时，备份跟随新基线。
    for _idx, t in ipairs(targets) do
        if t.needs then
            local ok, berr = writeFile(bdir .. "/" .. t.f.path, t.content)
            if not ok then
                return { ok = false, err = "backup failed: " .. tostring(berr) }
            end
        end
    end

    for _idx, t in ipairs(targets) do
        if t.needs then
            local pos = t.content:find(t.f.anchor, 1, true)
            local new_content = t.content:sub(1, pos - 1) .. t.f.content .. "\n" .. t.content:sub(pos)
            local ok, werr = writeFile(t.path, new_content)
            if not ok then
                return { ok = false, err = "write failed: " .. tostring(werr)
                    .. Manager._rollbackInstall(def, targets) }
            end
        end
    end

    for _idx, name in ipairs(def.patches) do
        local ok, cerr = copyFile(dir .. "/" .. name, patchesDir() .. "/" .. name)
        if not ok then
            return { ok = false, err = "copy failed: " .. tostring(cerr)
                .. Manager._rollbackInstall(def, targets) }
        end
    end

    return { ok = true, changed = true }
end

--- 安装中途失败时尽力回滚：恢复文件基线并清掉已分发的补丁文件。
---@param def table
---@param targets table
---@return string suffix 拼在安装错误后；回滚全部成功时为空串，否则列出需手动恢复的文件
function Manager._rollbackInstall(def, targets)
    local failed = {}
    for _idx, t in ipairs(targets) do
        if t.needs then
            local backup = readFile(backupDir(def.name) .. "/" .. t.f.path)
            local ok, werr = backup ~= nil, "backup missing"
            if ok then ok, werr = writeFile(t.path, backup) end
            if not ok then failed[#failed + 1] = t.f.path .. " (" .. tostring(werr) .. ")" end
        end
    end
    for _idx, name in ipairs(def.patches) do
        os.remove(patchesDir() .. "/" .. name)
    end
    if #failed == 0 then return "" end
    return "; rollback failed, restore manually: " .. table.concat(failed, ", ")
end

--- 恢复补丁：仅当目标仍带补丁标记时从备份回写；已失效（如升级被覆盖）则不
--- 用陈旧备份覆盖新文件，只清理运行时补丁文件。
---@param dir string 补丁目录（含 definition.lua）
---@return table { ok = true } | { ok = false, err = string }
function Manager.restore(dir)
    local def, derr = Manager.loadDefinition(dir)
    if not def then return { ok = false, err = derr } end

    local bdir = backupDir(def.name)
    for _idx, f in ipairs(def.files) do
        local path = installDir() .. "/" .. f.path
        local content, rerr = readFile(path)
        if content == nil then
            return { ok = false, err = "cannot read " .. path .. ": " .. tostring(rerr) }
        end
        if content:find(f.sentinel, 1, true) then
            local backup = readFile(bdir .. "/" .. f.path)
            if backup == nil then
                return { ok = false, err = "no backup for " .. path }
            end
            local ok, werr = writeFile(path, backup)
            if not ok then
                return { ok = false, err = "restore failed: " .. tostring(werr) }
            end
        end
    end

    for _idx, name in ipairs(def.patches) do
        os.remove(patchesDir() .. "/" .. name)
    end

    return { ok = true }
end

--- 补丁当前是否完整安装。
---@param dir string 补丁目录（含 definition.lua）
---@return boolean
function Manager.isApplied(dir)
    local def = Manager.loadDefinition(dir)
    if not def then return false end
    for _idx, f in ipairs(def.files) do
        local content = readFile(installDir() .. "/" .. f.path)
        if content == nil or not content:find(f.sentinel, 1, true) then
            return false
        end
    end
    for _idx, name in ipairs(def.patches) do
        if not fileExists(patchesDir() .. "/" .. name) then
            return false
        end
    end
    return true
end

return Manager
