--[[--
微信读书数据源门面（仅异步网络）

@module koplugin.book.source.wechat
--]]

local Auth = require("source.wechat.auth")
local Client = require("source.wechat.client")
local Mapper = require("source.wechat.mapper")
local WChapter = require("source.wechat.chapter")
local SourceBase = require("source.base")
local BookRef = require("types.book").BookRef
local ProgressPosition = require("types.book_progress")
local _ = require("gettext")

local WeChat = {}

--- 返回微信读书源元信息。
---@return BookSourceMeta
function WeChat.meta()
    return { id = "wechat", name = _("微信读书") }
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
        library = true,
        recent = true,
        search = true,
        filters = false,
        detail = true,
        scrape = false,
        cover = true,
        whole_book = false,
        chapters = true,
        progress_pull = true,
        progress_push = true,
        insight = false,
        stats_import = false,
        store = true,
    }
end

--- 是否已登录微信读书。
---@return boolean
function Source:configured()
    return Auth.hasSession()
end

--- 返回微信读书源配置状态。
---@return SourceConfigurationState
function Source:configurationState()
    if Auth.hasSession() then
        return "ready"
    end
    return "needs_login"
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
---@param ref BookRef
---@return BookCoverRequest|nil, string|nil
function Source:coverRequest(ref)
    local url = self._covers[ref.stable_id]
    if type(url) ~= "string" or url == "" then
        return nil, _("无封面")
    end
    return {
        url = url,
        headers = Client.sessionHeaders(),
    }
end

function Source:pingAsync(cb)
    return self._client:pingAsync(function(data, err)
        if not data then
            cb(nil, (type(err) == "table" and err.message) or err)
            return
        end
        if type(data.name) == "string" and data.name ~= "" then
            local MoonSettings = require("utils.settings")
            local c = MoonSettings.getSource("wechat")
            c.user_name = data.name
            MoonSettings.saveSource("wechat", c)
        end
        cb({ ok = true, user = Auth.userLabel() })
    end)
end

function Source:listLibraryAsync(opts, cb)
    opts = opts or {}
    if opts.search and opts.search ~= "" then
        return self:listStoreAsync(opts, cb)
    end
    return self._client:shelfSyncAsync(function(wire, err)
        if wire then
            cb(Mapper.shelfList(wire, function(id, url)
                rememberCover(self, id, url)
            end))
        else
            cb(nil, (type(err) == "table" and err.message) or err)
        end
    end)
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

function Source:recentBooksAsync(limit, cb)
    local cancelled = false
    local first, second
    first = self._client:recentBooksAsync(limit or 8, function(wire, err)
        if cancelled then return end
        if not wire then
            cb(nil, (type(err) == "table" and err.message) or err)
            return
        end
        second = self._client:shelfSyncAsync(function(shelf)
            if cancelled then return end
            local list = Mapper.recentList(wire, shelf, function(id, url)
                rememberCover(self, id, url)
            end)
            if #(list.data or {}) == 0 then
                cb(nil, _("暂无最近阅读"))
            else
                cb(list)
            end
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

function Source:getDetailAsync(ref, cb)
    return self._client:bookInfoAsync(ref.stable_id, function(wire, err)
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
        if cover then rememberCover(self, b.ref.stable_id, cover) end
        cb(b)
    end)
end

function Source:getTocAsync(ref, cb)
    return self._client:chapterInfosAsync(ref.stable_id, function(wire, err)
        if not wire then
            cb(nil, (type(err) == "table" and err.message) or err)
            return
        end
        local chapters, cerr = Mapper.chapters(wire, ref.stable_id)
        if chapters then
            cb(chapters)
        else
            cb(nil, _("章节列表为空"))
        end
    end)
end

function Source:fetchChapterContentAsync(ref, chapter, cb)
    return WChapter.fetchContentAsync(ref.stable_id, chapter, function(payload, err)
        if payload then
            cb(payload)
        else
            cb(nil, (type(err) == "table" and err.message) or err)
        end
    end)
end

function Source:getProgressAsync(ref, cb)
    local cancelled = false
    local first, second
    first = self._client:getProgressAsync(ref.stable_id, function(wire, err)
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
        second = self:getTocAsync(ref, function(toc)
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

function Source:putProgressAsync(ref, pos, cb)
    pos = pos or {}
    local frac = ProgressPosition.clampFraction(pos.fraction)
    local progress = math.max(0, math.min(100, math.floor(frac * 100 + 0.5)))
    local chapter_uid = pos.locator or pos.chapter_idx
    return self._client:putProgressAsync(ref.stable_id, progress, chapter_uid, function(wire, err)
        if wire then
            cb(true)
        else
            cb(nil, (type(err) == "table" and err.message) or err)
        end
    end)
end

return WeChat
