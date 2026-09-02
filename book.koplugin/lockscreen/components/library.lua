--[[--
锁屏书库公共数据辅助。

@module koplugin.book.lockscreen.components.library
--]]

local MoonSettings = require("utils.settings")
local Paths = require("utils.paths")
local lfs = require("libs/libkoreader-lfs")

local M = {}

--- 当前数据源 ID；锁屏只展示这一个源的书。
---@return string
function M.activeSourceId()
    return MoonSettings.activeSourceId()
end

--- 本地封面缓存路径；锁屏不触网，文件不存在就返回 nil 走占位。
---@param stable_id string|nil
---@param source_id string|nil
---@return string|nil
function M.coverPath(stable_id, source_id)
    if type(stable_id) ~= "string" or stable_id == "" then return nil end
    local path = Paths.coverPath(stable_id, source_id)
    return lfs.attributes(path, "mode") == "file" and path or nil
end

--- 把数据库行转成书架格子需要的字段（书名 / 作者 / 进度 / 封面）。
---@param book table 数据库行
---@param source_id string 行内缺 source_id 时的兜底
---@return table
function M.shelfBook(book, source_id)
    local stable_id = book.stable_id
    return {
        source_id = source_id,
        stable_id = stable_id,
        title = book.title or stable_id or "",
        authors = book.authors or "",
        percent = tonumber(book.percent) or 0,
        cover = M.coverPath(stable_id, source_id),
    }
end

return M
