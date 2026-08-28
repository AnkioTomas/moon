--[[--
核心文件补丁管理器（纯 Lua，零 UI 依赖）。

按功能组织补丁：`patches/<feature>/definition.lua` 描述要改哪些文件、在哪个
锚点前插入什么，以及要随运行时补丁目录一起分发的静态文件。

安装前先备份原文件到 `$DATA/.moon/backups/patches/<feature>/`，恢复时从备份
回写。锚点匹配不到或备份缺失时直接失败，绝不猜测写入。

@module koplugin.book.patch.manager
--]]

local Manager = {}

local _plugin_root
local _install_dir
local _backups_root
local _patches_dir

--- 延迟取 lfs（本模块零 UI 依赖，离线测试才能直接 require）。
---@return table
local function lfs()
    return require("libs/libkoreader-lfs")
end

--- 延迟取 DataStorage。
---@return table
local function dataStorage()
    return require("datastorage")
end

--- 延迟取 utils.paths。
---@return table
local function paths()
    return require("utils.paths")
end

--- 递归创建目录（已存在则跳过）。
---@param path string|nil
---@return nil
local function ensureDir(path)
    if not path or path == "" then return end
    if lfs().attributes(path, "mode") == "directory" then return end
    local parent = path:match("(.+)/[^/]+/?$")
    if parent and parent ~= "" and parent ~= path then
        ensureDir(parent)
    end
    lfs().mkdir(path)
end

---@param path string
---@return string|nil content
---@return string|nil err
local function readFile(path)
    local fh, err = io.open(path, "rb")
    if not fh then return nil, err or "cannot open " .. path end
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
    if dir then ensureDir(dir) end
    local tmp = path .. ".tmp"
    local fh, err = io.open(tmp, "wb")
    if not fh then return nil, err or "cannot open " .. tmp end
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
    if content == nil then return nil, err or "cannot read " .. src end
    return writeFile(dst, content)
end

--- 初始化路径来源。生产环境只传 plugin_root，其余走 KOReader 默认路径；
--- 测试可注入临时目录隔离副作用。
---@param opts table|nil
---   - plugin_root string 插件根目录（含 patches/<feature>/）
---   - install_dir string|nil KOReader 安装目录，缺省 lfs.currentdir()
---   - backups_root string|nil 补丁备份根，缺省 $DATA/.moon/backups/patches
---   - patches_dir string|nil 运行时补丁目录，缺省 DataStorage:getPatchesDir()
---@return nil
function Manager.init(opts)
    opts = opts or {}
    _plugin_root = opts.plugin_root
    _install_dir = opts.install_dir
    _backups_root = opts.backups_root
    _patches_dir = opts.patches_dir
end

--- KOReader 安装目录（被补丁的核心文件所在），未注入时取当前工作目录。
---@return string
local function installDir()
    return _install_dir or lfs().currentdir()
end

--- 某功能的原文件备份目录。
---@param feature string 功能名（patches/ 下的子目录名）
---@return string
local function backupDir(feature)
    if _backups_root then
        return _backups_root .. "/" .. feature
    end
    return paths().patchBackupDir(feature)
end

--- KOReader 运行时补丁目录（静态补丁文件分发到这里）。
---@return string
local function patchesDir()
    return _patches_dir or dataStorage():getPatchesDir()
end

--- 功能目录：<plugin_root>/patches/<feature>
---@param feature string
---@return string
local function featureDir(feature)
    if not _plugin_root then
        error("patch.manager: plugin_root not initialized", 2)
    end
    return _plugin_root .. "/patches/" .. feature
end

--- 加载并校验功能定义。
---@param feature string
---@return table|nil def
---@return string|nil err
function Manager.loadDefinition(feature)
    if type(feature) ~= "string" or feature == "" or feature:find("[^%w%._%-]") then
        return nil, "invalid feature name: " .. tostring(feature)
    end
    local path = featureDir(feature) .. "/definition.lua"
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
    if type(def.name) ~= "string" or def.name == "" then
        return nil, "definition.name required"
    end
    if def.name ~= feature then
        return nil, "definition.name mismatch: " .. def.name .. " ~= " .. feature
    end
    def.files = type(def.files) == "table" and def.files or {}
    def.patches = type(def.patches) == "table" and def.patches or {}
    for _, f in ipairs(def.files) do
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
---@param feature string
---@return table { ok = true, changed = boolean } | { ok = false, err = string }
function Manager.install(feature)
    local def, derr = Manager.loadDefinition(feature)
    if not def then return { ok = false, err = derr } end

    -- 先只读校验，任何一处不满足都不落盘。
    local targets = {}
    local changed = false
    for _, f in ipairs(def.files) do
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

    for _, name in ipairs(def.patches) do
        if not fileExists(featureDir(feature) .. "/" .. name) then
            return { ok = false, err = "missing patch payload: " .. feature .. "/" .. name }
        end
        if not fileExists(patchesDir() .. "/" .. name) then
            changed = true
        end
    end

    if not changed then
        return { ok = true, changed = false }
    end

    local bdir = backupDir(feature)

    -- 备份永远是「未打补丁时的基线」；目标当前未打补丁就刷新为当前内容，
    -- 这样 KOReader 升级覆盖后重新安装时，备份跟随新基线。
    for _, t in ipairs(targets) do
        if t.needs then
            local ok, berr = writeFile(bdir .. "/" .. t.f.path, t.content)
            if not ok then
                return { ok = false, err = "backup failed: " .. tostring(berr) }
            end
        end
    end

    for _, t in ipairs(targets) do
        if t.needs then
            local pos = t.content:find(t.f.anchor, 1, true)
            local new_content = t.content:sub(1, pos - 1) .. t.f.content .. "\n" .. t.content:sub(pos)
            local ok, werr = writeFile(t.path, new_content)
            if not ok then
                Manager._rollbackInstall(feature, def, targets)
                return { ok = false, err = "write failed: " .. tostring(werr) }
            end
        end
    end

    for _, name in ipairs(def.patches) do
        local ok, cerr = copyFile(featureDir(feature) .. "/" .. name, patchesDir() .. "/" .. name)
        if not ok then
            Manager._rollbackInstall(feature, def, targets)
            return { ok = false, err = "copy failed: " .. tostring(cerr) }
        end
    end

    return { ok = true, changed = true }
end

--- 安装中途失败时尽力回滚：恢复文件基线并清掉已分发的补丁文件。
---@param feature string
---@param def table
---@param targets table
---@return nil
function Manager._rollbackInstall(feature, def, targets)
    for _, t in ipairs(targets) do
        if t.needs then
            local backup = readFile(backupDir(feature) .. "/" .. t.f.path)
            if backup ~= nil then
                writeFile(t.path, backup)
            end
        end
    end
    for _, name in ipairs(def.patches) do
        os.remove(patchesDir() .. "/" .. name)
    end
end

--- 恢复补丁：仅当目标仍带补丁标记时从备份回写；已失效（如升级被覆盖）则不
--- 用陈旧备份覆盖新文件，只清理运行时补丁文件。
---@param feature string
---@return table { ok = true } | { ok = false, err = string }
function Manager.restore(feature)
    local def, derr = Manager.loadDefinition(feature)
    if not def then return { ok = false, err = derr } end

    local bdir = backupDir(feature)
    for _, f in ipairs(def.files) do
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

    for _, name in ipairs(def.patches) do
        os.remove(patchesDir() .. "/" .. name)
    end

    return { ok = true }
end

--- 补丁当前是否完整安装。
---@param feature string
---@return boolean
function Manager.isApplied(feature)
    local def = Manager.loadDefinition(feature)
    if not def then return false end
    for _, f in ipairs(def.files) do
        local content = readFile(installDir() .. "/" .. f.path)
        if content == nil or not content:find(f.sentinel, 1, true) then
            return false
        end
    end
    for _, name in ipairs(def.patches) do
        if not fileExists(patchesDir() .. "/" .. name) then
            return false
        end
    end
    return true
end

return Manager
