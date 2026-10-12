--[[--
微信读书阅读上下文缓存：按章记住 reader 状态（psvts / pclts），供正文拉取、进度与时长上报复用。

网页阅读页里的 psvts 只是出页时间的 encode，token 是固定默认值、pclts 为 0，
所以正文与进度按当前时间本地生成，不为它们下载阅读页（大书阅读页内嵌全书目录，可达数 MB）。
reader 状态模拟一次网页阅读会话；超过 TTL 重新生成，并重新发进入阅读上报。
阅读时长另用 sessionAsync：参数取自真实阅读页，每本书每 15 分钟最多拉一次。

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

---@class WechatReportSession
---@field psvts string
---@field pclts string
---@field token string|nil
---@field built_at integer
---@field entered boolean|nil 本会话已发过进入阅读上报

---@type table<string, WechatReaderState>
local readers = {}
---@type table<string, WechatReportSession>
local sessions = {}
---@type table<string, number>
local book_version_by_id = {}

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

--- 本书的阅读时长上报会话，对齐 weread.koplugin：参数取自真实网页阅读页，按书一份，
--- 自建成起满 TTL（或 force）就重开阅读页重建，重建后要重新进入阅读。
---@param client WechatClient
---@param book_id string
---@param force boolean
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
