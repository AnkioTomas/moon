--[[--
阅读模式解析：整书 vs 连续章节。

@module koplugin.book.ui.reader.session.mode
--]]

---@class ReaderSessionModeResolver
local Mode = {}

---@param identity BookIdentity|nil
---@return boolean
function Mode.isChapter(identity)
    -- 阅读形态来自物理路径身份：chapter_idx 存在就是章节文件。
    -- source.type 只是源能力，不能覆盖数据库解析出的文档身份。
    return identity ~= nil and identity.chapter_idx ~= nil
end

return Mode
