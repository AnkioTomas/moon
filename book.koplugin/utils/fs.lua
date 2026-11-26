--[[--
文件系统原语：整文件读写、递归删除、目录列表、分区用量。纯 Lua，零 KOReader UI 依赖。

读取与列表的失败都用「没有」表达（nil / 空表），不抛错；写与删返回 ok, err。

@module koplugin.book.utils.fs
--]]

local Fs = {}

--- 读整个文件（二进制）。
---@param path string
---@return string|nil 打不开返回 nil
function Fs.read(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end

--- 原子写整个文件：先写 `<path>.part`，close 成功再 rename，半截文件不会顶替旧文件。
---@param path string
---@param data string
---@return boolean|nil ok, string|nil err
function Fs.write(path, data)
    local tmp = path .. ".part"
    local file, err = io.open(tmp, "wb")
    if not file then return nil, err end
    local ok, write_err = file:write(data)
    local closed, close_err = file:close()
    if not (ok and closed) then
        os.remove(tmp)
        return nil, write_err or close_err
    end
    local renamed, rename_err = os.rename(tmp, path)
    if not renamed then
        os.remove(tmp)
        return nil, rename_err
    end
    return true
end

--- 递归删除，不跟随软链接（链接只删链接本身）。路径不存在算成功。
---@param path string
---@return boolean|nil ok, string|nil err
function Fs.removeTree(path)
    local lfs = require("libs/libkoreader-lfs")
    local attr = lfs.symlinkattributes(path)
    if not attr then return true end
    if attr.mode ~= "directory" then return os.remove(path) end
    local ok, iter, state = pcall(lfs.dir, path)
    if not ok then return nil, "cannot open " .. path end
    for name in iter, state do
        if name ~= "." and name ~= ".." then
            local removed, err = Fs.removeTree(path .. "/" .. name)
            if not removed then return nil, err end
        end
    end
    return lfs.rmdir(path)
end

--- path 所在分区用量（字节）。旧版 KOReader 的 df 没有 available，用 free 代替；取不到返回 nil。
---@param path string
---@return { total: number, used: number, available: number }|nil
function Fs.disk(path)
    local total, free, available = require("ffi/util").df(path)
    if not total then return nil end
    return { total = total, used = total - free, available = available or free }
end

--- 目录下的名字（不含 . / ..），升序。目录不存在返回空表。
---@param path string
---@return string[]
function Fs.list(path)
    local lfs = require("libs/libkoreader-lfs")
    local ok, iter, state = pcall(lfs.dir, path)
    local out = {}
    if not ok then return out end
    for name in iter, state do
        if name ~= "." and name ~= ".." then out[#out + 1] = name end
    end
    table.sort(out)
    return out
end

return Fs
