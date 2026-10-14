--[[--
Kindle 源：列出 Kindle 系统书库（/var/local/cc.db）里的 KFX 与带 DRM 的 mobi / azw / azw3（无 DRM 的归本地源扫盘），开书交给用户自装的 kindle.koplugin。

月读不碰 DRM：转换、解密、进度弹窗、报错文案都是 kindle.koplugin 的
`package.loaded["lua/open_file_ext"]:prepareKnownKindlePath(path)`。它不是公开 API，每次用都检查、pcall。
stable_id 是 cc.db 的 p_uuid；已转换的书用它的缓存 EPUB 作文件路径，否则用原文件。

@module koplugin.book.source.kindle
--]]

local SourceBase = require("source.base")
local _ = require("gettext")

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
        .. (where and (" AND " .. where) or "") .. " ORDER BY p_titles_0_collation"
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

--- 开书：按 uuid 查原文件交给 kindle.koplugin（KFX 首次要转换，可能几分钟），拿到真实路径再走我们的阅读器。
function Source:openBookAsync(identity, _opts, cb)
    local rows, err = Kindle.query("p_uuid = ?", identity.stable_id)
    local row = rows and rows[1]
    if not row then return SourceBase.defer(cb, nil, err or _("Kindle 书库里找不到这本书")) end
    local helper = Kindle.helper()
    if not helper then return SourceBase.defer(cb, nil, _("需要先安装并启用 kindle.koplugin")) end
    if row.kfx and not cachedEpub(row.uuid, row.location) then
        require("ui.themes.widgets.toast"):new{ text = _("首次打开需要转换，可能要几分钟，请耐心等待") }:show()
    end
    local cancelled = false
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
    return { cancel = function() cancelled = true end }
end

return Kindle
