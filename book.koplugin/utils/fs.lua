--[[--
文件系统原语：整文件读取与目录列表。纯 Lua，零 KOReader UI 依赖。

读取与列表的失败都用「没有」表达（nil / 空表），不抛错。

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
