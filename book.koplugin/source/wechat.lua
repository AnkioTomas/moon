--[[--
微信读书数据源门面

@module koplugin.book.source.wechat
--]]

local Auth = require("source.wechat.auth")
local Client = require("source.wechat.client")
local Mapper = require("source.wechat.mapper")
local WChapter = require("source.wechat.chapter")
local SourceBase = require("source.base")
local SourceError = require("source.error")
local Contract = require("source.contract")
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

--- 探测微信读书连通性。
---@return table|nil, SourceError|nil
function Source:ping()
    local data, err = self._client:ping()
    if not data then
        return nil, SourceError.wrap(err, Auth.hasSession() and "offline" or "unauthorized")
    end
    if type(data.name) == "string" and data.name ~= "" then
        local MoonSettings = require("utils.settings")
        local c = MoonSettings.getSource("wechat")
        c.user_name = data.name
        MoonSettings.saveSource("wechat", c)
    end
    return { ok = true, user = Auth.userLabel() }
end

--- 清空封面 URL 缓存。
function Source:clearCaches()
    self._covers = {}
end

--- 关闭微信源并清空封面缓存。
function Source:close()
    self._covers = {}
end

--- 列出微信书架书库。
---@param opts BookListOpts|nil
---@return BookListResult|nil, SourceError|nil
function Source:listLibrary(opts)
    opts = opts or {}
    if opts.search and opts.search ~= "" then
        return self:listStore(opts)
    end
    local wire, err = self._client:shelfSync()
    if not wire then
        return nil, SourceError.wrap(err, "offline")
    end
    return Mapper.shelfList(wire, function(id, url)
        rememberCover(self, id, url)
    end)
end

--- 搜索微信书城。
---@param opts BookListOpts|nil
---@return BookListResult|nil, SourceError|nil
function Source:listStore(opts)
    opts = opts or {}
    local wire, err = self._client:search(opts.search or "", opts.page_size, opts.scope)
    if not wire then
        return nil, SourceError.wrap(err, "offline")
    end
    return Mapper.searchList(wire, function(id, url)
        rememberCover(self, id, url)
    end)
end

--- 列出微信最近阅读。
---@param limit number|nil
---@return BookListResult|nil, SourceError|nil
function Source:recentBooks(limit)
    local wire, err = self._client:recentBooks(limit or 8)
    if not wire then
        return nil, SourceError.wrap(err, "offline")
    end
    local shelf = self._client:shelfSync()
    local list = Mapper.recentList(wire, shelf, function(id, url)
        rememberCover(self, id, url)
    end)
    if #(list.data or {}) == 0 then
        return nil, SourceError.not_found(_("暂无最近阅读"))
    end
    return list
end

--- 获取微信书籍详情。
---@param ref BookRef
---@return BookDetail|nil, SourceError|nil
function Source:getDetail(ref)
    local wire, err = self._client:bookInfo(ref.stable_id)
    if not wire then
        return nil, SourceError.wrap(err, "offline")
    end
    local row = wire.book or wire.data or wire
    local b, cover = Mapper.book(row)
    if not b then
        return nil, SourceError.not_found(_("书籍详情为空"))
    end
    if cover then
        rememberCover(self, b.ref.stable_id, cover)
    end
    return b
end

--- 获取微信书籍目录。
---@param ref BookRef
---@return BookChapter[]|nil, SourceError|nil
function Source:getToc(ref)
    local wire, err = self._client:chapterInfos(ref.stable_id)
    if not wire then
        return nil, SourceError.wrap(err, "offline")
    end
    local chapters, cerr = Mapper.chapters(wire, ref.stable_id)
    if not chapters then
        return nil, SourceError.not_found(_("章节列表为空"), cerr)
    end
    return chapters
end

--- 将章节内容落盘到临时路径。
---@param ref BookRef
---@param chapter BookChapter
---@param temp_path string
---@return boolean|nil, SourceError|nil
function Source:materializeChapter(ref, chapter, temp_path)
    local ok, err = WChapter.ensure(ref.stable_id, chapter.idx, temp_path, chapter)
    if not ok then
        return nil, SourceError.wrap(err, "io")
    end
    return true
end

--- 拉取微信阅读进度。
---@param ref BookRef
---@return ProgressPosition|nil, SourceError|nil
function Source:getProgress(ref)
    local wire, err = self._client:getProgress(ref.stable_id)
    if not wire then
        return nil, SourceError.wrap(err, "offline")
    end
    local pos, chapter_uid = Mapper.progress(wire)
    if not pos then
        return nil, SourceError.not_found(_("进度为空"))
    end
    if chapter_uid and not pos.chapter_idx then
        local toc = self:getToc(ref)
        if toc then
            for _, ch in ipairs(toc) do
                if tostring(ch.uid) == tostring(chapter_uid) then
                    pos.chapter_idx = ch.idx
                    break
                end
            end
        end
    end
    return pos
end

--- 上报微信阅读进度。
---@param ref BookRef
---@param pos ProgressPosition
---@return boolean|nil, SourceError|nil
function Source:putProgress(ref, pos)
    pos = pos or {}
    local frac = Contract.clampFraction(pos.fraction)
    local progress = math.max(0, math.min(100, math.floor(frac * 100 + 0.5)))
    local chapter_uid = pos.locator or pos.chapter_idx
    local wire, err = self._client:putProgress(ref.stable_id, progress, chapter_uid)
    if not wire then
        return nil, SourceError.wrap(err, "offline")
    end
    return true
end

--- 构造微信封面请求。
---@param ref BookRef
---@return BookCoverRequest|nil, SourceError|nil
function Source:coverRequest(ref)
    local url = self._covers[ref.stable_id]
    if type(url) ~= "string" or url == "" then
        local detail = self:getDetail(ref)
        if detail and type(detail.cover) == "string" then
            url = detail.cover
            rememberCover(self, ref.stable_id, url)
        end
    end
    if type(url) ~= "string" or url == "" then
        return nil, SourceError.not_found(_("无封面"))
    end
    return {
        url = url,
        headers = Client.sessionHeaders(),
    }
end

return WeChat
