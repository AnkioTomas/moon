local SourceBase = require("source.base")
local Client = require("source.kavita.client")
local _ = require("gettext")

local Kavita = {}

local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

function Kavita.meta()
    return { id = "kavita", name = _("Kavita"), type = "book" }
end

function Kavita.new()
    local cfg = require("utils.settings").getSource("kavita")
    local meta = Kavita.meta()
    local self = setmetatable({
        id = meta.id,
        name = meta.name,
        type = meta.type,
        cfg = cfg,
        _client = Client:new(cfg),
    }, Source)
    return self
end

function Source:capabilities()
    return {
        search = true,
        refresh = true,
        scrape = false,
        edit = false,
        insight = true,
        stats_pull = false,
    }
end

function Source:configured()
    return self._client:configured()
end

function Source:coverRequest(identity)
    local stable_id = identity and identity.stable_id
    return self._client:coverRequest(stable_id)
end

function Source:syncBooksAsync(opts, cb)
    opts = opts or {}
    if opts.dirty_only then
        require("ui/uimanager"):nextTick(function()
            cb({
                pulled = 0, pushed = 0, hidden = 0, conflicts = 0,
                skipped = true, reason = "kavita dirty_only no-op",
            })
        end)
        return { cancel = function() end }
    end
    local libraries = self.cfg.libraries or {}
    local lib_ids = {}
    for id in pairs(libraries) do
        lib_ids[#lib_ids + 1] = id
    end
    if #lib_ids == 0 then
        require("ui/uimanager"):nextTick(function()
            cb({
                pulled = 0, pushed = 0, hidden = 0, conflicts = 0,
                skipped = true, reason = "kavita: no libraries selected",
            })
        end)
        return { cancel = function() end }
    end
    local all_books = {}
    local cancelled = false
    local pending = #lib_ids
    local has_error = false
    local function fetchLibrary(lib_id)
        local page = 1
        local function fetchPage()
            if cancelled then return end
            self._client:fetchSeriesPage(lib_id, page, 1000, function(data, err)
                if cancelled then return end
                if err then
                    if not has_error then
                        has_error = true
                        cb(nil, err)
                    end
                    return
                end
                if not data or #data == 0 then
                    pending = pending - 1
                    if pending == 0 and not has_error then
                        local Store = require("book.store")
                        local result, rerr = Store.reconcile(self.id, all_books)
                        if result then
                            cb(result, rerr)
                        else
                            cb(nil, rerr)
                        end
                    end
                    return
                end
                for _, series in ipairs(data) do
                    all_books[#all_books + 1] = {
                        source_id = self.id,
                        stable_id = tostring(series.id),
                        title = series.name,
                        category = series.libraryName,
                        series = nil,
                        format = series.format == 3 and "epub" or series.format == 4 and "pdf" or series.format == 1 and "cbz" or series.format == 0 and "image" or nil,
                        cover = tostring(series.id),
                        deleted = 0,
                    }
                end
                page = page + 1
                fetchPage()
            end)
        end
        fetchPage()
    end
    for _, lib_id in ipairs(lib_ids) do
        fetchLibrary(lib_id)
    end
    return { cancel = function() cancelled = true end }
end

function Source:deleteBookAsync(identity, cb)
    local Store = require("book.store")
    if not Store.markDeleted(self.id, identity.stable_id) then
        require("ui/uimanager"):nextTick(function()
            cb(false, _("删除本书失败"))
        end)
        return { cancel = function() end }
    end
    require("ui/uimanager"):nextTick(function()
        cb(true)
    end)
    return { cancel = function() end }
end

function Source:openBookAsync(identity, opts, cb)
    opts = opts or {}
    local cancelled = false
    local dialog

    local function closeDialog()
        if dialog then dialog:close(); dialog = nil end
    end

    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        require("ui/uimanager"):nextTick(function()
            if not cancelled then cb(nil, _("网络不可用，请先连接 Wi-Fi")) end
        end)
        return { cancel = function() cancelled = true end }
    end

    local Paths = require("utils.paths")
    local stable_id = identity.stable_id
    local ext = "epub"
    local book_format = identity.book and identity.book.format
    if book_format == "pdf" then
        ext = "pdf"
    elseif book_format == "cbz" then
        ext = "cbz"
    end
    Paths.ensureBookWork(stable_id, self.id)
    local path = Paths.bookWorkDir(stable_id, self.id) .. "/1." .. ext
    local temp_path = path .. ".part"

    local function register(local_path)
        local ok, err = require("book.store").touch(local_path, identity)
        if ok then
            cb(local_path)
        else
            cb(nil, err)
        end
    end

    NetworkMgr:runWhenOnline(function()
        if cancelled then return end
        local ProgressbarDialog = require("ui/widget/progressbardialog")
        dialog = ProgressbarDialog:new{
            title = _("正在下载…"),
            subtitle = identity.book and identity.book.title or stable_id,
            progress_max = 100,
            refresh_time_seconds = 1,
            dismissable = false,
        }
        dialog:show()

        local chapter_id = opts.chapter_id or "1"
        self._client:downloadChapterAsync(chapter_id, temp_path, function(bytes, total)
            if dialog and total and total > 0 then
                dialog:reportProgress(bytes * 100 / total)
            end
        end, function(ok, err)
            closeDialog()
            if cancelled then return end
            if not ok then
                os.remove(temp_path)
                cb(nil, err)
                return
            end
            local file = io.open(temp_path, "rb")
            local head = file and file:read(4) or ""
            if file then file:close() end
            local valid = false
            if ext == "epub" then
                valid = head == "PK\003\004" or head == "PK\005\006"
            elseif ext == "pdf" then
                valid = head == "%PDF"
            else
                valid = true
            end
            if not valid then
                os.remove(temp_path)
                cb(nil, _("下载文件校验失败"))
                return
            end
            os.remove(path)
            if not os.rename(temp_path, path) then
                os.remove(temp_path)
                cb(nil, _("无法保存文件"))
                return
            end
            register(path)
        end)
    end)

    return { cancel = function()
        cancelled = true
        closeDialog()
    end }
end

return Kavita
