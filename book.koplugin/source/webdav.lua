--[[--
WebDAV 数据源门面：列目录 + 整本下载（仅异步）。

@module koplugin.book.source.webdav
--]]

local SourceBase = require("source.base")
local Client = require("source.webdav.client")
local Mapper = require("source.webdav.mapper")
local _ = require("gettext")

local WebDAV = {}

local BOOK_EXTENSIONS = {
    epub = true,
    pdf = true,
    cbz = true,
    cbr = true,
    mobi = true,
    azw3 = true,
    txt = true,
}

---@type table<string, function[]>
local opening = {}

---@param identity BookIdentity
---@return string
local function bookPath(identity)
    local Paths = require("utils.paths")
    local ext = identity.stable_id:match("%.([%w]+)$")
    ext = ext and string.lower(ext) or nil
    Paths.ensureBookWork(identity.stable_id, identity.source_id)
    return Paths.bookWorkDir(identity.stable_id, identity.source_id)
        .. "/book." .. (BOOK_EXTENSIONS[ext] and ext or "epub")
end

---@param path string
---@param format_path string|nil
---@return boolean
local function validBook(path, format_path)
    local attr = require("libs/libkoreader-lfs").attributes(path)
    if not attr or attr.mode ~= "file" or not attr.size or attr.size < 4 then
        return false
    end
    local file = io.open(path, "rb")
    if not file then return false end
    local head = file:read(4) or ""
    file:close()

    local ext = (format_path or path):match("%.([^.]+)$")
    ext = ext and string.lower(ext) or nil
    if ext == "txt" then return true end
    if ext == "mobi" or ext == "azw3" then
        if attr.size < 68 then return false end
        file = io.open(path, "rb")
        if not file then return false end
        file:seek("set", 60)
        local palm = file:read(8) or ""
        file:close()
        return palm == "BOOKMOBI" or palm == "TEXtREAd"
    end
    if ext == "epub" or ext == "cbz" then
        return head == "PK\003\004" or head == "PK\005\006"
    end
    if ext == "cbr" then
        return head == "Rar!" or head == "PK\003\004"
    end
    return ext == "pdf" and head == "%PDF"
end

---@param key string
---@param start fun(done: fun(ok: boolean, path: string|nil, err: any))
---@param cb fun(ok: boolean, path: string|nil, err: any)
local function shareOpening(key, start, cb)
    local waiters = opening[key]
    if waiters then
        waiters[#waiters + 1] = cb
        return
    end
    opening[key] = { cb }
    start(function(ok, path, err)
        waiters = opening[key]
        opening[key] = nil
        for i = 1, #waiters do
            waiters[i](ok, path, err)
        end
    end)
end

--- 返回 WebDAV 源元信息。
---@return BookSourceMeta
function WebDAV.meta()
    return { id = "webdav", name = _("WebDAV"), type = "book" }
end

---@class WebdavSource : SourceBase
---@field cfg table
---@field _client table
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

--- 构造 WebDAV 源实例。
---@return WebdavSource
function WebDAV.new()
    local cfg = require("utils.settings").getSource("webdav")
    local meta = WebDAV.meta()
    local self = setmetatable({
        id = meta.id,
        name = meta.name,
        type = meta.type,
        cfg = cfg,
        _client = Client.new(cfg),
    }, Source)
    return self
end

--- 返回 WebDAV 源能力集。
---@return SourceCapabilities
function Source:capabilities()
    return {
        search = true,
        refresh = true,
        scrape = false,
        insight = true,
        store = false,
    }
end

--- 是否已配置 WebDAV。
---@return boolean
function Source:configured()
    return self._client:configured()
end

--- 打开 WebDAV 整本书：缓存命中直开，否则下载、校验并登记物理路径。
---@param identity BookIdentity
---@param _opts table|nil
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }
function Source:openBookAsync(identity, _opts, cb)
    local cancelled = false
    local dialog
    local path = bookPath(identity)

    local function closeDialog()
        if dialog then
            dialog:close()
            dialog = nil
        end
    end

    local function register(local_path)
        require("book.store").touchAsync(local_path, identity, nil, function(ok, err)
            if cancelled then return end
            if ok then
                cb(local_path)
            else
                cb(nil, err and tostring(err) or _("无法登记书籍路径"))
            end
        end)
    end

    if validBook(path) then
        register(path)
        return { cancel = function() cancelled = true end }
    end
    os.remove(path)

    require("ui/network/manager"):runWhenOnline(function()
        if cancelled then return end
        shareOpening(identity.stable_id, function(done)
            local book = identity.book or {}
            local title = book.title
                or (identity.stable_id:match("([^/\\]+)$") or identity.stable_id)
            local size = tonumber(book.fileSize or book.filesize or book.size or book.file_size)
            local has_dialog, ProgressbarDialog = pcall(require, "ui/widget/progressbardialog")
            if has_dialog and ProgressbarDialog then
                dialog = ProgressbarDialog:new{
                    title = _("正在下载…"),
                    subtitle = title,
                    progress_max = (size and size > 0) and size or nil,
                    refresh_time_seconds = 1,
                    dismissable = false,
                }
                dialog:show()
            else
                require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
                    text = _("正在下载…"),
                })
            end

            local temp_path = path .. ".part"
            self._client:downloadAsync(identity.stable_id, temp_path, dialog and function(bytes)
                if dialog then dialog:reportProgress(bytes) end
            end or nil, function(ok, err)
                closeDialog()
                if not ok then
                    os.remove(temp_path)
                    done(false, nil, (type(err) == "table" and err.message) or err)
                    return
                end
                if not validBook(temp_path, path) then
                    os.remove(temp_path)
                    done(false, nil, _("下载文件校验失败"))
                    return
                end
                os.remove(path)
                if not os.rename(temp_path, path) then
                    os.remove(temp_path)
                    done(false, nil, _("无法保存文件"))
                    return
                end
                done(true, path)
            end)
        end, function(ok, local_path, err)
            if cancelled then return end
            if not ok then
                cb(nil, err or _("下载失败"))
                return
            end
            register(local_path)
        end)
    end)

    return {
        cancel = function()
            cancelled = true
            closeDialog()
        end,
    }
end

--- 递归拉取完整 WebDAV 目录，成功后一次性对账。
---@param _opts table|nil
---@param cb fun(result: SyncResult|nil, err: any)
---@return { cancel: fun() }
function Source:syncBooksAsync(_opts, cb)
    local queue, seen, books = { "" }, {}, {}
    local cancelled, job = false, nil
    local function nextDir()
        if cancelled then return end
        local path = table.remove(queue, 1)
        if path == nil then
            job = require("book.store").reconcileAsync(self.id, books, nil, cb)
            return
        end
        if seen[path] then nextDir(); return end
        seen[path] = true
        job = self._client:listAsync(path, function(entries, err)
            job = nil
            if cancelled then return end
            if not entries then cb(nil, (type(err) == "table" and err.message) or err); return end
            for _, entry in ipairs(entries) do
                if entry.is_dir and type(entry.path) == "string" and entry.path ~= "" then
                    queue[#queue + 1] = entry.path
                end
            end
            local mapped = Mapper.list(entries, path)
            for _, book in ipairs(mapped.data or {}) do books[#books + 1] = book end
            nextDir()
        end)
    end
    nextDir()
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job:cancel() end
    end }
end

--- 把书城下载文件上传到 WebDAV 根目录。
---@param local_path string
---@param filename string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return table|nil
function Source:importBookAsync(local_path, filename, cb)
    if not self._client:configured() then
        cb(nil, _("未配置 WebDAV 地址或用户名"))
        return nil
    end
    return self._client:uploadAsync(filename, local_path, cb)
end

return WebDAV
