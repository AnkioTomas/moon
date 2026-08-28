--[[--
微信读书阅读上下文缓存：章节正文拉取时记住 psvts，供时长上报复用。

@module koplugin.book.source.wechat.context
--]]

local Context = {}

---@type table<string, string>
local psvts_by_chapter = {}
---@type table<string, number>
local book_version_by_id = {}

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

---@param book_id string
---@param version number|string|nil
function Context.rememberBookVersion(book_id, version)
    version = tonumber(version)
    if version then
        book_version_by_id[tostring(book_id)] = version
    end
end

---@param book_id string
---@return number|nil
function Context.bookVersion(book_id)
    return book_version_by_id[tostring(book_id)]
end

--- 清空进程内缓存的 psvts 与书籍版本号（换账号或登出后必须调）。
function Context.clear()
    psvts_by_chapter = {}
    book_version_by_id = {}
end

return Context
