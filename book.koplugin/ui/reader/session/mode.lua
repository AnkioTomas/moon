--[[--
阅读模式解析：整书 vs 连续章节。

@module koplugin.book.ui.reader.session.mode
--]]

local Store = require("book.store")

local Mode = {}

---@param identity BookIdentity|nil
---@return "book"|"chapter"
function Mode.resolve(identity)
    local source = identity and identity.source
    if source and source.type == "chapter" then
        local toc = Store.toc(identity)
        if toc then
            return "chapter"
        end
    end
    return "book"
end

---@param identity BookIdentity|nil
---@return boolean
function Mode.isChapter(identity)
    return Mode.resolve(identity) == "chapter"
end

return Mode
