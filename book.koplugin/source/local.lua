--[[--
本地数据源门面：扫盘同步写库 + 查询走 book.catalog（本地唯一读入口）。

syncBooksAsync = 扫盘（force 强制 / 否则节流自动扫）。查询继承 SourceBase。

@module koplugin.book.source.local
--]]

local SourceBase = require("source.base")
local Client = require("source.local.client")
local _ = require("gettext")

local Local = {}

--- 返回本地源元信息。
---@return BookSourceMeta
function Local.meta()
    return { id = "local", name = _("本地书籍"), type = "book" }
end

---@class LocalSource : SourceBase
---@field cfg table
---@field _client table
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

--- 构造本地源实例。
---@return LocalSource
function Local.new()
    local cfg = require("utils.settings").getSource("local")
    local meta = Local.meta()
    local self = setmetatable({
        id = meta.id,
        name = meta.name,
        type = meta.type,
        cfg = cfg,
        _client = Client.new(cfg),
    }, Source)
    return self
end

--- 返回本地源能力集。
---@return SourceCapabilities
function Source:capabilities()
    return {
        search = true,
        refresh = true,
        scrape = true,
        edit = true,
        insight = true,
        stats_pull = self._client:isWebdav(),
    }
end

--- 是否已配置本地路径。
---@return boolean
function Source:configured()
    return self._client:configured()
end

--- 手动扫盘缺少目录时直接引导设置；后台生命周期仍由基类静默跳过。
---@param event string
---@param payload table|nil
function Source:onEvent(event, payload)
    if event == "book_meta_changed" then
        if not self._client:isWebdav() then return end
        local stable_id = payload.identity.stable_id
        self._client:pushBookAsync(stable_id, payload.cover == true, function(ok, err)
            if not ok then require("utils.log").warn("book webdav meta push failed", stable_id, err) end
        end)
        return
    end
    if event == "library_refresh_request" and not self:configured() then
        local UIManager = require("ui/uimanager")
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = _("请先设置本地书库目录，再扫描书籍。"),
            ok_text = _("立即设置"),
            ok_callback = function()
                require("source.local.setting").open(payload and payload.plugin)
            end,
        })
        return
    end
    return SourceBase.onEvent(self, event, payload)
end

--- 删除本地原书及其本地登记。
---@param identity BookIdentity
---@param cb fun(ok: boolean, err: string|nil)
---@return table
function Source:deleteBookAsync(identity, cb)
    if Client.isRemote(identity.stable_id) then
        return self._client:deleteWebdavAsync(identity.stable_id, function(ok, err, listed)
            if ok then
                -- 留墓碑而不是删行：books.sync 没写成时它是脏的，reconcile 不会拿远端旧条目把书复活，
                -- 下一轮 pushBooksSync 把条目删掉再清脏。
                local BookDB = require("db.book")
                BookDB.markDeleted(self.id, identity.stable_id)
                if listed then BookDB.markSynced(self.id, identity.stable_id) end
                cb(true)
            else
                cb(false, err or _("删除 WebDAV 书籍失败"))
            end
        end)
    end
    local cancelled = false
    require("ui/uimanager"):nextTick(function()
        if cancelled then return end
        local path = identity and identity.stable_id
        if type(path) ~= "string" or path == "" or not os.remove(path) then
            cb(false, _("删除本书失败"))
            return
        end
        require("db.book").remove(self.id, identity.stable_id)
        require("db.chapter").delete(path)
        local Paths = require("utils.paths")
        os.remove(Paths.coverPath(identity.stable_id, self.id))
        cb(true)
    end)
    return { cancel = function() cancelled = true end }
end

--- 本地文件直接登记并返回，不下载不复制。
---@param identity BookIdentity
---@param _opts table|nil
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }
function Source:openBookAsync(identity, _opts, cb)
    if Client.isRemote(identity.stable_id) then
        return self._client:openWebdavAsync(identity.stable_id, function(path, err)
            if not path then cb(nil, err); return end
            local ok, store_err = require("book.store").touch(path, identity)
            if ok then cb(path) else cb(nil, store_err) end
        end)
    end
    local cancelled = false
    require("ui/uimanager"):nextTick(function()
        if cancelled then return end
        local path = identity.stable_id
        if type(path) ~= "string"
            or require("libs/libkoreader-lfs").attributes(path, "mode") ~= "file" then
            cb(nil, _("本地书籍文件不存在"))
            return
        end
        local ok, err = require("book.store").touch(path, identity)
        if ok then
            cb(path)
        else
            cb(nil, err)
        end
    end)
    return { cancel = function() cancelled = true end }
end

--- 封面：扫描时已提取到 image 缓存目录，这里只查缓存（同步，禁止现解析）。
---@param identity BookIdentity
---@return BookCoverRequest|nil, string|nil
function Source:coverRequest(identity)
    local path = self._client:cachedCoverPath(identity and identity.stable_id)
    if path then
        return { url = path, headers = nil }
    end
    return nil, _("无封面")
end

--- 扫盘写 books：force 立即扫；否则走节流自动扫。
---@param opts { force?: boolean, dirty_only?: boolean }|nil
---@param cb fun(result: SyncResult|nil, err: any)
---@return { cancel: fun() }|nil
function Source:syncBooksAsync(opts, cb)
    opts = opts or {}
    -- local 无远端书架；dirty_only 跳过扫盘。
    if opts.dirty_only then
        require("ui/uimanager"):nextTick(function()
            cb({
                pulled = 0, pushed = 0, hidden = 0, conflicts = 0,
                skipped = true, reason = "local dirty_only",
            })
        end)
        return { cancel = function() end }
    end
    if opts.force then
        return self._client:scanAsync(function(ok, err)
            if ok == false then cb(nil, err); return end
            cb({ pulled = 1, pushed = 0, hidden = 0, conflicts = 0,
                skipped = false, scanned = true })
        end)
    end
    return self._client:autoScanAsync(function(scanned, err, skipped)
        if err then
            cb(nil, err)
            return
        end
        cb({ pulled = scanned and 1 or 0, pushed = 0, hidden = 0, conflicts = 0,
            skipped = skipped == true, reason = skipped and "throttled" or nil,
            scanned = not not scanned })
    end)
end

--- 纯本地目录没有远端：进度域直接 skipped；WebDAV 走通用 book.progress（开书拉取 + 冲突弹窗，关书推脏）。
function Source:syncProgressAsync(opts, cb)
    if not self._client:isWebdav() then
        cb({ skipped = true, reason = "local source" })
        return { cancel = function() end }
    end
    return SourceBase.syncProgressAsync(self, opts, cb)
end

--- 拉 WebDAV 进度（Moon+ `.Moon+/Cache/<文件名>.po`）；纯本地目录按“远端无记录”处理。
---@param identity BookIdentity
---@param cb fun(pos: ProgressPosition|nil, err: string|nil, meta: table|nil)
function Source:getProgressAsync(identity, cb)
    if not self._client:isWebdav() then
        require("ui/uimanager"):nextTick(function() cb(nil, nil, { empty = true }) end)
        return nil
    end
    return self._client:getProgressAsync(identity.stable_id, cb)
end

---@param identity BookIdentity
---@param pos ProgressPosition
---@param cb fun(ok: boolean|nil, err: string|nil)
function Source:putProgressAsync(identity, pos, cb)
    return self._client:putProgressAsync(identity.stable_id, pos, cb)
end

--- 上报阅读统计到 `.Moon+/Stats/stats.json`。纯本地目录没有远端，整批确认零行，
--- book.stats 按“本轮无可推”收尾，不刷失败日志。
---@param rows BookStatsRow[]
---@param cb fun(result: BookStatsPushResult|nil, err: string|nil)
function Source:pushStatsAsync(rows, cb)
    if not self._client:isWebdav() then
        require("ui/uimanager"):nextTick(function() cb({ synced_ids = {} }) end)
        return nil
    end
    return self._client:pushStatsAsync(rows, cb)
end

--- 纯本地目录没有远端：笔记域直接 skipped；WebDAV 走通用 book.note（每设备每书一份快照，拉取取并集）。
function Source:syncNotesAsync(opts, cb)
    if not self._client:isWebdav() then
        cb({ skipped = true, reason = "local source" })
        return { cancel = function() end }
    end
    return SourceBase.syncNotesAsync(self, opts, cb)
end

---@param identity BookIdentity
---@param annotations table[]
---@param cb fun(value: table|nil, err: string|nil)
function Source:pushNotesAsync(identity, annotations, cb)
    return self._client:pushNotesAsync(identity.stable_id, annotations, cb)
end

---@param identity BookIdentity
---@param cb fun(annotations: table[]|nil, err: string|nil, meta: table|nil)
function Source:pullNotesAsync(identity, cb)
    return self._client:pullNotesAsync(identity.stable_id, cb)
end

--- 仅 WebDAV（capabilities.stats_pull）时由 book.stats 调用。
---@param cb fun(result: BookStatsRow[]|BookStatsPullResult|nil, err: string|nil)
function Source:pullStatsAsync(cb)
    return self._client:pullStatsAsync(cb)
end

--- 把书城下载文件移入本地书库根目录，并单本入库（不重扫）。
---@param temp_path string
---@param filename string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return table|nil
function Source:importBookAsync(temp_path, filename, cb)
    if self._client:isWebdav() then
        filename = tostring(filename or ""):gsub("[/\\]", "_")
        if filename == "" then
            cb(nil, _("无效文件名"))
            return nil
        end
        local job
        job = self._client.dav:ensurePathAsync(self._client:webdavPath(), function(ok_dir, dir_err)
            if not ok_dir then cb(nil, dir_err); return end
            job = self._client.dav:putFileAsync(
                self._client:webdavPath() .. "/" .. filename,
                temp_path,
                function(ok, err)
                    if not ok then cb(nil, err); return end
                    cb(true)
                end
            )
        end)
        return job
    end
    return self._client:importAsync(temp_path, filename, cb)
end

--- 手动改分类/系列 = 移动文件（分类/系列即目录层级），stable_id 跟着变。
---@param stable_id string 当前文件绝对路径
---@param category string|nil
---@param series string|nil
---@return string|nil new_stable_id, string|nil err
function Source:moveBook(stable_id, category, series)
    if self._client:isWebdav() then
        -- WebDAV 下分类/系列只是 books.sync 元数据，不移动文件。编辑框随后 upsertLocal 写字段；
        -- 这里先标脏，否则下一轮同步会用远端书目把这次编辑覆盖回去。
        require("db.book").setLibraryMembership(self.id, stable_id, true)
        return stable_id
    end
    return self._client:moveBook(stable_id, category, series)
end

--- 用转换后的 EPUB 替换原书（WebDAV 书连同远端文件与书目），并迁移书籍身份与附属资源。
---@param temp_path string
---@param stable_id string
---@param cb fun(new_path: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Source:replaceBookAsync(temp_path, stable_id, cb)
    return self._client:replaceBookAsync(temp_path, stable_id, cb)
end

return Local
