--[[--
锁屏书库公共数据辅助。

@module koplugin.book.lockscreen.components.library
--]]

local MoonSettings = require("utils.settings")
local Paths = require("utils.paths")
local lfs = require("libs/libkoreader-lfs")

local M = {}

--- 展示查询用的源范围（混合模式由 Catalog.libraryScope 展开）。
---@return string|string[]|nil
function M.activeSourceId()
    return require("book.catalog").libraryScope(MoonSettings.activeSourceId())
end

--- 本地封面缓存路径；锁屏不触网，文件不存在就返回 nil 走占位。
---@param stable_id string|nil
---@param source_id string|nil
---@return string|nil
function M.coverPath(stable_id, source_id)
    if type(stable_id) ~= "string" or stable_id == "" then return nil end
    if type(source_id) ~= "string" or source_id == "" then return nil end
    local path = Paths.coverPath(stable_id, source_id)
    return lfs.attributes(path, "mode") == "file" and path or nil
end

--- 把数据库行转成书架格子需要的字段（书名 / 作者 / 进度 / 封面）。
---@param book table 数据库行（混合模式下列内必有 source_id）
---@param source_id string|string[]|nil 行内缺 source_id 时使用；混合模式是源 id 列表
---@return table
function M.shelfBook(book, source_id)
    local stable_id = book.stable_id
    local fallback = type(source_id) == "string" and source_id or nil
    local raw = book.source_id
    local sid = type(raw) == "string" and raw or fallback
    return {
        source_id = sid,
        stable_id = stable_id,
        title = book.title or stable_id or "",
        authors = book.authors or "",
        percent = tonumber(book.percent) or 0,
        cover = M.coverPath(stable_id, sid),
    }
end

--- 书架格子收集器：跨多次调用按 (source_id, stable_id) 去重。
--- 返回的 append 把 rows 转成 shelfBook 追加进 target，target 满 limit 即停。
---@param source_id string|string[]|nil
---@return fun(target: table[], rows: table[]|nil, limit: number, accept: (fun(row: table): boolean)|nil)
function M.shelfCollector(source_id)
    local seen = {}
    return function(target, rows, limit, accept)
        for _, row in ipairs(rows or {}) do
            if #target >= limit then return end
            local id = row.stable_id
            if type(id) == "string" and id ~= "" then
                local key = tostring(row.source_id or source_id) .. "\0" .. id
                if not seen[key] and (not accept or accept(row)) then
                    seen[key] = true
                    target[#target + 1] = M.shelfBook(row, source_id)
                end
            end
        end
    end
end

return M
