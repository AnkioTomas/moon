--[[--
Kindle 书库数据源门面：装了 kindle.koplugin 的 Kindle 上，直接读 Kindle 原生书库。
  client：借道 kindle.koplugin（cc.db 书目 / KFX 转换 / DRM）
  mapper：书目条目 → Book

书架以 cc.db 为全量快照 reconcile；stable_id = kindle.koplugin 的书目 id（cc:<uuid>）。
打开：MOBI/AZW3 直接给原文件；KFX 复用 kindle.koplugin 的转换缓存，未命中时子进程转换。
无远端：进度 / 笔记 / 统计不实现，各域自动 skipped；和 Kindle 阅读器的位置互通由 kindle.koplugin 自己负责。

@module koplugin.book.source.kindle
--]]

local SourceBase = require("source.base")
local Client = require("source.kindle.client")
local Mapper = require("source.kindle.mapper")
local _ = require("gettext")

local Kindle = {}

local META = { id = "kindle", name = _("Kindle 书库"), type = "book" }

--- 未装 kindle.koplugin（或不是 Kindle）时返回 nil，数据源列表里不出现。
---@return BookSourceMeta|nil
function Kindle.meta()
    return Client.available() and META or nil
end

---@class KindleSource : SourceBase
---@field _catalog table<string, table> 书目 id → kindle.koplugin 书目条目（最近一次扫描）
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

---@return KindleSource
function Kindle.new()
    return setmetatable({
        id = META.id,
        name = META.name,
        type = META.type,
        _catalog = {},
    }, Source)
end

---@return SourceCapabilities
function Source:capabilities()
    local caps = SourceBase.SourceCapabilities.defaults()
    caps.search = true
    caps.refresh = true
    caps.insight = true
    return caps
end

---@return boolean
function Source:configured()
    return Client.available()
end

--- 重扫 cc.db，刷新书目缓存。
---@return table[]|nil kbooks
---@return string|nil err
function Source:_scan()
    local kbooks, err = Client.scan()
    if not kbooks then return nil, err end
    self._catalog = {}
    for _, kbook in ipairs(kbooks) do
        self._catalog[kbook.id] = kbook
    end
    return kbooks
end

--- 书架 = cc.db 快照。已可打开的书顺带登记 books.path，从 kindle.koplugin 入口打开也能认出身份。
---@param opts { force?: boolean, dirty_only?: boolean }|nil
---@param cb fun(result: SyncResult|nil, err: any)
---@return { cancel: fun() }
function Source:syncBooksAsync(opts, cb)
    local cancelled = false
    require("ui/uimanager"):nextTick(function()
        if cancelled then return end
        if opts and opts.dirty_only then
            cb({ pulled = 0, pushed = 0, hidden = 0, conflicts = 0, skipped = true, reason = "kindle dirty_only" })
            return
        end
        local kbooks, err = self:_scan()
        if not kbooks then
            cb(nil, err)
            return
        end
        local books = {}
        for _, kbook in ipairs(kbooks) do
            books[#books + 1] = Mapper.book(kbook, Client.readyPath(kbook))
        end
        local result, rec_err = require("book.store").reconcile(self.id, books)
        if result then require("db.book").releaseForeignPaths(self.id) end
        cb(result, rec_err)
    end)
    return { cancel = function() cancelled = true end }
end

---@param identity BookIdentity
---@param _opts table|nil
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }
function Source:openBookAsync(identity, _opts, cb)
    local cancelled, job = false, nil
    local function finish(path, err)
        if cancelled then return end
        if not path then
            cb(nil, err)
            return
        end
        local ok, store_err = require("book.store").touch(path, identity)
        if not ok then
            cb(nil, store_err)
            return
        end
        require("db.book").releaseForeignPaths(self.id)
        cb(path)
    end
    require("ui/uimanager"):nextTick(function()
        if cancelled then return end
        local kbook = self._catalog[identity.stable_id]
        if not kbook then
            local _kbooks, err = self:_scan()
            kbook = self._catalog[identity.stable_id]
            if not kbook then
                finish(nil, err or _("Kindle 书库中找不到这本书"))
                return
            end
        end
        if kbook.open_mode == "blocked" then
            finish(nil, Client.reasonText(kbook.block_reason))
            return
        end
        local path = Client.readyPath(kbook)
        if path then
            finish(path)
            return
        end
        job = require("workers.job").run(function()
            local epub, code = Client.prepare(kbook)
            return { path = epub, code = code }
        end, {
            name = "kindle.prepare",
            kind = "heavy",
            on_done = function(res)
                finish(res.path, not res.path and Client.reasonText(res.code) or nil)
            end,
            on_failed = function(err)
                finish(nil, tostring(err))
            end,
        })
    end)
    return { cancel = function()
        cancelled = true
        if job then job:cancel() end
    end }
end

return Kindle
