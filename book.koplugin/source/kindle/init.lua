--[[--
Kindle 源：列出 Kindle 系统书库（/var/local/cc.db）里的 KFX 与带 DRM 的 mobi / azw / azw3（无 DRM 的归本地源扫盘），开书交给用户自装的 kindle.koplugin。

月读不碰 DRM：转换、解密、进度弹窗、报错文案都是 kindle.koplugin 的
`package.loaded["lua/open_file_ext"]:prepareKnownKindlePath(path)`。它不是公开 API，每次用都检查、pcall。
stable_id 是 cc.db 的 p_uuid；已转换的书用它的缓存 EPUB 作文件路径，否则用原文件。

@module koplugin.book.source.kindle
--]]

local SourceBase = require("source.base")
local _ = require("gettext")
local T = require("ffi/util").template

local Kindle = {}

--- cc.db 路径（测试可改）。
Kindle.CC_DB = "/var/local/cc.db"
--- 小于这个字节数的缩略图是亚马逊的「无封面」占位图。
Kindle.MIN_COVER_BYTES = 4096

local KFX = "application/x-kfx-ebook"
local COLUMNS = "p_uuid, p_location, p_titles_0_nominal, j_credits, p_mimeType, p_thumbnail, p_percentFinished, p_lastAccess"
local FILTER = [[p_type = 'Entry:Item'
    AND (p_mimeType = 'application/x-kfx-ebook'
        OR (p_mimeType IN ('application/x-mobipocket-ebook', 'application/x-mobi8-ebook') AND p_isDRMProtected = 1))
    AND p_isVisibleInHome = 1 AND COALESCE(p_isArchived, 0) = 0
    AND p_location IS NOT NULL AND p_location <> '']]

local function attr(path, key)
    return type(path) == "string" and require("libs/libkoreader-lfs").attributes(path, key) or nil
end

--- kindle.koplugin 的开书解析器，形状不对就当没装。
---@return table|nil
function Kindle.helper()
    local ofe = package.loaded["lua/open_file_ext"]
    if type(ofe) == "table" and type(ofe.prepareKnownKindlePath) == "function" then return ofe end
    return nil
end

--- 有 cc.db 且装了 kindle.koplugin 才可用。
---@return boolean
function Kindle.available()
    return attr(Kindle.CC_DB, "mode") == "file" and Kindle.helper() ~= nil
end

--- kindle.koplugin 的缓存 EPUB（已转换才返回）。
---@param uuid string
---@param location string
---@return string|nil
local function cachedEpub(uuid, location)
    local helper = Kindle.helper()
    local cm = helper and helper.cache_manager
    if type(cm) ~= "table" or type(cm.getCachePaths) ~= "function" then return nil end
    local ok, epub = pcall(cm.getCachePaths, cm, { id = "cc:" .. uuid, source_path = location, open_mode = "convert" })
    return ok and attr(epub, "mode") == "file" and epub or nil
end

--- j_credits 是 JSON 数组，取所有 "display" 拼成作者。
local function authors(credits)
    if type(credits) ~= "string" then return nil end
    local names = {}
    for name in credits:gmatch('"display"%s*:%s*"(.-)"') do names[#names + 1] = name end
    return #names > 0 and table.concat(names, ", ") or nil
end

--- 只读查 cc.db，返回行表数组。
---@param where string|nil 附加条件
---@param ... any 绑定参数
---@return table[]|nil rows, string|nil err
function Kindle.query(where, ...)
    local ok, conn = pcall(require("lua-ljsqlite3/init").open, Kindle.CC_DB, "ro")
    if not ok then return nil, tostring(conn) end
    local sql = "SELECT " .. COLUMNS .. " FROM Entries WHERE " .. FILTER
        .. (where and (" AND " .. where) or "") .. " ORDER BY p_titles_0_collation COLLATE BINARY" -- 列声明 icu 排序规则，KOReader 的 sqlite 没有
    local rows = {}
    local done, err = pcall(function(...)
        local stmt = conn:prepare(sql)
        if select("#", ...) > 0 then stmt:bind(...) end
        for row in stmt:rows() do
            local thumb = row[6]
            rows[#rows + 1] = {
                uuid = row[1],
                location = row[2],
                title = row[3],
                authors = authors(row[4]),
                kfx = row[5] == KFX,
                cover = (tonumber(attr(thumb, "size")) or 0) >= Kindle.MIN_COVER_BYTES and thumb or nil,
                percent = tonumber(row[7]),
                last_access = tonumber(row[8]),
            }
        end
        stmt:close()
    end, ...)
    conn:close()
    if not done then return nil, tostring(err) end
    return rows
end

--- 返回 Kindle 源元信息。
---@return BookSourceMeta
function Kindle.meta()
    return { id = "kindle", name = _("Kindle 书库"), type = "book" }
end

---@class KindleSource : SourceBase
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

---@return KindleSource
function Kindle.new()
    local meta = Kindle.meta()
    return setmetatable({ id = meta.id, name = meta.name, type = meta.type }, Source)
end

function Source:configured()
    return Kindle.available()
end

--- 只能编辑展示元信息（cc.db 只读，改动只落月读库）。
function Source:capabilities()
    return { scrape = false, edit = true, stats_pull = false, shelf_cache = false }
end

--- 编辑后标脏：reconcile 遇脏行不盖 title/authors，否则下一轮同步就把编辑覆盖回 cc.db 的值。
function Source:onEvent(event, payload)
    if event == "book_meta_changed" then
        require("book.books_db").setLibraryMembership(self.id, payload.identity.stable_id, true)
    end
end

--- 书架只来自本机 cc.db，没有远端可推。
function Source:pushDirty() end

--- 书架 = cc.db 快照（KFX + 带 DRM 的 mobi 族；无 DRM 的归本地源）。查询失败报错，不当成空书架。
function Source:syncBooksAsync(opts, cb)
    opts = opts or {}
    if opts.dirty_only then return SourceBase.skipped(cb, "kindle dirty_only") end
    local rows, err = Kindle.query()
    if not rows then return SourceBase.defer(cb, nil, err) end
    local books = {}
    for i, row in ipairs(rows) do
        books[i] = {
            stable_id = row.uuid,
            title = row.title,
            authors = row.authors,
            cover = row.cover,
            path = cachedEpub(row.uuid, row.location) or row.location,
            inserted_at = row.last_access,
        }
    end
    local ok, hidden = require("book.books_db").reconcile(self.id, books, { force = opts.force, allow_empty = true })
    if not ok then return SourceBase.defer(cb, nil, "failed to reconcile books") end
    return SourceBase.defer(cb, { pulled = #books, pushed = 0, hidden = hidden, conflicts = 0, skipped = false })
end

--- 封面是 Kindle 自带的缩略图文件（同步只查库）。
function Source:coverRequest(identity)
    local cover = identity.cover
    if type(cover) ~= "string" or cover == "" then
        local row = require("book.books_db").get(self.id, identity.stable_id)
        cover = row and row.cover
    end
    if attr(cover, "mode") == "file" then return { url = cover, headers = {} } end
    return nil, _("无封面")
end

--- kindle.koplugin 里这本书的目录项和缓存管理器；接口不全（版本不同）返回 nil，退回它自己的同步转换。
---@param row table
---@return table|nil book, table|nil cache_manager
local function convertible(row)
    local helper = Kindle.helper()
    local library, cm = helper.virtual_library, helper.cache_manager
    if type(library) ~= "table" or type(library.getBook) ~= "function"
        or type(cm) ~= "table" or type(cm.isFresh) ~= "function" or type(cm.ensureCachedEpub) ~= "function" then
        return nil
    end
    local book = library:getBook("cc:" .. row.uuid) or library:getBook(row.location)
    if book and not cm:isFresh(book) then return book, cm end
    return nil
end

--- 开书：按 uuid 查原文件交给 kindle.koplugin，拿到真实路径再走我们的阅读器。
--- KFX 首次要转换（kindle-helper 要几分钟）：放进 fork 子进程当后台任务，UI 不卡、可取消、可转后台；
--- 转换完时用户还在等才继续开，转了后台只提示。相对可用内存偏大的 KFX 先确认再入队，避免默默 OOM。
function Source:openBookAsync(identity, _opts, cb)
    local rows, err = Kindle.query("p_uuid = ?", identity.stable_id)
    local row = rows and rows[1]
    if not row then return SourceBase.defer(cb, nil, err or _("Kindle 书库里找不到这本书")) end
    local helper = Kindle.helper()
    if not helper then return SourceBase.defer(cb, nil, _("需要先安装并启用 kindle.koplugin")) end
    local cancelled = false
    local handle = { cancel = function() cancelled = true end }
    local function open()
        require("ui/uimanager"):nextTick(function()
            if cancelled then return end
            local ok, path, prep_err = pcall(helper.prepareKnownKindlePath, helper, row.location)
            if cancelled then return end
            if not ok or type(path) ~= "string" or path == "" then
                return cb(nil, ok and prep_err or _("无法打开书籍"))
            end
            local touched, store_err = require("book.store").touch(path, identity)
            cb(touched and path or nil, store_err)
        end)
    end

    local book, cm
    if row.kfx then book, cm = convertible(row) end
    if not book then
        if row.kfx then
            require("ui.themes.widgets.toast"):new{ text = _("首次打开需要转换，可能要几分钟，请耐心等待") }:show()
        end
        open()
        return handle
    end

    local function enqueueConvert()
        if cancelled then return end
        local Tasks = require("workers.tasks")
        local foreground = true
        local task, reason = Tasks.enqueue{
            key = "kindle\0convert\0" .. row.uuid,
            kind = "cache",
            title = row.title,
            cancellable = true,
            run = function(report, done)
                report(_("首次打开需要转换，可能要几分钟"))
                return require("workers.job").run(function()
                    local path, convert_err = cm:ensureCachedEpub(book)
                    return { ok = path ~= nil, err = convert_err }
                end, {
                    name = "kindle.convert",
                    kind = "medium",
                    on_done = done,
                    on_failed = function(job_err) done({ ok = false, err = tostring(job_err) }) end,
                })
            end,
            on_done = function(result)
                if cancelled then return end
                if foreground then
                    if result.ok then open() else cb(nil, result.err or _("无法打开书籍")) end
                elseif result.ok then
                    require("ui.themes.widgets.toast"):new{ text = T(_("「%1」已转换完成，可以打开了"), row.title) }:show()
                else
                    require("ui.themes.widgets.toast"):new{ text = T(_("「%1」转换失败"), row.title) }:show()
                end
            end,
        }
        if not task then
            return cb(nil, reason == "running" and _("这本书正在转换，请稍后再试") or _("任务队列已满"))
        end
        require("workers.ui.task_dialog").follow(task, function() foreground = false end)
        handle.cancel = function()
            cancelled = true
            task.cancel()
        end
    end

    local size = attr(row.location, "size") or 0
    local Mem = require("utils.mem")
    if Mem.isHeavy(size) then
        local file_mb = Mem.mb(size) or 1
        local free_mb = Mem.mb(Mem.availableBytes())
        local text = free_mb
            and T(_("这本书文件很大（约 %1 MB；当前可用内存约 %2 MB）。首次打开需要由 kindle.koplugin 转换成 EPUB，转换过程内存占用很高，在 Kindle 上可能卡死或被系统强制结束，并可能耗时很久。\n\n仍要转换并打开吗？"), file_mb, free_mb)
            or T(_("这本书文件很大（约 %1 MB）。首次打开需要由 kindle.koplugin 转换成 EPUB，转换过程内存占用很高，在 Kindle 上可能卡死或被系统强制结束，并可能耗时很久。\n\n仍要转换并打开吗？"), file_mb)
        require("ui.themes.widgets.confirm"):new{
            text = text,
            ok_text = _("仍然转换"),
            cancel_text = _("取消"),
            ok_callback = enqueueConvert,
            cancel_callback = function() cb(nil, nil, { cancelled = true }) end,
        }:show()
        return handle
    end

    enqueueConvert()
    return handle
end

return Kindle
