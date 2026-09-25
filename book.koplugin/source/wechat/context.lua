--[[--
微信读书阅读上下文缓存：读阅读页时记住 reader 状态（psvts / pclts / token），
供正文拉取、进度与时长上报复用。

reader 状态属于一次网页阅读会话，服务端会过期；超过 TTL 视为未缓存，调用方重读阅读页。

@module koplugin.book.source.wechat.context
--]]

local Context = {}

local READER_TTL = 15 * 60

---@class WechatReaderState
---@field psvts string
---@field pclts string|nil
---@field token string|nil
---@field at integer 读到阅读页的时间
---@field entered boolean|nil 本会话已发过进入阅读上报

---@type table<string, WechatReaderState>
local readers = {}
---@type table<string, number>
local book_version_by_id = {}

local function key(book_id, chapter_uid)
    return tostring(book_id) .. "\31" .. tostring(chapter_uid)
end

--- 记住阅读页 reader 状态；缺 psvts 的状态不可用，直接忽略。
---@param book_id string
---@param chapter_uid string|number
---@param state { psvts: string|nil, pclts: string|nil, token: string|nil }|nil
function Context.rememberReader(book_id, chapter_uid, state)
    if type(state) ~= "table" or type(state.psvts) ~= "string" or state.psvts == "" then return end
    readers[key(book_id, chapter_uid)] = {
        psvts = state.psvts,
        pclts = state.pclts,
        token = state.token,
        at = os.time(),
    }
end

--- 未过期的 reader 状态。
---@param book_id string
---@param chapter_uid string|number|nil
---@return WechatReaderState|nil
function Context.reader(book_id, chapter_uid)
    if not chapter_uid then return nil end
    local state = readers[key(book_id, chapter_uid)]
    if state and os.time() - state.at < READER_TTL then return state end
    return nil
end

---@param book_id string
---@param chapter_uid string|number|nil
---@return string|nil
function Context.psvts(book_id, chapter_uid)
    local state = Context.reader(book_id, chapter_uid)
    return state and state.psvts
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

--- 清空进程内缓存的 reader 状态与书籍版本号（换账号或登出后必须调）。
function Context.clear()
    readers = {}
    book_version_by_id = {}
end

return Context
