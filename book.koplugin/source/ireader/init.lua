--[[--
掌阅数据源。

扫码登录（掌阅 App）后，书架、目录、正文、进度走 PC 站 JSON。
书城搜索、分类和分页走手机站。本地删除留墓碑，不伪造远端删除成功。

@module koplugin.book.source.ireader
--]]

local Assets = require("source.assets")
local Browse = require("source.browse")
local Client = require("source.ireader.client")
local Mapper = require("source.ireader.mapper")
local Paths = require("utils.paths")
local Shelf = require("source.shelf")
local SourceBase = require("source.base")
local Toc = require("source.toc")
local Text = require("utils.text")
local _ = require("l10n").get("source.ireader")

local IReader = {}

local FETCH_INTERVAL = 0.5

local LEGACY_CHANNELS = { h5_ch_male = "10", h5_ch_female = "68", h5_ch_publish = "92" }
local CHANNEL_TITLES = { ["10"] = _("男生"), ["68"] = _("女生"), ["92"] = _("出版") }

---@return BookSourceMeta
function IReader.meta()
    return SourceBase.loadMeta("ireader")
end

---@class IReaderSource : SourceBase
local Source = setmetatable({ shelf_add = true }, { __index = SourceBase })
Source.__index = Source

---@return IReaderSource
function IReader.new()
    local meta = IReader.meta()
    return setmetatable({ id = meta.id, name = meta.name, type = meta.type }, Source)
end

---@return boolean
function Source:configured()
    return Client.session() ~= nil
end

local Remote = {}

function Remote:shelfSyncAsync(cb) return Client.shelfAsync(cb) end

---@param stable_id string
---@param cb fun(ok: boolean|nil, err: string|nil)
function Remote:addToShelfAsync(stable_id, cb)
    local row = require("book.books_db").get("ireader", stable_id)
    return Client.addAsync(stable_id, row and row.title or stable_id, cb)
end

--- 未接入可验证的远端移架请求。返回失败，墓碑留着，下次拉书架也不会把这本书加回来。
function Remote:removeFromShelfAsync(_stable_id, cb)
    return SourceBase.defer(cb, nil, _("掌阅网页不能把书移出书架"))
end

function Source:syncBooksAsync(opts, cb)
    if not self:configured() then return SourceBase.skipped(cb, "ireader not logged in") end
    return Shelf.syncAsync(self.id, Remote, Mapper.shelf, opts, cb)
end

---@param keyword string
---@param cb fun(res: { data: Book[] }|nil, err: string|nil)
function Source:searchAsync(keyword, cb)
    return Client.searchAsync(keyword, function(html, err)
        if not html then cb(nil, err or _("请求失败")); return end
        cb({ data = Mapper.search(html) })
    end)
end

---@param identity BookIdentity
---@param cb fun(page: IReaderReviewPage|nil, err: string|nil)
---@return HttpJob
function Source:bookReviewsAsync(identity, cb)
    return Client.reviewsAsync(identity.stable_id, cb)
end

---@param opts { node?: string, limit?: integer }|nil
---@param cb fun(res: { data: Book[], groups: StoreChipGroup[] }|nil, err: string|nil)
function Source:browseAsync(opts, cb)
    local node = opts and opts.node or ""
    local parent, category, order, status = node:match("^(%d+):(%d+):(%w+):(%d+)$")
    parent = parent or LEGACY_CHANNELS[node] or "10"
    category, order, status = category or parent, order or "download", status or "0"
    local limit = opts and opts.limit or 60
    local handle, pending = {}, true
    local initial = Client.categoriesAsync(parent, category, function(page, err)
        pending = false
        if handle.cancelled then return end
        if not page then cb(nil, err); return end
        parent, category = page.parent, page.category
        local function valid(rows, value, fallback)
            for _idx, row in ipairs(rows) do if row.id == value then return value end end
            return fallback
        end
        order = valid(page.orders, order, page.orders[1].id)
        status = valid(page.statuses, status, page.statuses[1].id)
        local values = { parent, category, order, status }
        local function group(title, rows, position)
            local chips, active = {}, nil
            for _idx, row in ipairs(rows) do
                local next_node = { unpack(values) }
                next_node[position] = row.id
                if position == 1 then
                    next_node[2] = row.id
                    if row.id == "92" and status == "3" then next_node[4] = "0" end
                end
                local id = table.concat(next_node, ":")
                chips[#chips + 1] = { id = id, title = position == 1 and CHANNEL_TITLES[row.id] or row.title }
                if row.id == values[position] then active = id end
            end
            return { title = title, chips = chips, active = active }
        end
        local groups = {
            group(nil, page.channels, 1), group(_("分类"), page.categories, 2),
            group(_("排序"), page.orders, 3), group(_("状态"), page.statuses, 4),
        }
        handle.job = Browse.pages(function(index, done)
            return Client.catalogAsync({ parent = parent, category = category, order = order, status = status }, index, done)
        end, limit, groups, function(result, reason)
            if handle.cancelled then return end
            if result then
                for index = #result.data, limit + 1, -1 do result.data[index] = nil end
            end
            cb(result, reason)
        end)
    end)
    if pending then handle.job = initial end
    function handle.cancel()
        handle.cancelled = true
        if handle.job then handle.job.cancel() end
    end
    return handle
end

function Source:getDetailAsync(identity, cb)
    return Client.detailAsync(identity.stable_id, function(body, err)
        local detail = Mapper.detail(body, identity.stable_id)
        if detail then cb(require("book.store").rememberDetail(detail)); return end
        local row = identity.book or require("book.books_db").get(self.id, identity.stable_id)
        if row then cb(row); return end
        cb(nil, err or _("请求失败"))
    end)
end

---@param self IReaderSource
---@param identity BookIdentity
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
local function fetchTocAsync(self, identity, cb)
    return Client.chaptersAsync(identity.stable_id, function(rows, err)
        if not rows then cb(nil, err); return end
        local toc = Mapper.chapters(rows)
        if #toc == 0 then cb(nil, _("掌阅目录为空")); return end
        if not Toc.put(self.id, identity.stable_id, toc) then cb(nil, _("章节目录保存失败")); return end
        cb(toc)
    end)
end

function Source:loadTocAsync(identity, cb, force)
    if not force then
        local cached = Toc.read(self.id, identity.stable_id)
        if cached and #cached > 0 and (cached[1].toc_version == Mapper.TOC_VERSION
            or not require("ui/network/manager"):isConnected()) then
            return SourceBase.defer(cb, cached)
        end
    end
    return fetchTocAsync(self, identity, cb)
end

Source.refreshTocAsync = fetchTocAsync

--- 已缓存正文离线原地还原字码，保留路径、节点和 sidecar；失败不覆盖旧文件。
---@param path string
---@return boolean
local function reuse(path)
    local file = assert(io.open(path, "rb"))
    local raw, read_err = file:read("*a")
    file:close()
    assert(raw, read_err)
    local html = assert(Mapper.content(raw), _("掌阅正文含未知字码，请更新插件后重试"))
    if html == raw then return true end
    local temp = path .. ".part"
    file = assert(io.open(temp, "wb"))
    local written, write_err = file:write(html)
    local closed, close_err = file:close()
    if not written or not closed then
        os.remove(temp)
        error(write_err or close_err)
    end
    local renamed, rename_err = os.rename(temp, path)
    if not renamed then
        os.remove(temp)
        error(rename_err)
    end
    return true
end

---@param open boolean
---@return ChapterFetchContent
local function fetcher(open)
    return function(identity, chapter, done)
        local cancelled, active, image_err = false, nil, nil
        local pending = true
        local initial = Client.contentAsync(identity.stable_id, chapter.uid, function(html, err, kind)
            pending = false
            if cancelled then return end
            if html then
                active = Assets.localizeAsync(html,
                    Paths.bookWorkDir(identity.stable_id, "ireader") .. "/images",
                    function(url, cb)
                        return require("http.request").get(url, {
                            accept = "image/*",
                            headers = { Referer = "https://pc.ireader.com/" },
                            cache_ttl = 0,
                            allow_redirects = true,
                            timeout = require("http.timeout").net(0.5),
                        }, function(raw, reason)
                            if reason then image_err = tostring(reason) end
                            cb(raw, reason)
                        end)
                    end,
                    function(localized)
                        if cancelled then return end
                        if Text.hasRemoteImageSrc(localized) then
                            done(nil, image_err or _("掌阅插图下载失败，请重试"))
                            return
                        end
                        done({ title = chapter.title, html = localized })
                    end)
            elseif open and kind == "unpaid" then
                local notice = string.format(_("这是 VIP 章节，你还没有购买。\n请先在%s购买本章，再回来阅读。"), _("掌阅"))
                done({
                    title = chapter.title,
                    html = Text.chapterHtml(chapter.title, notice),
                    temporary = true,
                })
            else
                done(nil, err)
            end
        end)
        if pending then active = initial end
        return { cancel = function()
            cancelled = true
            if active and active.cancel then active.cancel() end
        end }
    end
end

function Source:openBookAsync(identity, opts, cb)
    local Chapter = require("source.chapter")
    local open = opts and opts.chapter_idx and Chapter.openAsync or Chapter.openWithUi
    return open(self, identity, identity.book, opts, {
        loadToc = function(ref, done) return self:loadTocAsync(ref, done) end,
        fetchContent = fetcher(true),
        reuse = reuse,
    }, cb)
end

function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    local Chapter = require("source.chapter")
    return Chapter.prefetchAsync(identity, identity.book, toc, from_idx, count, {
        fetchContent = fetcher(false),
        interval_seconds = FETCH_INTERVAL,
        reuse = reuse,
    }, cb)
end

function Source:cacheAllChaptersAsync(identity, on_progress, cb, range)
    local Chapter = require("source.chapter")
    return Chapter.cacheAllAsync(self, identity, fetcher(false), on_progress, cb, FETCH_INTERVAL, range, reuse)
end

function Source:getProgressAsync(identity, cb)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录掌阅")) end
    local cancelled, job = false, nil
    local pending = true
    local initial = Client.progressAsync(identity.stable_id, function(item, err)
        pending = false
        if cancelled then return end
        if err then cb(nil, err); return end
        ---@type { chapterId: string|number|nil, readPercent: string|number|nil }|nil
        local process = type(item) == "table" and item.readProcess or nil
        local uid = type(process) == "table" and Mapper.progressUid(process.chapterId) or nil
        if not uid then cb(nil, nil, { empty = true }); return end
        job = self:loadTocAsync(identity, function(toc, reason)
            if cancelled then return end
            if not toc or #toc == 0 then cb(nil, reason or _("掌阅目录为空")); return end
            local idx = Toc.index(self.id, identity.stable_id, uid)
            if not idx then cb(nil, nil, { empty = true }); return end
            cb({
                chapter_idx = idx,
                chapter_title = toc[idx].title,
                fraction = (idx - 1) / #toc,
                extra = { chapter_uid = uid, chapter_idx = idx },
            })
        end)
    end)
    if pending then job = initial end
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

function Source:putProgressAsync(identity, pos, cb)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录掌阅")) end
    local cancelled, job = false, nil
    local pending = true
    local initial = self:loadTocAsync(identity, function(toc, err)
        pending = false
        if cancelled then return end
        if not toc then cb(nil, err); return end
        local idx = tonumber(pos.chapter_idx) or tonumber(identity.chapter_idx)
        local chapter = idx and toc[idx]
        if not chapter then cb(nil, _("缺少掌阅章节位置")); return end
        job = Client.putProgressAsync(identity.stable_id, chapter.uid, #toc, function(ok, perr)
            if cancelled then return end
            cb(ok and true or nil, perr)
        end)
    end)
    if pending then job = initial end
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

return IReader
