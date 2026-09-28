--[[--
Kindle 书目条目 → Book。

@module koplugin.book.source.kindle.mapper
--]]

local Mapper = {}

--- 不可读条目（仅云端、受 DRM 保护的 MOBI、未知格式）返回 nil，不进书架。
---@param kbook table kindle.koplugin ccdb_scanner 条目
---@param path string|nil 已可直接打开的物理路径
---@return Book|nil
function Mapper.book(kbook, path)
    if kbook.open_mode == "blocked" then
        return nil
    end
    local authors = table.concat(kbook.authors or {}, ", ")
    return {
        source_id = "kindle",
        stable_id = kbook.id,
        title = kbook.title,
        authors = authors ~= "" and authors or nil,
        path = path,
    }
end

return Mapper
