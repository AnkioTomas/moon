







local lfs = require("libs/libkoreader-lfs")
local Text = require("utils.text")
local _ = require("l10n").get("source.local")
local T = require("ffi/util").template
local Job = require("workers.job")
local Common = require("source.local.common")

local SOURCE_ID = Common.SOURCE_ID
local defer, isBookFile, localRoot, ensureParent = Common.defer, Common.isBookFile, Common.localRoot, Common.ensureParent
local fetchText, putText = Common.fetchText, Common.putText
local remoteStableId, remoteRelativePath = Common.remoteStableId, Common.remoteRelativePath
local sidecarKey, stem, readFile, writeFile, field = Common.sidecarKey, Common.stem, Common.readFile, Common.writeFile, Common.field
local eachAsync, coverPath = Common.eachAsync, Common.coverPath
local safeRel = Common.safeRel
local parseBookProps, scanFiles = Common.parseBookProps, Common.scanFiles
local moonPath, coverRemotePath = Common.moonPath, Common.coverRemotePath
local progressRemotePath, notesRemotePath = Common.progressRemotePath, Common.notesRemotePath

local Webdav = {}

-- 上传失败的书多久内不再自动重传（秒）；每轮同步都重传整个失败批次会拖垮网络
local UPLOAD_COOLDOWN = 3600


local SERIES_PREFIX = "^<(.-)>%s*\n%s*#(.-)#%s*\n"






local function entryRow(entry, rel)
    local tags = type(entry.category) == "string" and entry.category or ""
    return {
        source_id = SOURCE_ID, stable_id = remoteStableId(rel),
        title = field(entry.bookName), authors = field(entry.author),
        intro = field(entry.description), category = field(entry.favorite),
        series = field(entry.series) or field(tags:match(SERIES_PREFIX)),
    }
end







local function rowEntry(self, row, rel, base)
    local entry = {}
    for k, v in pairs(base or {}) do entry[k] = v end
    if not base then
        entry.addTime = os.time() * 1000
        entry.deviceId = require("utils.device_id").ensure()
        entry.downloadUrl = "[WebDav]/" .. self:webdavPath() .. "/" .. rel
        entry.coverUrl, entry.rate, entry.groupName = "", "0", ""
        entry.groupBooks = require("json").util.InitArray({})
    end
    local category = type(entry.category) == "string" and entry.category or ""
    local _series, prefix_num = category:match(SERIES_PREFIX)
    local tags = Text.trim((category:gsub(SERIES_PREFIX, "")))
    local series = row.series or ""
    local num = math.floor(tonumber(entry.seriesNum) or tonumber(prefix_num) or 0)
    entry.filename = rel
    entry.bookName = row.title or stem(rel)
    entry.author = row.authors or ""
    entry.description = row.intro or ""
    entry.favorite = row.category or ""
    entry.series, entry.seriesNum = series, num
    entry.category = series ~= "" and string.format("<%s>\n#%d#\n%s", series, num, tags) or tags
    return entry
end

local ENTRY_FIELDS = { "filename", "bookName", "author", "description", "favorite", "category", "series", "seriesNum" }


local function sameEntry(a, b)
    for _idx, key in ipairs(ENTRY_FIELDS) do
        if tostring(a[key] or "") ~= tostring(b[key] or "") then return false end
    end
    return true
end




local function decodeBooksSync(raw)
    local JSON = require("json")
    local ok_json, decoded = pcall(JSON.decode, raw)
    if ok_json then
        return decoded
    end
    local ok_zlib, Zlib = pcall(require, "ffi/zlib")
    if not ok_zlib then
        return nil
    end
    for _idx, size in ipairs({ 65536, 262144, 1048576, 4194304, 16777216 }) do
        local inflated_ok, inflated = pcall(Zlib.zlib_uncompress, raw, size)
        if inflated_ok then
            ok_json, decoded = pcall(JSON.decode, inflated)
            if ok_json then
                return decoded
            end
        end
    end
    return nil
end








local function listVersion(decoded)
    local version, device
    for _idx, entry in ipairs(decoded) do
        local v = type(entry) == "table" and tonumber(entry.syncVersion)
        if v and (not version or v > version) then
            version, device = v, type(entry.syncDevice) == "string" and entry.syncDevice or nil
        end
    end
    return version, device
end



local function versionPath(self)
    return self:webdavCacheRoot() .. "/books_sync_version"
end





local function knownVersion(self)
    local raw = readFile(versionPath(self)) or ""
    local version, device = raw:match("^(%d+)\n?(.*)$")
    return tonumber(version), device ~= "" and device or nil
end




local function rememberVersion(self, version, device)
    writeFile(versionPath(self), version .. "\n" .. (device or ""))
end






















local BOOK_PATH_MAX_DEPTH = 3

local LIST_CONCURRENCY = 4
local LARGE_LIBRARY_ENTRIES = 1000



local function pathDepth(rel)
    local n = 1
    for _slash in rel:gmatch("/") do n = n + 1 end
    return n
end




local function entryRel(folder_path, entry)
    local path = entry.path or entry.name
    if folder_path ~= "" then
        local prefix = folder_path .. "/"
        if path:sub(1, #prefix) == prefix then return path:sub(#prefix + 1) end
    end
    return path
end






local function eachAsyncLimit(list, limit, step, done)
    if #list == 0 then return done() end
    local next_i, live, finished, pumping = 1, 0, false, false
    local function pump()
        if finished or pumping then return end
        pumping = true
        while live < limit and next_i <= #list do
            local i = next_i
            next_i = next_i + 1
            live = live + 1
            step(list[i], function()
                live = live - 1
                pump()
            end, i)
        end
        pumping = false
        if next_i > #list and live == 0 then
            finished = true
            done()
        end
    end
    pump()
end



local function knownRemoteFiles()
    local BookDB = require("book.books_db")
    local out = {}
    for _idx, stable_id in ipairs(BookDB.libraryStableIdsBySource(SOURCE_ID)) do
        local rel = remoteRelativePath(stable_id)
        if rel then out[rel] = true end
    end
    return out
end




local function knownUnder(known, dir_rel)
    local prefix = dir_rel .. "/"
    local found = {}
    for rel in pairs(known) do
        if rel:sub(1, #prefix) == prefix then found[#found + 1] = rel end
    end
    return found
end









local function listBooks(self, run, done)
    local Timeout = require("http.timeout")
    -- 列目录跟用户的「网络超时」走，不写死比设置更短的秒数。
    -- 单文件夹：整包 net(1)，连接 net(CONNECT_RATIO)。
    -- 书库根一次可能列上万条，整包和连接都用 net(10)，
    -- 避免慢服务器的首包被默认连接超时（30×2/3=20 秒）掐掉。
    local folder_timeout = Timeout.net(1)
    local folder_connect = Timeout.net(Timeout.CONNECT_RATIO)
    local tree_timeout = Timeout.net(10)
    local root = self:webdavPath()
    local known = knownRemoteFiles()
    local list_jobs = {}
    run.list_jobs = list_jobs
    run.list_failed = {}
    local checked = 0

    local function adoptKnown(dir_rel)
        for _idx, rel in ipairs(knownUnder(known, dir_rel)) do
            if pathDepth(rel) <= BOOK_PATH_MAX_DEPTH then run.remote[rel] = true end
        end
    end

    local function collect(folder_path, prefix, entries, depth)
        local dirs = {}
        for _idx, entry in ipairs(entries) do
            if entry.name:sub(1, 1) ~= "." then
                checked = checked + 1
                if checked == LARGE_LIBRARY_ENTRIES then
                    local Settings = require("utils.settings")
                    local cfg = Settings.getSource(SOURCE_ID)
                    if not cfg.webdav_large_library_warned then
                        require("ui.themes.widgets.toast"):new{
                            text = _("WebDAV 中的文件和文件夹较多，逐项检查会较慢。建议自行部署月读服务：\nhttps://github.com/AnkioTomas/book"),
                            timeout = 8,
                        }:show()
                        cfg.webdav_large_library_warned = true
                        Settings.saveSource(SOURCE_ID)
                    end
                end
                local rel = prefix ~= "" and prefix .. "/" .. entryRel(folder_path, entry) or entryRel(folder_path, entry)
                if entry.is_dir then
                    if depth < BOOK_PATH_MAX_DEPTH then
                        dirs[#dirs + 1] = { path = entry.path, rel = rel }
                    end
                elseif isBookFile(entry.name) and pathDepth(rel) <= BOOK_PATH_MAX_DEPTH then
                    run.remote[rel] = true
                end
            end
        end
        return dirs
    end

    local function walkEntries(path, prefix, depth, entries, finish)
        local dirs = collect(path, prefix, entries, depth)
        eachAsyncLimit(dirs, LIST_CONCURRENCY, function(dir, next_dir, index)
            if run.cancelled then return end
            run.report(T(_("正在列出远端目录 %1"), dir.path), index, #dirs)
            local job, completed
            job = self.dav:listAsync(dir.path, function(child, err)
                completed = true
                if job then list_jobs[job] = nil end
                if run.cancelled then return end
                if not child then
                    -- 单本 / 单文件夹失败不中止整轮：记下、跳过，已列入的书仍保留。
                    require("utils.log").warn("book webdav list folder failed", dir.rel, err)
                    run.list_failed[#run.list_failed + 1] = dir.rel
                    adoptKnown(dir.rel)
                    return next_dir()
                end
                walkEntries(dir.path, dir.rel, depth + 1, child, next_dir)
            end, { timeout = folder_timeout, connect_timeout = folder_connect })
            if job and not completed then list_jobs[job] = true end
        end, finish)
    end

    local function finishList(err)
        run.list_jobs = nil
        done(err)
    end

    -- 固定布局目录（书库根、.Moon+、Cache、Cover）不存在就建，已存在时 MKCOL 返回 405 视为成功。
    run.report(_("正在检查远端目录…"))
    run.active = self.dav:ensurePathAsync(moonPath(self, "Cache"), function(ok, err)
        if run.cancelled then return end
        if not ok then return done(err) end
        run.active = self.dav:ensurePathAsync(moonPath(self, "Cover"), function(ok_cover, cover_err)
            if run.cancelled then return end
            if not ok_cover then return done(cover_err) end
            run.report(T(_("正在列出远端目录 %1"), root))
            run.active = self.dav:listAsync(root, function(entries, list_err)
                if run.cancelled then return end
                if not entries then return finishList(list_err or "WebDAV list failed") end
                walkEntries(root, "", 1, entries, function() finishList() end)
            end, { depth = "1", timeout = tree_timeout, connect_timeout = tree_timeout })
        end)
    end)
end





local function scanLocal(self, run, done)
    run.local_files = {}
    local root = localRoot(self)
    if not root then return done() end
    run.report(_("正在扫描本地书库…"))
    run.active = Job.run(function()
        -- 同步合并会把“本地没有”的条目删掉：有子目录读不了就整轮中止
        local files, skipped = scanFiles(root)
        if skipped[1] then error("cannot open " .. skipped[1], 0) end
        return files
    end, {
        name = "local.webdav.scan",
        kind = "medium",
        on_done = function(files)
            if run.cancelled then return end
            for _idx, item in ipairs(files) do run.local_files[item.path:sub(#root + 2)] = item end
            done()
        end,
        on_failed = function(err)
            if not run.cancelled then done(err or "local scan failed") end
        end,
    })
end



local function tombstone(stable_id)
    local BookDB = require("book.books_db")
    BookDB.markDeleted(SOURCE_ID, stable_id)
    BookDB.markSynced(SOURCE_ID, stable_id)
end





local function memberFiles(run)
    local function alive(rel)
        return not run.remote or run.remote[rel] or run.local_files[rel] ~= nil
    end
    local out, seen = {}, {}
    local function add(rel)
        if not seen[rel] then seen[rel] = true; out[#out + 1] = rel end
    end
    for rel in pairs(run.entries) do
        if alive(rel) then add(rel) end
    end
    for _idx, row in ipairs(require("book.books_db").unsynced(SOURCE_ID)) do
        local rel = remoteRelativePath(row.stable_id)
        -- 脏墓碑（删了还没推）也算：pushBooksSync 要靠它剔条目、清脏。
        if rel and (row.deleted == 1 or alive(rel)) then add(rel) end
    end
    for rel in pairs(run.remote or {}) do add(rel) end
    table.sort(out)
    return out
end










local function pullBooksSync(self, run, done)
    run.report(_("正在下载书目…"))
    run.active = fetchText(self, moonPath(self, "books.sync"), self:webdavCacheRoot() .. "/.books.sync",
        function(raw, err, missing)
        if run.cancelled then return end
        -- 连不上、认证 / 权限错误：后面每一步都会同样失败，中止整轮把原因报给用户。
        if not raw and not missing then return done(err) end
        local decoded = raw and decodeBooksSync(raw)
        if type(decoded) == "table" then
            run.version, run.version_device = listVersion(decoded)
            for _idx, entry in ipairs(decoded) do
                if type(entry) == "table" and type(entry.filename) == "string" then
                    if safeRel(entry.filename) then
                        run.entries[entry.filename] = entry
                    else
                        require("utils.log").warn("book webdav books.sync unsafe filename", entry.filename)
                    end
                end
            end
        elseif raw then
            -- 书目读不出来就不知道谁还活着：不 reconcile、不回写，只跑其余步骤。
            require("utils.log").warn("book webdav books.sync unreadable", "decode failed")
            run.meta_failed = true
            run.files = {}
            -- 静默跳过会表现成“云端有书、书架却一本没多”：把原因带到同步结果里提示用户。
            run.push_error = run.push_error or _("云端书目 books.sync 无法读取，本轮未合并书目；可检查或删除 .Moon+/books.sync 后刷新")
            return done()
        end

        -- 失败目录中的书目条目即使尚未拉到本地，也不能因为这次没列出来就删除。
        for _idx, dir_rel in ipairs(run.list_failed or {}) do
            local prefix = dir_rel .. "/"
            for rel in pairs(run.entries) do
                if rel:sub(1, #prefix) == prefix then run.remote[rel] = true end
            end
        end
        local BookDB = require("book.books_db")
        run.files = memberFiles(run)
        -- 书目与远端列表都为空而本地书架非空：首次同步，或目录填错 / 服务端异常。本轮不下架任何书，
        -- 但照常上传本地书、写书目（meta_failed 只表示书目读不出、不能回写）。
        -- 只看远端：run.files 还含本地脏行，靠它判断会让一条未推的编辑把整个书架下架。
        local live = {}
        -- 本地入库的绝对路径身份不是云端的书，不算“本地书架非空”
        for _idx, stable_id in ipairs(BookDB.libraryStableIdsBySource(SOURCE_ID)) do
            if remoteRelativePath(stable_id) then live[#live + 1] = stable_id end
        end
        if next(run.entries) == nil and next(run.remote or {}) == nil and #live > 0 then
            require("utils.log").warn("book webdav remote library empty; skip reconcile")
            run.reconcile_skipped = true
            return done()
        end
        local before = BookDB.getMany(SOURCE_ID, live)
        local ids = {}
        for i, rel in ipairs(run.files) do ids[i] = remoteStableId(rel) end
        local known = BookDB.getMany(SOURCE_ID, ids)
        local rows = {}
        for i, rel in ipairs(run.files) do
            local entry = run.entries[rel]
            local row = entry and entryRow(entry, rel) or { source_id = SOURCE_ID, stable_id = ids[i] }
            -- 裸文件（书目里没有）用文件名兜底，但不能拿文件名覆盖已解析出的书名。
            if not row.title and not (known[ids[i]] and known[ids[i]].title) then
                row.title = stem(rel)
            end
            rows[i] = row
        end
        run.report(T(_("正在写入书架（%1 本）"), #rows))
        if not BookDB.reconcile(SOURCE_ID, rows) then
            return done("failed to save WebDAV book metadata")
        end
        local known, known_device = knownVersion(self)
        local trusted = not run.version or not known or run.version > known
            or (run.version == known and run.version_device == known_device)
        if not trusted then
            require("utils.log").warn("book webdav books.sync stale version; keep local files",
                run.version, run.version_device, known, known_device)
        elseif run.version and run.version ~= known then
            rememberVersion(self, run.version, run.version_device)
        end
        local root, member = localRoot(self), {}
        for _idx, rel in ipairs(run.files) do member[rel] = true end
        for stable_id, row in pairs(before) do
            local rel = remoteRelativePath(stable_id)
            if trusted and root and rel and not member[rel] and row.sync_status == 1 and row.path == root .. "/" .. rel then
                os.remove(row.path)
                tombstone(stable_id)
            end
        end
        done()
    end)
end





local function pullProgress(self, run, done)
    local ProgressDB = require("book.progress_db")
    run.report(_("正在检查阅读进度…"))
    run.active = self.dav:listAsync(moonPath(self, "Cache"), function(entries, err)
        if run.cancelled then return end
        if not entries then
            require("utils.log").warn("book webdav progress list failed", err)
            return done()
        end
        -- 边车按书文件 basename 寻址：书目成员用 webdav:// 身份；书库里还没上传 / 没进书目的
        -- 本地书用它的物理路径身份，这样「只同步进度、不上传正文」的书也能在批量同步里拉回进度。
        local by_key, metadata = {}, {}
        local BookDB = require("book.books_db")
        for _idx, rel in ipairs(run.files) do
            -- 还没收编的本地书（书目里有条目、库里是绝对路径身份）按它自己的身份写回，
            -- 免得本轮先写出一条 webdav:// 的进度行、随后收编再合并出两份。
            local item = run.local_files and run.local_files[rel]
            local stable_id = remoteStableId(rel)
            if item and not BookDB.get(SOURCE_ID, stable_id) then stable_id = item.path end
            by_key[sidecarKey(rel)] = { rel = rel, stable_id = stable_id }
        end
        for rel, item in pairs(run.local_files or {}) do
            local key = sidecarKey(rel)
            if not by_key[key] then
                by_key[key] = { rel = rel, stable_id = item.path }
            end
        end
        for _idx, entry in ipairs(entries) do metadata[entry.name] = true end
        local pending = {}
        for _idx, entry in ipairs(entries) do
            local target = by_key[entry.name:match("^(.+)%.po$") or ""]
            local pos = target and ProgressDB.get(SOURCE_ID, target.stable_id)
            if target and entry.mtime and (not pos or pos.sync_status ~= 0
                and entry.mtime > (tonumber(pos.updated_at) or 0)) then
                pending[#pending + 1] = { rel = target.rel, stable_id = target.stable_id,
                    mtime = entry.mtime,
                    metadata_present = metadata[entry.name .. ".json"] == true }
            end
        end
        eachAsync(pending, function(item, next_item, i)
            run.report(T(_("正在下载进度 %1"), item.rel), i, #pending)
            run.active = self:getProgressAsync(item.stable_id, function(pos, err)
                if run.cancelled then return end
                if pos then
                    local stable_id = item.stable_id
                    local local_pos = ProgressDB.get(SOURCE_ID, stable_id)
                    local RemoteData = require("source.local.remote_data")
                    -- Keep the local position until the reader can ask which one to use.
                    if not local_pos or not RemoteData.progressUploadGuardEnabled()
                        or not RemoteData.isProgressAhead(pos, local_pos) then
                        pos.updated_at = item.mtime
                        ProgressDB.upsertRemote(SOURCE_ID, stable_id, pos)
                    end
                elseif err then
                    require("utils.log").warn("book webdav progress failed", item.rel, err)
                end
                next_item()
            end, { metadata_present = item.metadata_present })
        end, done)
    end)
end





local function pullCovers(self, run, done)
    run.report(_("正在检查封面…"))
    run.active = self.dav:listAsync(moonPath(self, "Cover"), function(entries, err)
        if run.cancelled then return end
        if not entries then
            require("utils.log").warn("book webdav cover list failed", err)
            -- 远端封面状态未知：当作全都有，避免步骤 7 重复上传。
            for _idx, rel in ipairs(run.files) do run.covers[sidecarKey(rel)] = true end
            return done()
        end
        for _idx, entry in ipairs(entries) do
            local key = entry.name:match("^(.+)_2%.png$")
            if key then run.covers[key] = true end
        end
        local pending = {}
        for _idx, rel in ipairs(run.files) do
            if run.covers[sidecarKey(rel)]
                and lfs.attributes(coverPath(remoteStableId(rel)), "mode") ~= "file" then
                pending[#pending + 1] = rel
            end
        end
        eachAsync(pending, function(rel, next_item, i)
            run.report(T(_("正在下载封面 %1"), rel), i, #pending)
            local target = coverPath(remoteStableId(rel))
            ensureParent(target)
            run.active = self.dav:getAsync(coverRemotePath(self, rel), target .. ".part",
                { timeout = require("http.timeout").net(1) }, function(ok)
                if run.cancelled then return end
                if ok then
                    os.remove(target)
                    os.rename(target .. ".part", target)
                else
                    os.remove(target .. ".part")
                end
                next_item()
            end)
        end, done)
    end)
end








local function enrichCached(self, run, done)
    self._enriched = self._enriched or {}
    local ids = {}
    for i, rel in ipairs(run.files) do ids[i] = remoteStableId(rel) end
    local rows = require("book.books_db").getMany(SOURCE_ID, ids)
    local pending = {}
    for i, rel in ipairs(run.files) do
        local stable_id, row = ids[i], rows[ids[i]]
        local path = self:webdavBookRoot() .. "/" .. rel
        local bare = not (row and row.title) or row.title == stem(rel)
        if not self._enriched[stable_id] and lfs.attributes(path, "mode") == "file"
            and (bare or lfs.attributes(coverPath(stable_id), "mode") ~= "file") then
            self._enriched[stable_id] = true
            pending[#pending + 1] = { rel = rel, stable_id = stable_id, path = path }
        end
    end
    if #pending == 0 then return done() end
    run.report(T(_("正在解析 %1 本书的信息"), #pending))
    run.active = Job.run(function()
        local out = {}
        for i, item in ipairs(pending) do out[i] = parseBookProps(item.path, item.stable_id) or {} end
        return out
    end, {
        name = "local.webdav.enrich",
        kind = "medium",
        on_done = function(props)
            if run.cancelled then return end
            local BookDB = require("book.books_db")
            for i, item in ipairs(pending) do
                local row, p = BookDB.get(SOURCE_ID, item.stable_id), props[i]
                if row then
                    local title = (not row.title or row.title == stem(item.rel)) and p.title or row.title
                    BookDB.upsertLocal({
                        source_id = SOURCE_ID, stable_id = item.stable_id,
                        title = title, authors = row.authors or p.authors, intro = row.intro or p.intro,
                        category = row.category, series = row.series, meta = { language = p.language },
                    })
                end
            end
            done()
        end,
        on_failed = function(err)
            require("utils.log").warn("book webdav enrich failed", err)
            if not run.cancelled then done() end
        end,
    })
end



local function isOpenInReader(path)
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local ui = ReaderUI and ReaderUI.instance
    return ui and ui.document and ui.document.file == path or false
end





local function adoptLocal(item, stable_id)
    local BookDB = require("book.books_db")
    if not BookDB.get(SOURCE_ID, item.path) then
        return BookDB.touchPath(SOURCE_ID, stable_id, item.path)
    end
    -- 关书仍会写旧身份；所有收编入口都等到阅读结束后再迁移。
    if isOpenInReader(item.path) then return true end
    if lfs.attributes(coverPath(stable_id), "mode") ~= "file" then
        local cover = readFile(coverPath(item.path))
        if cover then writeFile(coverPath(stable_id), cover) end
    end
    local ok = BookDB.adoptStableId(SOURCE_ID, item.path, stable_id, item.path)
    if not ok then require("utils.log").warn("book webdav identity adoption failed", item.path, stable_id) end
    return ok
end


local function uploadEnabled()
    return require("utils.settings").getSource(SOURCE_ID).webdav_upload_local ~= false
end








local function indexLocal(self, run, done)
    local remote = run.remote or run.entries
    local trusted = not (run.meta_failed or (run.reconcile_skipped and not run.remote))
    local BookDB = require("book.books_db")
    local rels = {}
    for rel in pairs(run.local_files) do rels[#rels + 1] = rel end
    table.sort(rels)
    local ids, paths = {}, {}
    for i, rel in ipairs(rels) do
        ids[i] = remoteStableId(rel)
        paths[i] = run.local_files[rel].path
    end
    local rows, local_rows = BookDB.getMany(SOURCE_ID, ids), BookDB.getMany(SOURCE_ID, paths)
    local pending = {}
    for i, rel in ipairs(rels) do
        local item, row = run.local_files[rel], rows[ids[i]]
        if remote[rel] then
            if trusted and not (row and row.deleted == 1 and row.sync_status == 0)
                and (not row or row.path ~= item.path or local_rows[item.path])
                and not adoptLocal(item, ids[i]) then return done(_("更新书籍身份失败")) end
        elseif not row and not local_rows[paths[i]] then
            pending[#pending + 1] = item
        end
        if trusted and uploadEnabled() and not remote[rel] and not (row and row.deleted == 1 and row.sync_status == 0)
            and os.time() - (self.upload_failed[rel] or 0) > UPLOAD_COOLDOWN then
            run.upload_pending = true
        end
    end
    local first_err
    eachAsync(pending, function(item, next_item, i)
        run.report(T(_("正在入库 %1"), item.name), i, #pending)
        run.active = self:indexOneAsync(item.path, function(ok, err)
            if run.cancelled then return end
            if not ok then
                first_err = first_err or err
                require("utils.log").warn("book webdav local index failed", item.path, err)
            end
            next_item()
        end)
    end, function(err)
        if first_err then run.push_error = T(_("本地书入库失败：%1"), tostring(first_err)) end
        done(err)
    end)
end










local function uploadLocal(self, run, done)
    if run.meta_failed or (run.reconcile_skipped and not run.remote) or not uploadEnabled() then return done() end
    local remote = run.remote or run.entries
    local BookDB = require("book.books_db")
    local rels = {}
    for rel in pairs(run.local_files) do rels[#rels + 1] = rel end
    table.sort(rels)
    local ids, paths = {}, {}
    for i, rel in ipairs(rels) do
        ids[i] = remoteStableId(rel)
        paths[i] = run.local_files[rel].path
    end
    local rows, local_rows = BookDB.getMany(SOURCE_ID, ids), BookDB.getMany(SOURCE_ID, paths)
    local pending = {}
    for i, rel in ipairs(rels) do
        local item, row = run.local_files[rel], rows[ids[i]]
        if remote[rel] then
            if not (row and row.deleted == 1 and row.sync_status == 0)
                and (not row or row.path ~= item.path or local_rows[item.path])
                and not adoptLocal(item, ids[i]) then return done(_("更新书籍身份失败")) end
        elseif not (row and row.deleted == 1 and row.sync_status == 0)
            and os.time() - (self.upload_failed[rel] or 0) > UPLOAD_COOLDOWN then
            pending[#pending + 1] = rel
        end
    end
    local member = {}
    for _idx, rel in ipairs(run.files) do member[rel] = true end
    local failed, first_err = 0, nil
    local stopped = false
    -- 传输层失败（超时 / 断网）说明后面的书也传不上去，本轮停手，别把 Wi-Fi 拖垮
    local function fail(rel, err, transport)
        failed = failed + 1
        first_err = first_err or err
        self.upload_failed[rel] = os.time()
        if transport then stopped = true end
    end
    eachAsync(pending, function(rel, next_item, i)
        if stopped then return next_item() end
        run.report(T(_("正在上传 %1"), rel), i, #pending)
        local item, stable_id = run.local_files[rel], remoteStableId(rel)
        local parent = rel:match("^(.+)/[^/]+$")
        run.active = self.dav:ensurePathAsync(self:webdavPath() .. (parent and "/" .. parent or ""),
            function(ok_dir, dir_err)
                if run.cancelled then return end
                if not ok_dir then
                    require("utils.log").warn("book webdav upload mkdir failed", rel, dir_err)
                    fail(rel, dir_err, true)
                    return next_item()
                end
                run.active = self.dav:putFileAsync(self:webdavPath() .. "/" .. rel, item.path, function(ok, err, code)
                    if run.cancelled then return end
                    if not ok then
                        require("utils.log").warn("book webdav upload failed", rel, err)
                        fail(rel, err, code == nil)
                        return next_item()
                    end
                    if not adoptLocal(item, stable_id) then
                        fail(rel, _("更新书籍身份失败"), false)
                        return next_item()
                    end
                    local row = BookDB.get(SOURCE_ID, stable_id)
                    BookDB.upsertRemote({
                        source_id = SOURCE_ID, stable_id = stable_id,
                        title = not (row and row.title) and stem(rel) or nil,
                    })
                    -- 文件上去了、书目还没写：标脏，书目写成才由 pushBooksSync 清脏。
                    -- 已同步而书目里没有的行会被下一轮当成别的设备删了，连本地原书一起删掉。
                    BookDB.setLibraryMembership(SOURCE_ID, stable_id, true)
                    if not member[rel] then
                        member[rel] = true
                        run.files[#run.files + 1] = rel
                    end
                    next_item()
                end)
            end)
    end, function(err)
        if failed > 0 then
            run.push_error = T(_("%1 本书上传失败：%2"), failed, tostring(first_err))
        end
        done(err)
    end)
end





local function uploadCovers(self, run, done)
    if not uploadEnabled() then return done() end
    local pending = {}
    for _idx, rel in ipairs(run.files) do
        if not run.covers[sidecarKey(rel)]
            and lfs.attributes(coverPath(remoteStableId(rel)), "mode") == "file" then
            pending[#pending + 1] = rel
        end
    end
    eachAsync(pending, function(rel, next_item, i)
        run.report(T(_("正在上传封面 %1"), rel), i, #pending)
        run.active = self.dav:putFileAsync(coverRemotePath(self, rel), coverPath(remoteStableId(rel)), function(ok, err)
            if run.cancelled then return end
            if not ok then require("utils.log").warn("book webdav cover upload failed", rel, err) end
            next_item()
        end, require("http.timeout").net(1))
    end, done)
end








local function writeBooksSync(self, list, remote_version, cb)
    local JSON = require("json")
    local version = math.max(remote_version or 0, knownVersion(self) or 0) + 1
    local device = require("utils.device_id").ensure()
    for _idx, entry in ipairs(list) do entry.syncVersion, entry.syncDevice = version, device end
    local ok_zlib, Zlib = pcall(require, "ffi/zlib")
    local data = ok_zlib and Zlib.zlib_compress(JSON.encode(#list > 0 and list or JSON.util.InitArray({})))
    if not data then return defer(cb, false, _("无法生成 WebDAV 书目文件")) end
    return putText(self, moonPath(self, "books.sync"), self:webdavCacheRoot() .. "/.books.sync.upload", data,
        function(ok, err)
            if ok then rememberVersion(self, version, device) end
            cb(ok, err)
        end)
end









local function pushBooksSync(self, run, done)
    if run.meta_failed or (run.reconcile_skipped and not run.remote) then return done() end
    local BookDB = require("book.books_db")
    local ids = {}
    for i, rel in ipairs(run.files) do ids[i] = remoteStableId(rel) end
    local rows = BookDB.getMany(SOURCE_ID, ids)
    local list, listed, dirty_ids = {}, {}, {}
    local changed = false
    for i, rel in ipairs(run.files) do
        local row, base = rows[ids[i]], run.entries[rel]
        if row and row.deleted == 1 and row.sync_status == 0 then
            changed = changed or base ~= nil
        elseif row then
            if row.sync_status == 0 then dirty_ids[#dirty_ids + 1] = ids[i] end
            local entry = rowEntry(self, row, rel, base)
            changed = changed or not base or not sameEntry(entry, base)
            listed[rel] = true
            list[#list + 1] = entry
        elseif base then
            listed[rel] = true
            list[#list + 1] = base
        end
    end
    for rel in pairs(run.entries) do
        if not listed[rel] then changed = true end
    end
    local function confirm()
        for _idx, stable_id in ipairs(dirty_ids) do BookDB.markSynced(SOURCE_ID, stable_id) end
        done()
    end
    if not changed then return confirm() end
    run.report(T(_("正在更新书目（%1 本）"), #list))
    run.active = writeBooksSync(self, list, run.version, function(ok, err)
        if run.cancelled then return end
        if not ok then
            require("utils.log").warn("book webdav books.sync upload failed", err)
            run.push_error = run.push_error or err
            return done()
        end
        confirm()
    end)
end








local function deleteRemoteBook(self, rel, cb)
    local cancelled, active = false, nil
    active = self.dav:deleteAsync(self:webdavPath() .. "/" .. rel, function(ok, err, code)
        if cancelled then return end
        if not ok and code ~= 404 then return cb(false, err) end
        local sidecars = { coverRemotePath(self, rel), progressRemotePath(self, rel),
            progressRemotePath(self, rel) .. ".json", notesRemotePath(self, rel) }
        eachAsync(sidecars, function(path, next_item)
            active = self.dav:deleteAsync(path, function()
                if not cancelled then next_item() end
            end)
        end, function() cb(true) end)
    end)
    return { cancel = function()
        cancelled = true
        if active and active.cancel then active:cancel() end
    end }
end









local function editBooksSync(self, rel, edit, cb)
    local cancelled, active = false, nil
    active = fetchText(self, moonPath(self, "books.sync"), self:webdavCacheRoot() .. "/.books.sync.edit",
        function(raw, get_err, missing)
        if cancelled then return end
        if not raw and not missing then return cb(false, get_err) end
        local decoded = {}
        if raw then decoded = decodeBooksSync(raw) end
        if type(decoded) ~= "table" then return cb(false, _("WebDAV 书目文件损坏，无法更新")) end
        local list, old, at = {}, nil, nil
        for _idx, entry in ipairs(decoded) do
            if type(entry) == "table" and entry.filename == rel then
                old, at = old or entry, at or #list + 1
            else
                list[#list + 1] = entry
            end
        end
        local entry = edit(old)
        if not old and not entry then return cb(true) end
        if entry then table.insert(list, at or #list + 1, entry) end
        active = writeBooksSync(self, list, listVersion(decoded), function(written, write_err)
            if not cancelled then cb(written, write_err) end
        end)
    end)
    return { cancel = function()
        cancelled = true
        if active and active.cancel then active:cancel() end
    end }
end






local function pushDeletes(self, run, done)
    local BookDB = require("book.books_db")
    local pending = {}
    for _idx, stable_id in ipairs(BookDB.pendingDeleteIds(SOURCE_ID)) do
        if remoteRelativePath(stable_id) then pending[#pending + 1] = stable_id end
    end
    run.deleted = run.deleted or 0
    eachAsync(pending, function(stable_id, next_item, i)
        local rel = remoteRelativePath(stable_id)
        run.report(_("正在同步删除的书"), i, #pending)
        run.active = deleteRemoteBook(self, rel, function(ok, err)
            if run.cancelled then return end
            if not ok then
                require("utils.log").warn("book webdav delete failed", rel, err)
                run.push_error = run.push_error or err
                return next_item()
            end
            run.active = editBooksSync(self, rel, function() return nil end, function(listed, edit_err)
                if run.cancelled then return end
                if not listed then run.push_error = run.push_error or edit_err end
                if listed and BookDB.remove(SOURCE_ID, stable_id) then run.deleted = run.deleted + 1 end
                next_item()
            end)
        end)
    end, done)
end



local SYNC_STEPS = {
    pushDeletes, pullBooksSync, scanLocal, pullProgress, pullCovers,
    indexLocal, enrichCached, uploadCovers, pushBooksSync,
}
local DIRTY_STEPS = { pushDeletes, pullBooksSync, pushBooksSync }





local function reconcileSkipped(self, run, done)
    if not run.reconcile_skipped then return done() end
    run.reconcile_skipped = nil
    pullBooksSync(self, run, done)
end

local REFRESH_STEPS = {
    pushDeletes, listBooks, scanLocal, pullBooksSync, pullProgress, pullCovers,
    indexLocal, enrichCached, uploadCovers, pushBooksSync, reconcileSkipped,
}


local UPLOAD_STEPS = { scanLocal, pullBooksSync, uploadLocal, uploadCovers, pushBooksSync, reconcileSkipped }




local queues = {}






local function serial(self, start)
    local key = self.cfg.webdav_url .. "\0" .. moonPath(self, "books.sync")
    local queue = queues[key] or {}
    queues[key] = queue
    local handle, released, begin = nil, false, nil
    local function release()
        if released then return end
        released = true
        local at
        for i = 1, #queue do if queue[i] == begin then at = i; break end end
        table.remove(queue, at)
        if #queue == 0 then
            if queues[key] == queue then queues[key] = nil end
        elseif at == 1 then
            queue[1]()
        end
    end
    begin = function() handle = start(release) end
    queue[#queue + 1] = begin
    if #queue == 1 then begin() end
    return { cancel = function()
        if handle and handle.cancel then handle:cancel() end
        release()
    end }
end








local function backgroundUpload(self, remote, report, done)
    if self._uploading then done(); return end
    self._uploading = true
    return serial(self, function(release)
        local run = { files = {}, entries = {}, covers = {}, cancelled = false, remote = remote, report = report }
        local index = 0
        local function finish(err)
            self._uploading = false
            release()
            err = err or run.push_error
            if err then require("utils.log").warn("book webdav background upload", err) end
            done(err)
        end
        local function nextStep(step_err)
            if run.cancelled then return end
            if step_err then return finish(step_err) end
            index = index + 1
            local step = UPLOAD_STEPS[index]
            if not step then return finish() end
            step(self, run, nextStep)
        end
        nextStep()
        return { cancel = function()
            run.cancelled = true
            self._uploading = false
            if run.active and run.active.cancel then run.active:cancel() end
        end }
    end)
end













function Webdav.scanWebdavAsync(self, cb, opts)
    local ok, err = self:validatePath()
    if not ok then
        return defer(cb, false, err)
    end
    opts = opts or {}
    local steps = opts.refresh and REFRESH_STEPS or opts.dirty_only and DIRTY_STEPS or SYNC_STEPS
    return serial(self, function(release)

        local run = { files = {}, entries = {}, covers = {}, cancelled = false,
            remote = steps == REFRESH_STEPS and {} or nil,
            report = opts.on_progress or function() end }
        local index = 0
        local function nextStep(step_err)
            if run.cancelled then return end
            if step_err then release(); return cb(false, step_err) end
            index = index + 1
            local step = steps[index]
            if not step then
                release()
                cb(true, nil, run.push_error)
                if run.upload_pending and not run.cancelled then
                    local function start(report, done) return backgroundUpload(self, run.remote, report, done) end
                    if opts.on_background then
                        opts.on_background(start)
                    else
                        start(function() end, function() end)
                    end
                end
                return
            end
            step(self, run, nextStep)
        end
        nextStep()
        return { cancel = function()
            run.cancelled = true
            if run.active and run.active.cancel then run.active:cancel() end
            for job in pairs(run.list_jobs or {}) do job:cancel() end
        end }
    end)
end





function Webdav.openWebdavAsync(self, stable_id, cb)
    local rel = remoteRelativePath(stable_id)
    if not rel then return defer(cb, nil, _("无效的 WebDAV 书籍路径")) end
    local target = self:webdavBookRoot() .. "/" .. rel
    if lfs.attributes(target, "mode") == "file" then return defer(cb, target) end
    if not self:isWebdav() then return defer(cb, nil, _("未配置 WebDAV，无法下载云端书籍")) end
    ensureParent(target)
    local part = target .. ".part"
    local cancelled = false
    local job = self.dav:getAsync(self:webdavPath() .. "/" .. rel, part, nil, function(ok, get_err)
        if cancelled then return end
        if not ok then
            os.remove(part)
            cb(nil, get_err or _("WebDAV 下载失败"))
            return
        end
        os.remove(target)
        if not os.rename(part, target) then
            cb(nil, _("无法保存 WebDAV 书籍"))
            return
        end
        cb(target)
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job:cancel() end
        os.remove(part)
    end }
end









function Webdav.pushBookAsync(self, stable_id, cover, cb)
    local rel = remoteRelativePath(stable_id)
    if not rel then return defer(cb, true) end
    local BookDB = require("book.books_db")
    -- upsertLocal 不标脏已有行；不标的话推送失败后下一轮 reconcile 会用远端书目把改动盖回去。
    BookDB.setLibraryMembership(SOURCE_ID, stable_id, true)
    return serial(self, function(release)
        local cancelled, active = false, nil
        local function pushEntry()
            active = editBooksSync(self, rel, function(base)
                local row = BookDB.get(SOURCE_ID, stable_id)
                return row and rowEntry(self, row, rel, base) or base
            end, function(listed, edit_err)
                if cancelled then return end
                if listed then BookDB.markSynced(SOURCE_ID, stable_id) end
                release()
                cb(listed, edit_err)
            end)
        end
        if not cover then
            pushEntry()
        else
            local remote, path = coverRemotePath(self, rel), coverPath(stable_id)
            local function afterCover(ok, err)
                if cancelled then return end
                if not ok then require("utils.log").warn("book webdav cover push failed", rel, err) end
                pushEntry()
            end
            if lfs.attributes(path, "mode") ~= "file" then
                active = self.dav:deleteAsync(remote, function(ok, err, code)
                    afterCover(ok or code == 404, err)
                end)
            else
                active = self.dav:ensurePathAsync(moonPath(self, "Cover"), function(ok_dir, dir_err)
                    if cancelled then return end
                    if not ok_dir then return afterCover(false, dir_err) end
                    active = self.dav:putFileAsync(remote, path, afterCover, require("http.timeout").net(1))
                end)
            end
        end
        return { cancel = function()
            cancelled = true
            if active and active.cancel then active:cancel() end
        end }
    end)
end








function Webdav.importWebdavAsync(self, temp_path, filename, cb)
    filename = filename:gsub("[/\\]", "_")
    if filename == "" then return defer(cb, nil, _("无效文件名")) end
    local BookDB = require("book.books_db")
    local cancelled, active = false, nil
    active = self.dav:listAsync(self:webdavPath(), function(entries, list_err)
        if cancelled then return end
        -- 根目录还不存在（首次使用）按空目录处理，上传前会建。
        local remote = {}
        for _idx, entry in ipairs(entries or {}) do remote[entry.name] = true end
        local stem_name, ext = filename:match("^(.*)(%.[^.]*)$")
        stem_name, ext = stem_name or filename, ext or ""
        local name, n = filename, 2
        while remote[name] or BookDB.get(SOURCE_ID, remoteStableId(name))
            or lfs.attributes(self:webdavBookRoot() .. "/" .. name) do
            name = string.format("%s (%d)%s", stem_name, n, ext)
            n = n + 1
        end
        if not entries then require("utils.log").dbg("book webdav import list failed", list_err) end
        active = self.dav:ensurePathAsync(self:webdavPath(), function(ok_dir, dir_err)
            if cancelled then return end
            if not ok_dir then return cb(nil, dir_err) end
            active = self.dav:putFileAsync(self:webdavPath() .. "/" .. name, temp_path, function(ok, put_err)
                if cancelled then return end
                if not ok then return cb(nil, put_err) end
                local stable_id = remoteStableId(name)
                BookDB.upsertRemote({ source_id = SOURCE_ID, stable_id = stable_id, deleted = 0, title = stem(name) })
                active = Webdav.pushBookAsync(self, stable_id, false, function(listed, err)
                    if not listed then require("utils.log").warn("book webdav import entry failed", name, err) end
                    if not cancelled then cb(true, nil, stable_id) end
                end)
            end)
        end)
    end)
    return { cancel = function()
        cancelled = true
        if active and active.cancel then active:cancel() end
    end }
end





function Webdav.testWebdavAsync(self, cb)
    if not self:isWebdav() then return defer(cb, false, _("未配置 WebDAV 地址")) end
    local valid, valid_err = self:validatePath()
    if not valid then return defer(cb, false, valid_err) end
    local remote = self:webdavPath() .. "/.moon-webdav-test"
    local upload = self:webdavCacheRoot() .. "/.test.upload"
    local download = self:webdavCacheRoot() .. "/.test.download"
    local token = "moon-webdav-test " .. os.time() .. " " .. math.random(1e9)
    if not writeFile(upload, token) then return defer(cb, false, _("无法创建测试文件")) end
    local cancelled, active = false, nil
    local function finish(ok, stage, err)
        os.remove(upload)
        os.remove(download)
        if cancelled then return end
        cb(ok, not ok and (stage .. (err or "")) or nil)
    end
    local function verify()
        if readFile(download) ~= token then finish(false, _("读回内容与写入不一致")); return end
        active = self.dav:deleteAsync(remote, function(ok, err)
            finish(ok == true, _("删除失败："), err)
        end)
    end
    active = self.dav:ensurePathAsync(self:webdavPath(), function(ok_dir, dir_err)
        if not ok_dir then finish(false, _("创建目录失败："), dir_err); return end
        active = self.dav:putFileAsync(remote, upload, function(ok_put, put_err)
            if not ok_put then finish(false, _("写入失败："), put_err); return end
            active = self.dav:getAsync(remote, download, nil, function(ok_get, get_err)
                if not ok_get then finish(false, _("读取失败："), get_err); return end
                verify()
            end)
        end)
    end)
    return { cancel = function()
        cancelled = true
        if active and active.cancel then active:cancel() end
        os.remove(upload)
        os.remove(download)
    end }
end

return Webdav
