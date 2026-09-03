--[[--
阅读模式解析：整书 vs 连续章节。

@module koplugin.book.ui.reader.session.mode
--]]

local Mode = {}

---@param identity BookIdentity|nil
---@return "book"|"chapter"
function Mode.resolve(identity)
    -- 阅读形态来自物理路径身份：chapter_idx 存在就是章节文件。
    -- source.type 只是源能力，不能覆盖数据库解析出的文档身份。
    if identity and identity.chapter_idx ~= nil then
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
