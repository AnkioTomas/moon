--[[--
本地数据源门面：扫盘同步写库 + 查询走 book.catalog（本地唯一读入口）。

syncBooksAsync = 扫盘或 WebDAV 同步（force 强制 / 否则节流自动同步）。查询继承 SourceBase。

@module koplugin.book.source.local
--]]

local SourceBase = require("source.base")
local Client = require("source.local.client")
local _ = require("gettext")

local Local = {}

--- 返回本地源元信息。
---@return BookSourceMeta
function Local.meta()
    return require("source.meta").get("local")
end

---@class LocalSource : SourceBase
---@field cfg table
---@field _client table
---@field _auto_sync_at number|nil 上次自动同步开始时间（失败清掉）
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
        scrape = true,
        edit = true,
        stats_pull = self._client:isWebdav(),
    }
end

--- 是否已配置本地路径。
---@return boolean
function Source:configured()
    return self._client:configured()
end

--- 编辑 / 刮削后：WebDAV 书库立即上行这本书；纯本地目录没有远端，什么都不做。
---@param event string
---@param payload table|nil
function Source:onEvent(event, payload)
    if event ~= "book_meta_changed" or not self._client:isWebdav() then return end
    local stable_id = payload.identity.stable_id
    self._client:pushBookAsync(stable_id, payload.cover == true, function(ok, err)
        if not ok then require("utils.log").warn("book webdav meta push failed", stable_id, err) end
    end)
end

--- 纯本地目录没有远端：书库外开过的书、进度、统计会一直是脏行，入队只会每次唤醒空跑一轮。
function Source:pushDirty()
    if self._client:isWebdav() then SourceBase.pushDirty(self) end
end

--- 删除。WebDAV 书：删本地镜像后走基类本地优先删除，远端文件与书目条目由下一轮同步的 pushDeletes 推删。
--- 纯本地书：原书文件就是“远端”，删掉它即确认，随后标删并立即撕墓碑。
--- 两种书删掉的本地文件都连带清 KOReader 记的 .sdr、阅读历史与收藏。
---@param identity BookIdentity
---@param cb fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
function Source:deleteBookAsync(identity, cb)
    local stable_id = identity.stable_id
    local Sidecar = require("book.sidecar")
    if Client.isRemote(stable_id) then
        local mirror = self._client:webdavBookRoot() .. "/" .. require("source.local.common").remoteRelativePath(stable_id)
        os.remove(mirror)
        Sidecar.remove(mirror)
        return SourceBase.deleteBookAsync(self, identity, cb)
    end
    -- 文件已被外部删掉同样算确认，否则这本书永远删不掉。
    if not os.remove(stable_id) and require("libs/libkoreader-lfs").attributes(stable_id, "mode")
        or not require("book.store").markDeleted(self.id, stable_id) then
        return SourceBase.defer(cb, false, _("删除本书失败"))
    end
    Sidecar.remove(stable_id)
    -- 原书已删、书已从书架消失，对用户就是删成了；撕不掉的墓碑只是库里残留，不报失败。
    if not require("book.books_db").remove(self.id, stable_id) then
        require("utils.log").warn("book local tombstone remove failed", stable_id)
    end
    return SourceBase.defer(cb, true)
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
    local path = identity.stable_id
    if require("libs/libkoreader-lfs").attributes(path, "mode") ~= "file" then
        return SourceBase.defer(cb, nil, _("本地书籍文件不存在"))
    end
    local ok, err = require("book.store").touch(path, identity)
    return SourceBase.defer(cb, ok and path or nil, err)
end

--- 封面：扫描时已提取到 image 缓存目录，这里只查缓存（同步，禁止现解析）。
---@param identity BookIdentity
---@return BookCoverRequest|nil, string|nil
function Source:coverRequest(identity)
    local path = self._client:cachedCoverPath(identity.stable_id)
    if path then
        return { url = path, headers = nil }
    end
    return nil, _("无封面")
end

local skipped = SourceBase.skipped

--- 桌面打开触发的自动同步节流（秒）：反复开桌面不重复扫盘、不重复跑整轮 WebDAV。
local AUTO_SYNC_INTERVAL = 60

--- 书架同步。WebDAV：force=刷新（另列远端目录）、dirty_only=只推本地删除与书目改动、否则日常同步；
--- 有本地改动没推上去时整轮仍算成功，原因放在 push_error。纯本地目录：扫盘，dirty_only 无事可做。
--- 不带 force / dirty_only 的自动同步按 AUTO_SYNC_INTERVAL 节流；失败不占节流窗口，下次打开桌面就重试。
---@param opts { force?: boolean, dirty_only?: boolean, on_progress?: fun(text: string|nil, done: integer|nil, total: integer|nil), on_background?: fun(start: function) }|nil on_background=后台上传交给调用方排队、展示进度
---@param cb fun(result: SyncResult|nil, err: any)
---@return { cancel: fun() }|nil
function Source:syncBooksAsync(opts, cb)
    opts = opts or {}
    local webdav = self._client:isWebdav()
    if opts.dirty_only and not webdav then return skipped(cb, "local dirty_only") end
    local auto = not opts.force and not opts.dirty_only
    if auto then
        if self._auto_sync_at and os.time() - self._auto_sync_at < AUTO_SYNC_INTERVAL then
            return skipped(cb, "throttled")
        end
        self._auto_sync_at = os.time()
    end
    local function done(ok, err, push_error)
        if not ok then
            if auto then self._auto_sync_at = nil end
            return cb(nil, err)
        end
        -- 扫盘 / WebDAV 同步不统计变更本数：pulled 非 0 只是让桌面按“可能有变”刷新。
        cb({ pulled = opts.dirty_only and 0 or 1, pushed = 0, hidden = 0, conflicts = 0,
            skipped = false, push_error = push_error })
    end
    if webdav then
        return self._client:scanWebdavAsync(done,
            { refresh = opts.force, dirty_only = opts.dirty_only, on_progress = opts.on_progress,
                on_background = opts.on_background })
    end
    return self._client:scanAsync(done, opts.on_progress, opts.force)
end

--- 纯本地目录没有远端：进度域直接 skipped；WebDAV 走通用 book.progress（开书拉取 + 冲突弹窗，关书推脏）。
function Source:syncProgressAsync(opts, cb)
    if not self._client:isWebdav() then return skipped(cb, "local source") end
    return SourceBase.syncProgressAsync(self, opts, cb)
end

--- 拉 WebDAV 进度（Moon+ `.Moon+/Cache/<文件名>.po`）；纯本地目录按“远端无记录”处理。
---@param identity BookIdentity
---@param cb fun(pos: ProgressPosition|nil, err: string|nil, meta: table|nil)
function Source:getProgressAsync(identity, cb)
    if not self._client:isWebdav() then return SourceBase.defer(cb, nil, nil, { empty = true }) end
    return self._client:getProgressAsync(identity.stable_id, cb)
end

---@param identity BookIdentity
---@param pos ProgressPosition
---@param cb fun(ok: boolean|nil, err: string|nil)
function Source:putProgressAsync(identity, pos, cb)
    return self._client:putProgressAsync(identity.stable_id, pos, cb)
end

--- 纯本地目录没有远端：统计域直接 skipped；WebDAV 走通用 book.stats。
function Source:syncStatsAsync(opts, cb)
    if not self._client:isWebdav() then return skipped(cb, "local source") end
    return SourceBase.syncStatsAsync(self, opts, cb)
end

--- 上报阅读统计到 `.Moon+/Stats/`（按书文件 + 总表），仅 WebDAV（见 syncStatsAsync）。
---@param rows BookStatsRow[]
---@param cb fun(result: BookStatsPushResult|nil, err: string|nil)
function Source:pushStatsAsync(rows, cb)
    return self._client:pushStatsAsync(rows, cb)
end

--- 纯本地目录没有远端：笔记域直接 skipped；WebDAV 走通用 book.note（每设备每书一份快照，拉取取并集）。
function Source:syncNotesAsync(opts, cb)
    if not self._client:isWebdav() then return skipped(cb, "local source") end
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
        return self._client:importWebdavAsync(temp_path, filename, cb)
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
        require("book.books_db").setLibraryMembership(self.id, stable_id, true)
        return stable_id
    end
    return self._client:moveBook(stable_id, category, series)
end

return Local
