--[[--
阅读模式解析：整书 vs 连续章节。

@module koplugin.book.ui.reader.session.mode
--]]

local Mode = {}

---@param identity BookIdentity|nil
---@return "book"|"chapter"
function Mode.resolve(identity)
    local source = identity and identity.source
    -- 源类型就是模式契约；目录是否已缓存是数据可用性，不应触发同步
    -- SQLite/JSON 读取，更不能因为缓存暂时缺失把章节书当整书打开。
    if source and source.type == "chapter" then
        return "chapter"
    end
    return "book"
end

---@param identity BookIdentity|nil
---@return boolean
function Mode.isChapter(identity)
    return Mode.resolve(identity) == "chapter"
end

return Mode
