--[[--
Kindle 用户存储根目录上的崩溃转储与 Indexer 诊断文件。

只扫描 Kindle 设备 `Device.home_dir`（官方为 `/mnt/us`）的顶层，不递归子目录、
不跟随符号链接、不把普通 `*.txt` / `*.core` 算进来。不自动删除。

目录、越界路径和已替换的文件都不能删。测试可注入 roots，避免碰到真实设备。

@module koplugin.book.features.storage.dumps
--]]

local lfs = require("libs/libkoreader-lfs")

local Dumps = {}

--- 测试注入的扫描根；生产代码不要设。
Dumps._roots = nil

--- 只认这两种已知文件名；模式整串锚定，带路径分隔或相对段的名字匹配不上。
---@param name string
---@return boolean
function Dumps.isDumpName(name)
    return name:match("^Indexer_Dump_%d+%.txt$") ~= nil or name:match("^cvm_%d+_[%w._%-]+%.core$") ~= nil
end

---@param path string
---@return string|nil
local function trimSlash(path)
    path = path:gsub("/+", "/"):gsub("/$", "")
    return path ~= "" and path or nil
end

--- Kindle 官方用户存储根：`Device.home_dir`（device.lua 中为 `/mnt/us`）。
--- 非 Kindle 不扫，以免在模拟器或其它设备上误扫家目录。
---@return string[]
function Dumps.defaultRoots()
    if Dumps._roots then return Dumps._roots end
    local Device = require("device")
    if not Device:isKindle() then return {} end
    local home = trimSlash(Device.home_dir)
    if not home or lfs.attributes(home, "mode") ~= "directory" then return {} end
    return { home }
end

---@param path string
---@param root string
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

--- 同步扫描（给子进程和测试用）。只看根目录顶层普通文件。
---@param roots string[]|nil
---@return { items: table[], total: number, count: number }
function Dumps.scan(roots)
    local items, total = {}, 0
    for _idx, root in ipairs(roots or Dumps.defaultRoots()) do
        root = trimSlash(root)
        if root and lfs.attributes(root, "mode") == "directory" then
            for name in lfs.dir(root) do
                local path = root .. "/" .. name
                -- symlinkattributes 对符号链接给 link，只收普通文件
                local link = Dumps.isDumpName(name) and lfs.symlinkattributes(path)
                if link and link.mode == "file" then
                    items[#items + 1] = {
                        path = path, root = root, name = name,
                        size = link.size, mtime = link.modification, ino = link.ino, dev = link.dev,
                    }
                    total = total + link.size
                end
            end
        end
    end
    table.sort(items, function(a, b) return a.path < b.path end)
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
---@param item table scan 给出的条目
---@return string|nil err missing / replaced / not_file / out_of_scope
function Dumps.verify(item)
    if not Dumps.isInsideRoot(item.path, item.root) then return "out_of_scope" end
    local link = lfs.symlinkattributes(item.path)
    if not link then return "missing" end
    if link.mode ~= "file" then return "not_file" end
    if link.ino ~= item.ino or link.dev ~= item.dev or link.size ~= item.size
        or link.modification ~= item.mtime then
        return "replaced"
    end
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
    for _idx, item in ipairs(items) do
        local ok, err = Dumps.remove(item)
        if ok then
            removed[#removed + 1] = item
        else
            errors[#errors + 1] = { item = item, err = err }
        end
    end
    return { removed = removed, errors = errors }
end

return Dumps
