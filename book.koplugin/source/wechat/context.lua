--[[--
微信读书阅读上下文缓存：章节正文拉取时记住 psvts，供时长上报复用。

@module koplugin.book.source.wechat.context
--]]

local Context = {}

---@type table<string, string>
local psvts_by_chapter = {}

---@param book_id string
---@param chapter_uid string|number
---@param psvts string|nil
function Context.rememberPsvts(book_id, chapter_uid, psvts)
    if type(psvts) ~= "string" or psvts == "" then return end
    psvts_by_chapter[tostring(book_id) .. "\31" .. tostring(chapter_uid)] = psvts
end

---@param book_id string
---@param chapter_uid string|number|nil
---@return string|nil
function Context.psvts(book_id, chapter_uid)
    if not chapter_uid then return nil end
    return psvts_by_chapter[tostring(book_id) .. "\31" .. tostring(chapter_uid)]
end

function Context.clear()
    psvts_by_chapter = {}
end

return Context
