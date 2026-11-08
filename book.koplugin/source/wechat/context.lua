--[[--
微信读书阅读上下文缓存：按章记住本地 reader 状态（psvts / pclts），以及书籍版本号。

App 进度与时长走 App ``POST /book/read``；Web 在读状态用独立的网页会话。

@module koplugin.book.source.wechat.context
--]]

local Protocol = require("source.wechat.protocol")

local Context = {}

local READER_TTL = 15 * 60

---@class WechatReaderState
---@field psvts string
---@field pclts string
---@field at integer 生成时间
---@field entered boolean|nil 本会话已发过进入阅读上报

---@type table<string, WechatReaderState>
local readers = {}
---@type table<string, WechatReportSession>
local sessions = {}
---@type table<string, number>
local book_version_by_id = {}

---@class WechatReportSession
---@field psvts string
---@field pclts string
---@field token string|nil
---@field built_at integer
---@field entered boolean|nil

local function key(book_id, chapter_uid)
    return tostring(book_id) .. "\31" .. tostring(chapter_uid)
end

--- 该章未过期的 reader 状态，缺失或过期就地生成。
--- psvts 模拟服务端出页时间，pclts 模拟稍后的页面初始化时间；两者在会话内固定：进入阅读与后续时长上报必须共用同一个 pc，每次现算会让服务端不认 rt。
---@param book_id string
---@param chapter_uid string|number
---@return WechatReaderState
function Context.reader(book_id, chapter_uid)
    local k = key(book_id, chapter_uid)
    local state = readers[k]
    local now = os.time()
    if state and now - state.at < READER_TTL then return state end
    state = { psvts = Protocol.encode(now - 1), pclts = Protocol.encode(now), at = now }
    readers[k] = state
    return state
end

--- 获取网页阅读会话；真实 psvts / pclts / token 只用于在读心跳，不用于累计时长。
---@param client WechatClient
---@param book_id string
---@param force boolean|nil
---@param cb fun(session: WechatReportSession|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Context.sessionAsync(client, book_id, force, cb)
    local session = sessions[book_id]
    if session and not force and os.time() - session.built_at < READER_TTL then
        cb(session)
        return nil
    end
    return client:readerStateAsync(book_id, function(state, err)
        if not state then
            cb(nil, err)
            return
        end
        local now = os.time()
        sessions[book_id] = {
            psvts = state.psvts,
            pclts = state.pclts or Protocol.encode(now),
            token = state.token,
            built_at = now,
        }
        cb(sessions[book_id])
    end)
end

---@param book_id string
---@param version number|string|nil
function Context.rememberBookVersion(book_id, version)
    version = tonumber(version)
    if version then
        book_version_by_id[book_id] = version
    end
end

---@param book_id string
---@return number|nil
function Context.bookVersion(book_id)
    return book_version_by_id[book_id]
end

--- 清空进程内缓存的 reader 状态与书籍版本号（换账号或登出后必须调）。
function Context.clear()
    readers = {}
    sessions = {}
    book_version_by_id = {}
end

return Context
