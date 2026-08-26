--[[--
微信读书数据源门面（仅异步网络）

@module koplugin.book.source.wechat
--]]

local Auth = require("source.wechat.auth")
local Client = require("source.wechat.client")
local Mapper = require("source.wechat.mapper")
local WChapter = require("source.wechat.chapter")
local SourceBase = require("source.base")
local ProgressPosition = require("types.book_progress")
local _ = require("gettext")

local TOC_TTL = 6 * 60 * 60

local WeChat = {}

--- 返回微信读书源元信息。
---@return BookSourceMeta
function WeChat.meta()
    return { id = "wechat", name = _("微信读书"), type = "online" }
end

---@class WechatSource : SourceBase
---@field cfg table
---@field _client table
---@field _covers table<string, string>
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

--- 构造微信读书源实例。
---@return WechatSource
function WeChat.new()
    local cfg = require("utils.settings").getSource("wechat")
    local meta = WeChat.meta()
    ---@type WechatSource
    local self = setmetatable({
        id = meta.id,
        name = meta.name,
        type = meta.type,
        cfg = cfg,
        _client = Client:new(cfg),
        _covers = {},
    }, Source)
    return self
end

--- 缓存书籍封面 URL（仅接受 http(s)）。
---@param self WechatSource
---@param stable_id string
---@param url string
local function rememberCover(self, stable_id, url)
    if type(stable_id) == "string" and type(url) == "string" and url:find("^https?://", 1) then
        self._covers[stable_id] = url
    end
end

--- 返回微信读书源能力集。
---@return SourceCapabilities
function Source:capabilities()
    return {
        search = true,
        refresh = true,
        scrape = false,
        insight = true,
        store = true,
    }
end

--- 是否已登录微信读书。
---@return boolean
function Source:configured()
    return Auth.hasSession()
end

--- 清空封面 URL 缓存。
function Source:clearCaches()
    self._covers = {}
end

--- 关闭微信源并清空封面缓存。
function Source:close()
    self._covers = {}
end

--- 构造微信封面请求。
---@param identity BookIdentity
---@return BookCoverRequest|nil, string|nil
function Source:coverRequest(identity)
    local url = self._covers[identity.stable_id]
    if type(url) ~= "string" or url == "" then
        return nil, _("无封面")
    end
    return {
        url = url,
        headers = Client.sessionHeaders(),
    }
end

---@param _opts table|nil
---@param cb fun(result: SyncResult|nil, err: any)
---@return table
function Source:syncBooksAsync(_opts, cb)
    local cancelled, job = false, nil
    job = self._client:shelfSyncAsync(function(wire, err)
        if cancelled then return end
        if wire then
            local list = Mapper.shelfList(wire, function(id, url)
                rememberCover(self, id, url)
            end)
            job = require("book.store").reconcileAsync(self.id, list.data or {}, nil, cb)
        else
            cb(nil, (type(err) == "table" and err.message) or err)
        end
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job:cancel() end
    end }
end

function Source:listStoreAsync(opts, cb)
    opts = opts or {}
    return self._client:searchAsync(opts.search or "", opts.page_size, opts.scope, function(wire, err)
        if wire then
            cb(Mapper.searchList(wire, function(id, url)
                rememberCover(self, id, url)
            end))
        else
            cb(nil, (type(err) == "table" and err.message) or err)
        end
    end)
end

function Source:getDetailAsync(identity, cb)
    return self._client:bookInfoAsync(identity.stable_id, function(wire, err)
        if not wire then
            cb(nil, (type(err) == "table" and err.message) or err)
            return
        end
        local row = wire.book or wire.data or wire
        local b, cover = Mapper.book(row)
        if not b then
            cb(nil, _("书籍详情为空"))
            return
        end
        if cover then rememberCover(self, b.stable_id, cover) end
        cb(b)
    end)
end

local function getTocAsync(self, identity, cb)
    local payload = require("utils.db.toc").get(identity.source_id, identity.stable_id, TOC_TTL)
    if payload then
        local ok, cached = pcall(function() return require("json").decode(payload) end)
        if ok and type(cached) == "table" and #cached > 0 then
            require("ui/uimanager"):nextTick(function() cb(cached) end)
            return
        end
    end
    return self._client:chapterInfosAsync(identity.stable_id, function(wire, err)
        if not wire then
            cb(nil, (type(err) == "table" and err.message) or err)
            return
        end
        local chapters, cerr = Mapper.chapters(wire, identity.stable_id)
        if chapters then
            local ok, encoded = pcall(function() return require("json").encode(chapters) end)
            if ok and encoded then
                require("utils.db.queue").run(function()
                    require("utils.db.toc").upsert(identity.source_id, identity.stable_id, encoded)
                end)
            end
            cb(chapters)
        else
            cb(nil, _("章节列表为空"))
        end
    end)
end

local function fetchChapterContentAsync(_self, identity, chapter, cb)
    return WChapter.fetchContentAsync(identity.stable_id, chapter, function(payload, err)
        if payload then
            cb(payload)
        else
            cb(nil, (type(err) == "table" and err.message) or err)
        end
    end)
end

function Source:openBookAsync(identity, opts, cb)
    return require("source.chapter").openWithUi(self, identity, identity.book, opts, {
        loadToc = function(r, done) return getTocAsync(self, r, done) end,
        fetchContent = function(r, chapter, done)
            return fetchChapterContentAsync(self, r, chapter, done)
        end,
    }, cb)
end

--- 阅读中后台预取后续章节。
---@param identity BookIdentity
---@param toc BookChapter[]
---@param from_idx integer
---@param count integer
---@param cb fun()|nil
---@return { cancel: fun() }
function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    return require("source.chapter").prefetchAsync(identity, identity.book, toc, from_idx, count, {
        fetchContent = function(r, chapter, done)
            return fetchChapterContentAsync(self, r, chapter, done)
        end,
    }, cb)
end

function Source:getProgressAsync(identity, cb)
    local cancelled = false
    local first, second
    first = self._client:getProgressAsync(identity.stable_id, function(wire, err)
        if cancelled then return end
        if not wire then
            cb(nil, (type(err) == "table" and err.message) or err)
            return
        end
        local pos, chapter_uid = Mapper.progress(wire)
        if not pos then
            cb(nil, _("进度为空"))
            return
        end
        if not chapter_uid or pos.chapter_idx then
            cb(pos)
            return
        end
        second = getTocAsync(self, identity, function(toc)
            if cancelled then return end
            for _, ch in ipairs(toc or {}) do
                if tostring(ch.uid) == tostring(chapter_uid) then
                    pos.chapter_idx = ch.idx
                    break
                end
            end
            cb(pos)
        end)
    end)
    return {
        cancel = function()
            cancelled = true
            if first then first.cancel() end
            if second then second.cancel() end
        end,
    }
end

function Source:putProgressAsync(identity, pos, cb)
    pos = pos or {}
    local frac = ProgressPosition.clampFraction(pos.fraction)
    local progress = math.max(0, math.min(100, math.floor(frac * 100 + 0.5)))
    -- 只传显式 chapter_uid：locator 是 XPointer、chapter_idx 是目录序号，都不是微信 chapterUid
    local chapter_uid = pos.chapter_uid
    return self._client:putProgressAsync(identity.stable_id, progress, chapter_uid, function(wire, err)
        if wire then
            cb(true)
        else
            cb(nil, (type(err) == "table" and err.message) or err)
        end
    end)
end

--- 网络恢复后重试已持久化的阅读进度。
---@param event string
function Source:onEvent(event, payload)
    SourceBase.onEvent(self, event, payload)
end

return WeChat
