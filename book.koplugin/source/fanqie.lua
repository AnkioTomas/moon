--[[--
番茄小说官方数据源。

@module koplugin.book.source.fanqie
--]]

local Base = require("source.base")

local M = {}
local Source = setmetatable({}, { __index = Base })
Source.__index = Source

function M.meta()
    return { id = "fanqie", name = "番茄小说", type = "chapter" }
end

function M.new()
    local Settings = require("source.fanqie.settings")
    local Client = require("source.fanqie.client")
    local settings = Settings:new()
    return setmetatable({
        id = "fanqie",
        name = "番茄小说",
        type = "chapter",
        settings = settings,
        client = Client:new(settings),
    }, Source)
end

function Source:configured()
    local Settings = require("source.fanqie.settings")
    self.settings = Settings:new()
    self.client.settings = self.settings
    return self.settings:is_cookie_configured()
end

function Source:capabilities()
    return { refresh = true, insight = true }
end

---@return { cancel: fun(), job: any, cancelled: boolean }
local function handle()
    local h = { job = nil, cancelled = false }
    function h.cancel()
        h.cancelled = true
        if h.job and h.job.cancel then
            h.job.cancel()
        end
    end
    return h
end

---@param err any
---@return string
local function errMsg(err)
    if type(err) == "table" then
        return tostring(err.message or err.err or "番茄请求失败")
    end
    return tostring(err or "番茄请求失败")
end

--- 旧 fanqie.koplugin 封面：DataStorage/fanqie/cache/covers/<title>.jpg → .moon/cache
---@param title string
---@param stable_id string
local function migrateLegacyCover(title, stable_id)
    local Paths = require("utils.paths")
    local target = Paths.coverPath(stable_id, "fanqie")
    if require("libs/libkoreader-lfs").attributes(target, "size") then return end
    local ok_ds, DS = pcall(require, "datastorage")
    if not ok_ds or type(DS) ~= "table" then return end
    local ok_dir, root = pcall(function() return DS:getFullDataDir() end)
    if not ok_dir or type(root) ~= "string" then return end
    local old_cover = root
        .. "/fanqie/cache/covers/"
        .. title:gsub('[/\\:%*%?"<>|]', "_")
        .. ".jpg"
    local input = io.open(old_cover, "rb")
    if not input then return end
    local bytes = input:read("*a")
    input:close()
    local output = io.open(target, "wb")
    if not output then return end
    output:write(bytes)
    output:close()
end

function Source:syncBooksAsync(opts, cb)
    opts = opts or {}
    -- 番茄暂无书架删/加推送；dirty_only 不得全量 pull。
    if opts.dirty_only then
        require("ui/uimanager"):nextTick(function()
            cb({
                pulled = 0, pushed = 0, hidden = 0, conflicts = 0,
                skipped = true, reason = "no dirty shelf push",
            })
        end)
        return { cancel = function() end }
    end
    local Settings = require("source.fanqie.settings")
    local Client = require("source.fanqie.client")
    self.settings = Settings:new()
    self.client = Client:new(self.settings)
    if not self:configured() then
        cb(nil, "请在数据源设置中扫码登录番茄小说")
        return { cancel = function() end }
    end

    local h = handle()
    h.job = self.client:fetchShelfDetailAsync(opts.force, function(wire, err)
        if h.cancelled then return end
        if not wire then
            cb(nil, errMsg(err))
            return
        end
        local rows = wire.data and wire.data.detail_list
        if type(rows) ~= "table" then
            cb(nil, "番茄书架响应不完整，保留本地书架")
            return
        end
        require("utils.paths").ensureLayout("fanqie")
        local books = {}
        for _, row in ipairs(rows) do
            local id = row.book_id or row.bookId or row.id
            if id then
                local title = row.book_name or row.title or row.name or "未知"
                migrateLegacyCover(title, tostring(id))
                books[#books + 1] = {
                    source_id = "fanqie",
                    stable_id = tostring(id),
                    title = title,
                    authors = row.author_name or row.author or "",
                    intro = row.description or row.desc or row.abstract or "",
                    cover = row.thumb_url or row.coverUrl or row.cover or row.cover_url,
                }
            end
        end
        local result, reason = require("book.store").reconcile(self.id, books)
        cb(result, reason)
    end)
    return h
end

function Source:coverRequest(identity)
    local book = identity.book or require("db.book").get(self.id, identity.stable_id)
    if book and type(book.cover) == "string" and book.cover:match("^https?://") then
        return { url = book.cover }
    end
    return nil, "暂无封面"
end

function Source:getDetailAsync(identity, cb)
    local cancelled = false
    require("ui/uimanager"):nextTick(function()
        if not cancelled then
            cb(identity.book or require("db.book").get(self.id, identity.stable_id))
        end
    end)
    return { cancel = function() cancelled = true end }
end

function Source:loadTocAsync(identity, cb)
    local Toc = require("source.fanqie.toc")
    local Content = require("source.fanqie.content")
    local cached = Toc.read(self.id, identity.stable_id)
    if cached and #cached > 0 then
        require("ui/uimanager"):nextTick(function() cb(cached) end)
        return { cancel = function() end }
    end
    local h = handle()
    h.job = self.client:fetchChapterDirectoryAsync(identity.stable_id, function(wire, err)
        if h.cancelled then return end
        if not wire then
            cb(nil, errMsg(err))
            return
        end
        local rows = Content.readable_chapters(
            Content.normalize_chapters(wire, identity.stable_id))
        local toc = {}
        for _, row in ipairs(rows) do
            local uid = row.itemId or row.item_id
            if uid then
                toc[#toc + 1] = {
                    idx = #toc + 1,
                    uid = tostring(uid),
                    title = row.title or row.item_title or ("第" .. (#toc + 1) .. "章"),
                }
            end
        end
        if #toc == 0 then
            cb(nil, "番茄目录为空")
            return
        end
        Toc.put(self.id, identity.stable_id, toc)
        cb(toc)
    end)
    return h
end

local function fetch(self, identity, chapter, cb)
    local Content = require("source.fanqie.content")
    local h = handle()
    h.job = self.client:officialGetContentAsync(identity.stable_id, chapter.uid, function(result, err)
        if h.cancelled then return end
        if not result then
            cb(nil, errMsg(err))
            return
        end
        cb({
            title = result.title ~= "" and result.title or chapter.title,
            html = Content.decode_pua_content(result.content),
        })
    end)
    return h
end

function Source:openBookAsync(identity, opts, cb)
    local Chapter = require("source.chapter")
    local open = opts and opts.chapter_idx and Chapter.openAsync or Chapter.openWithUi
    return open(self, identity, identity.book, opts, {
        loadToc = function(ref, done) return self:loadTocAsync(ref, done) end,
        fetchContent = function(ref, ch, done) return fetch(self, ref, ch, done) end,
    }, cb)
end

function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    return require("source.chapter").prefetchAsync(identity, identity.book, toc, from_idx, count, {
        fetchContent = function(ref, ch, done) return fetch(self, ref, ch, done) end,
        interval_seconds = 6,
    }, cb)
end

function Source:getProgressAsync(identity, cb)
    local Toc = require("source.fanqie.toc")
    local h = handle()
    h.job = self.client:fetchReadProgressAsync(function(wire, err)
        if h.cancelled then return end
        if not wire then
            cb(nil, errMsg(err))
            return
        end
        local row
        for _, item in ipairs(wire.data or {}) do
            if tostring(item.book_id) == identity.stable_id then
                row = item
                break
            end
        end
        if not row or not row.item_id then
            cb(nil, nil, { empty = true })
            return
        end
        h.job = self:loadTocAsync(identity, function(toc, reason)
            if h.cancelled then return end
            if not toc then
                cb(nil, reason)
                return
            end
            local idx = Toc.index(self.id, identity.stable_id, row.item_id)
            if not idx then
                cb(nil, nil, { empty = true })
                return
            end
            local within = tonumber(row.read_progress) or 0
            if within > 1 then within = within / 10000 end
            within = math.max(0, math.min(1, within))
            cb({
                chapter_idx = idx,
                chapter_fraction = within,
                fraction = (idx - 1 + within) / #toc,
                extra = { chapter_uid = tostring(row.item_id), chapter_idx = idx },
            })
        end)
    end)
    return h
end

function Source:putProgressAsync(identity, pos, cb)
    local h = handle()
    h.job = self:loadTocAsync(identity, function(toc, err)
        if h.cancelled then return end
        if not toc then
            cb(nil, err)
            return
        end
        local idx = tonumber(pos.chapter_idx) or tonumber(identity.chapter_idx)
        local chapter = idx and toc[idx]
        if not chapter then
            cb(nil, "缺少番茄章节位置")
            return
        end
        h.job = self.client:updateReadProgressAsync(
            identity.stable_id, chapter.uid, idx - 1,
            math.max(0, math.min(1, tonumber(pos.chapter_fraction) or 0)),
            function(wire, reason)
                if h.cancelled then return end
                if not wire or tonumber(wire.code or 0) ~= 0 then
                    cb(nil, reason and errMsg(reason) or "番茄进度上传失败")
                    return
                end
                cb(true)
            end)
    end)
    return h
end

return M
