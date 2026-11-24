--[[--
Kindle 用户存储根目录上的崩溃转储与 Indexer 诊断文件。

只扫描 Kindle 设备 `Device.home_dir`（官方为 `/mnt/us`）的顶层，不递归子目录、
不跟随符号链接、不把普通 `*.txt` / `*.core` 算进来。不自动删除。

目录、越界路径和已替换的文件都不能删。测试可注入 roots，避免碰到真实设备。

@module koplugin.book.features.storage.dumps
--]]

require("l10n").apply()

local _ = require("gettext")
local lfs = require("libs/libkoreader-lfs")

local Dumps = {}

--- 测试注入的扫描根；生产代码不要设。
Dumps._roots = nil

---@param name string
---@return boolean
function Dumps.isIndexerName(name)
    return type(name) == "string" and name:match("^Indexer_Dump_%d+%.txt$") ~= nil
end

---@param name string
---@return boolean
function Dumps.isCoreName(name)
    return type(name) == "string" and name:match("^cvm_%d+_[%w._%-]+%.core$") ~= nil
end

--- 只认这两种已知文件名，不接受路径分隔或相对段。
---@param name string
---@return boolean
function Dumps.isDumpName(name)
    if type(name) ~= "string" or name == "" then return false end
    if name:find("/", 1, true) or name:find("\\", 1, true) or name == "." or name == ".." then
        return false
    end
    return Dumps.isIndexerName(name) or Dumps.isCoreName(name)
end

local function trimSlash(path)
    if type(path) ~= "string" then return nil end
    path = path:gsub("/+", "/"):gsub("/$", "")
    if path == "" then return nil end
    return path
end

--- 拒绝明显过宽或系统路径，避免把扫描根扩到整机。
---@param path string|nil
---@return boolean
function Dumps.isSafeRoot(path)
    path = trimSlash(path)
    if not path or path == "/" then return false end
    local banned = {
        ["/mnt"] = true, ["/var"] = true, ["/usr"] = true, ["/etc"] = true,
        ["/tmp"] = true, ["/home"] = true, ["/root"] = true, ["/opt"] = true,
        ["/dev"] = true, ["/proc"] = true, ["/sys"] = true, ["/boot"] = true,
        ["/bin"] = true, ["/sbin"] = true, ["/lib"] = true, ["/lib64"] = true,
    }
    if banned[path] then return false end
    local ok, Paths = pcall(require, "utils.paths")
    if ok and Paths.isMoonPath(path) then return false end
    return true
end

--- Kindle 官方用户存储根：`Device.home_dir`（device.lua 中为 `/mnt/us`）。
--- 非 Kindle 不扫，以免在模拟器或其它设备上误扫家目录。
---@return string[]
function Dumps.defaultRoots()
    if type(Dumps._roots) == "table" then
        local out = {}
        for _idx, root in ipairs(Dumps._roots) do
            root = trimSlash(root)
            if root and Dumps.isSafeRoot(root) then out[#out + 1] = root end
        end
        return out
    end
    local ok, Device = pcall(require, "device")
    if not ok or not Device or type(Device.isKindle) ~= "function" or not Device:isKindle() then
        return {}
    end
    local home = trimSlash(Device.home_dir)
    if not home or not Dumps.isSafeRoot(home) then return {} end
    if lfs.attributes(home, "mode") ~= "directory" then return {} end
    return { home }
end

---@param path string|nil
---@param root string|nil
---@return boolean
function Dumps.isInsideRoot(path, root)
    path, root = trimSlash(path), trimSlash(root)
    if not path or not root then return false end
    local name = path:match("([^/]+)$")
    if not name or path ~= root .. "/" .. name or not Dumps.isDumpName(name) then
        return false
    end
    local ffiUtil = require("ffi/util")
    local real_root = trimSlash(ffiUtil.realpath(root) or root)
    local real_path = ffiUtil.realpath(path)
    if not real_path then
        return true
    end
    real_path = trimSlash(real_path)
    local real_parent = real_path:match("^(.*)/[^/]+$")
    local real_name = real_path:match("([^/]+)$")
    return real_parent == real_root and real_name == name and Dumps.isDumpName(real_name)
end

---@param item table
---@return string
function Dumps.displayPath(item)
    if type(item) ~= "table" then return "" end
    if type(item.name) == "string" and item.name ~= "" then
        return _("设备存储") .. "/" .. item.name
    end
    return item.path or ""
end

local function snapshot(path, root, name, attr)
    return {
        path = path,
        root = root,
        name = name,
        size = tonumber(attr.size) or 0,
        mtime = tonumber(attr.modification) or 0,
        ino = attr.ino,
        dev = attr.dev,
    }
end

--- 同步扫描（给子进程和测试用）。只看根目录顶层普通文件。
---@param roots string[]|nil
---@return { items: table[], total: number, count: number }
function Dumps.scan(roots)
    roots = roots or Dumps.defaultRoots()
    local items, total, seen = {}, 0, {}
    for _idx, root in ipairs(roots) do
        root = trimSlash(root)
        if root and Dumps.isSafeRoot(root) and lfs.attributes(root, "mode") == "directory" then
            local ok, iter, state = pcall(lfs.dir, root)
            if ok and type(iter) == "function" then
                for name in iter, state do
                    if name ~= "." and name ~= ".." and Dumps.isDumpName(name) then
                        local path = root .. "/" .. name
                        if not seen[path] then
                            local link = lfs.symlinkattributes(path)
                            if link and link.mode == "file" then
                                -- mode == "file" 且不是 link：symlinkattributes 对普通文件是 file，对符号链接是 link
                                items[#items + 1] = snapshot(path, root, name, link)
                                total = total + (tonumber(link.size) or 0)
                                seen[path] = true
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(items, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        return a.path < b.path
    end)
    return { items = items, total = total, count = #items }
end

--- 子进程扫描，避免卡 UI。
---@param cb fun(result: table|nil)
---@param roots string[]|nil
---@return { cancel: fun() }
function Dumps.scanAsync(cb, roots)
    roots = roots or Dumps.defaultRoots()
    return require("workers.job").run(function()
        return require("features.storage.dumps").scan(roots)
    end, {
        name = "storage.dumps", kind = "light",
        on_done = cb,
        on_failed = function(err)
            require("utils.log").warn("book storage dumps scan failed", err)
            cb(nil)
        end,
    })
end

--- 删除前重验：仍是范围内的普通文件，且没有被换成别的文件。
---@param item table
---@return string|nil err missing / replaced / not_file / out_of_scope / invalid
function Dumps.verify(item)
    if type(item) ~= "table" or type(item.path) ~= "string" or type(item.name) ~= "string" then
        return "invalid"
    end
    if not Dumps.isDumpName(item.name) then return "invalid" end
    if not Dumps.isInsideRoot(item.path, item.root) then return "out_of_scope" end
    local link = lfs.symlinkattributes(item.path)
    if not link then return "missing" end
    if link.mode == "directory" or link.mode == "link" or link.mode ~= "file" then
        return "not_file"
    end
    local name = item.path:match("([^/]+)$")
    if name ~= item.name or not Dumps.isDumpName(name) then return "replaced" end
    if item.ino ~= nil and link.ino ~= nil and item.ino ~= link.ino then return "replaced" end
    if item.dev ~= nil and link.dev ~= nil and item.dev ~= link.dev then return "replaced" end
    if (tonumber(item.size) or 0) ~= (tonumber(link.size) or 0) then return "replaced" end
    if (tonumber(item.mtime) or 0) ~= (tonumber(link.modification) or 0) then return "replaced" end
    return nil
end

--- 删除单个已校验文件。不会删目录，不会跟随符号链接。
---@param item table
---@return boolean ok
---@return string|nil err
function Dumps.remove(item)
    local err = Dumps.verify(item)
    if err then return false, err end
    local ok = os.remove(item.path)
    local still = lfs.symlinkattributes(item.path)
    if still or not ok then return false, "failed" end
    return true
end

--- 逐项删除，互不影响。
---@param items table[]
---@return { removed: table[], errors: { item: table, err: string }[] }
function Dumps.removeMany(items)
    local removed, errors = {}, {}
    for _idx, item in ipairs(items or {}) do
        local ok, err = Dumps.remove(item)
        if ok then
            removed[#removed + 1] = item
        else
            errors[#errors + 1] = { item = item, err = err or "failed" }
        end
    end
    return { removed = removed, errors = errors }
end

return Dumps
