--[[--
本地源：WebDAV 书库。书目（.Moon+/books.sync）同步流水线、按需下载正文、删除、
单本上行、排版替换与连通性测试。布局与静读天下 / book 服务端共用，见 scanWebdavAsync。
函数首参即 LocalClient，由 source.local.client 装配为方法。

@module koplugin.book.source.local.webdav
--]]

local lfs = require("libs/libkoreader-lfs")
local Text = require("utils.text")
local _ = require("gettext")
local T = require("ffi/util").template
local Job = require("workers.job")
local Common = require("source.local.common")

local SOURCE_ID = Common.SOURCE_ID
local defer, isBookFile, localRoot, ensureParent = Common.defer, Common.isBookFile, Common.localRoot, Common.ensureParent
local remoteStableId, remoteRelativePath = Common.remoteStableId, Common.remoteRelativePath
local sidecarKey, stem, readFile, writeFile, field = Common.sidecarKey, Common.stem, Common.readFile, Common.writeFile, Common.field
local decodeProgress, eachAsync, coverPath = Common.decodeProgress, Common.eachAsync, Common.coverPath
local moveBookArtifacts, parseBookProps, scanFiles = Common.moveBookArtifacts, Common.parseBookProps, Common.scanFiles
local moonPath, coverRemotePath = Common.moonPath, Common.coverRemotePath
local progressRemotePath, notesRemotePath = Common.progressRemotePath, Common.notesRemotePath

local Webdav = {}

--- books.sync 的 category 首部系列前缀：`<系列>\n#编号#\n`。
local SERIES_PREFIX = "^<(.-)>%s*\n%s*#(.-)#%s*\n"

--- books.sync 条目 → books 行。契约与静读天下 / book 服务端一致：
--- favorite 才是分类；category 是换行分隔的标签集，首部可能带系列前缀。
---@param entry table
---@param rel string
---@return table
local function entryRow(entry, rel)
    local tags = type(entry.category) == "string" and entry.category or ""
    return {
        source_id = SOURCE_ID, stable_id = remoteStableId(rel),
        title = field(entry.bookName), authors = field(entry.author),
        intro = field(entry.description), category = field(entry.favorite),
        series = field(entry.series) or field(tags:match(SERIES_PREFIX)),
    }
end

--- books 行 → books.sync 条目。在远端原条目上改，评分、分组、添加时间等本插件不管的字段原样保留。
---@param row Book
---@param rel string
---@param base table|nil 远端原条目
---@param ctx { root: string, device_id: string, array: fun(t: table): table }
---@return table
local function rowEntry(row, rel, base, ctx)
    local entry = {}
    for k, v in pairs(base or {}) do entry[k] = v end
    if not base then
        entry.addTime = os.time() * 1000
        entry.deviceId = ctx.device_id
        entry.downloadUrl = "[WebDav]/" .. ctx.root .. "/" .. rel
        entry.coverUrl, entry.rate, entry.groupName = "", "0", ""
        entry.groupBooks = ctx.array({})
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

---@return boolean
local function sameEntry(a, b)
    for _idx, key in ipairs(ENTRY_FIELDS) do
        if tostring(a[key] or "") ~= tostring(b[key] or "") then return false end
    end
    return true
end

--- 解析 .Moon+/books.sync：明文 JSON，或 zlib 压缩的 JSON（解压尺寸未知，逐级试缓冲区）。
---@param raw string
---@return any|nil
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

--- WebDAV 同步的一轮状态；各步骤只读写这张表，run.active 是当前在飞的可取消句柄。
---@class WebdavRun
---@field files string[] 本轮书架成员（相对路径）：books.sync 条目 + 未推的本地新增；刷新时再并入扫描结果
---@field entries table<string, table> books.sync 条目，按 filename
---@field remote table<string, boolean>|nil 刷新时列出的远端书文件；日常同步不列目录，为 nil
---@field local_files table<string, table>|nil 刷新时扫出的本地书库目录文件（相对路径 → scanFiles 条目）
---@field meta_failed boolean|nil books.sync 存在但读不出：本轮不能回写，否则会覆盖别的设备的书目
---@field covers table<string, boolean> 远端已有封面的 sidecar 键
---@field report fun(text: string, done: integer|nil, total: integer|nil) 真实步骤上报
---@field active table|nil
---@field cancelled boolean

--- 刷新步骤：列远端书文件（跳过 . 前缀项，含 .Moon+）。列不出来就中止整轮：
--- 合并时把“无法确认”当成“不存在”会误删书目条目。
---@param self LocalClient
---@param run WebdavRun
---@param next fun(err: string|nil)
local function listBooks(self, run, next)
    local function walk(path, prefix, done)
        run.report(T(_("正在列出远端目录 %1"), path))
        run.active = self.dav:listAsync(path, function(entries, err)
            if run.cancelled then return end
            if not entries then done(err or "WebDAV list failed"); return end
            eachAsync(entries, function(entry, next_entry)
                if entry.name:sub(1, 1) == "." then return next_entry() end
                local rel = prefix ~= "" and prefix .. "/" .. entry.name or entry.name
                if entry.is_dir then
                    return walk(entry.path, rel, function(walk_err)
                        if walk_err then done(walk_err) else next_entry() end
                    end)
                end
                if isBookFile(entry.name) then run.remote[rel] = true end
                next_entry()
            end, function() done() end)
        end)
    end
    -- 固定布局目录（书库根、.Moon+、Cache、Cover）不存在就建，已存在时 MKCOL 返回 405 视为成功。
    run.report(_("正在检查远端目录…"))
    run.active = self.dav:ensurePathAsync(moonPath(self, "Cache"), function(ok, err)
        if run.cancelled then return end
        if not ok then return next(err) end
        run.active = self.dav:ensurePathAsync(moonPath(self, "Cover"), function(ok_cover, cover_err)
            if run.cancelled then return end
            if not ok_cover then return next(cover_err) end
            walk(self:webdavPath(), "", next)
        end)
    end)
end

--- 刷新步骤：扫本地书库目录。扫不全就中止整轮：合并时会把“本地也没有”的条目删掉。
---@param self LocalClient
---@param run WebdavRun
---@param next fun(err: string|nil)
local function scanLocal(self, run, next)
    run.local_files = {}
    local root = localRoot(self)
    if not root then return next() end
    run.report(_("正在扫描本地书库…"))
    run.active = Job.run(function()
        return scanFiles(root)
    end, {
        name = "local.webdav.scan",
        kind = "medium",
        on_done = function(files)
            if run.cancelled then return end
            for _idx, item in ipairs(files) do run.local_files[item.path:sub(#root + 2)] = item end
            next()
        end,
        on_failed = function(err)
            if not run.cancelled then next(err or "local scan failed") end
        end,
    })
end

--- 给这本书打墓碑（已下架且已同步），书架立即消失。
---@param stable_id string
local function tombstone(stable_id)
    local BookDB = require("book.books_db")
    BookDB.markDeleted(SOURCE_ID, stable_id)
    BookDB.markSynced(SOURCE_ID, stable_id)
end

--- 本轮书架成员：books.sync 条目 + 还没推上去的本地新增（脏行）。
--- 刷新时再按扫描结果合并：条目的文件远端、本地都没有就剔除；远端有文件却不在书目里的补进来。
---@param run WebdavRun
---@return string[]
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

--- 拉 books.sync，按书目 reconcile 书架（云端的书只靠 books.sync 存活）。
--- 远端元数据覆盖本地已同步行；本地脏行（用户编辑、删除）由 upsertRemote 保留，等 pushBooksSync 推上去。
--- 书目里没了的书（别的设备删了）：本地书库目录里已下载的那份跟着删。
---@param self LocalClient
---@param run WebdavRun
---@param next fun(err: string|nil)
local function pullBooksSync(self, run, next)
    local temp = self:webdavCacheRoot() .. "/.books.sync"
    ensureParent(temp)
    run.report(_("正在下载书目…"))
    run.active = self.dav:getAsync(moonPath(self, "books.sync"), temp, nil, function(ok, err, code)
        if run.cancelled then return end
        local raw = ok and readFile(temp)
        os.remove(temp)
        local decoded = raw and decodeBooksSync(raw)
        if type(decoded) == "table" then
            for _idx, entry in ipairs(decoded) do
                if type(entry) == "table" and type(entry.filename) == "string" then
                    run.entries[entry.filename] = entry
                end
            end
        elseif ok or code ~= 404 then
            -- 书目读不出来就不知道谁还活着：不 reconcile、不回写，只跑其余步骤。
            require("utils.log").warn("book webdav books.sync unreadable", err or "decode failed")
            run.meta_failed = true
            run.files = {}
            return next()
        end

        local BookDB = require("book.books_db")
        run.files = memberFiles(run)
        -- 书目为空而本地书架非空：首次同步，或目录填错 / 服务端异常。本轮不下架任何书，
        -- 但照常上传本地书、写书目（meta_failed 只表示书目读不出、不能回写）。
        local live = BookDB.libraryStableIdsBySource(SOURCE_ID)
        if #run.files == 0 and #live > 0 then
            require("utils.log").warn("book webdav remote library empty; skip reconcile")
            return next()
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
            return next("failed to save WebDAV book metadata")
        end
        local root, member = localRoot(self), {}
        for _idx, rel in ipairs(run.files) do member[rel] = true end
        for stable_id, row in pairs(before) do
            local rel = remoteRelativePath(stable_id)
            if root and rel and not member[rel] and row.sync_status == 1 and row.path == root .. "/" .. rel then
                os.remove(row.path)
                tombstone(stable_id)
            end
        end
        next()
    end)
end

--- 同步步骤：拉进度。版本以 .po 文件 mtime 为准，只下载比本地新的；本地脏行由 upsertRemote 保留。
---@param self LocalClient
---@param run WebdavRun
---@param next fun(err: string|nil)
local function pullProgress(self, run, next)
    local ProgressDB = require("book.progress_db")
    run.report(_("正在检查阅读进度…"))
    run.active = self.dav:listAsync(moonPath(self, "Cache"), function(entries, err)
        if run.cancelled then return end
        if not entries then
            require("utils.log").warn("book webdav progress list failed", err)
            return next()
        end
        local by_key = {}
        for _idx, rel in ipairs(run.files) do by_key[sidecarKey(rel)] = rel end
        local pending = {}
        for _idx, entry in ipairs(entries) do
            local rel = by_key[entry.name:match("^(.+)%.po$") or ""]
            local pos = rel and ProgressDB.get(SOURCE_ID, remoteStableId(rel))
            if rel and entry.mtime and (not pos or entry.mtime > (tonumber(pos.updated_at) or 0)) then
                pending[#pending + 1] = { rel = rel, mtime = entry.mtime }
            end
        end
        local temp = self:webdavCacheRoot() .. "/.progress"
        ensureParent(temp)
        eachAsync(pending, function(item, next_item, i)
            run.report(T(_("正在下载进度 %1"), item.rel), i, #pending)
            run.active = self.dav:getAsync(progressRemotePath(self, item.rel), temp, nil, function(ok)
                if run.cancelled then return end
                local pos = ok and decodeProgress(readFile(temp))
                os.remove(temp)
                if pos then
                    pos.updated_at = item.mtime
                    ProgressDB.upsertRemote(SOURCE_ID, remoteStableId(item.rel), pos)
                end
                next_item()
            end)
        end, function() next() end)
    end)
end

--- 同步步骤：列远端封面，本地缺的下载下来。
---@param self LocalClient
---@param run WebdavRun
---@param next fun(err: string|nil)
local function pullCovers(self, run, next)
    run.report(_("正在检查封面…"))
    run.active = self.dav:listAsync(moonPath(self, "Cover"), function(entries, err)
        if run.cancelled then return end
        if not entries then
            require("utils.log").warn("book webdav cover list failed", err)
            -- 远端封面状态未知：当作全都有，避免步骤 7 重复上传。
            for _idx, rel in ipairs(run.files) do run.covers[sidecarKey(rel)] = true end
            return next()
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
            run.active = self.dav:getAsync(coverRemotePath(self, rel), target .. ".part", nil, function(ok)
                if run.cancelled then return end
                if ok then
                    os.remove(target)
                    os.rename(target .. ".part", target)
                else
                    os.remove(target .. ".part")
                end
                next_item()
            end)
        end, function() next() end)
    end)
end

--- 同步步骤：已下载到本地、却还没封面或书名还只是文件名的书，解析一次元数据和封面（子进程）。
--- （阅读时会话会先从已打开的文档补封面，所以不能只拿“缺封面”当没解析过。）
--- 解析结果只补空字段，已有值（远端书目或用户编辑）优先；每本书每个会话只试一次，
--- 本身没有封面的书不会每轮都重新打开。
---@param self LocalClient
---@param run WebdavRun
---@param next fun(err: string|nil)
local function enrichCached(self, run, next)
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
    if #pending == 0 then return next() end
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
                local row, p = BookDB.get(SOURCE_ID, item.stable_id), props and props[i] or {}
                if row then
                    local title = (not row.title or row.title == stem(item.rel)) and p.title or row.title
                    BookDB.upsertLocal({
                        source_id = SOURCE_ID, stable_id = item.stable_id,
                        title = title, authors = row.authors or p.authors, intro = row.intro or p.intro,
                        category = row.category, series = row.series,
                    })
                end
            end
            next()
        end,
        on_failed = function(err)
            require("utils.log").warn("book webdav enrich failed", err)
            if not run.cancelled then next() end
        end,
    })
end

--- 本地目录里的文件收编为 webdav 身份：之前按绝对路径登记过（扫盘/从文件管理器打开）就整体并过来，
--- 进度、笔记、统计跟着走；否则只登记物理路径。
---@param item table scanFiles 条目
---@param stable_id string
local function adoptLocal(item, stable_id)
    local BookDB = require("book.books_db")
    if not BookDB.get(SOURCE_ID, item.path) then
        return BookDB.touchPath(SOURCE_ID, stable_id, item.path)
    end
    if lfs.attributes(coverPath(stable_id), "mode") ~= "file" then
        local cover = readFile(coverPath(item.path))
        if cover then writeFile(coverPath(stable_id), cover) end
    end
    return BookDB.adoptStableId(SOURCE_ID, item.path, stable_id, item.path)
end

--- 刷新步骤：合并本地书库目录。远端已有文件的收编身份；远端没有的上传到同一相对路径
--- （本地新书，或书目里有条目、远端文件却丢了），上传成功才进书架与书目。
--- 用户在 KOReader 删过、删除还没推上去的（脏墓碑）不传。
---@param self LocalClient
---@param run WebdavRun
---@param next fun(err: string|nil)
local function uploadLocal(self, run, next)
    if run.meta_failed then return next() end
    local BookDB = require("book.books_db")
    local rels = {}
    for rel in pairs(run.local_files) do rels[#rels + 1] = rel end
    table.sort(rels)
    local ids = {}
    for i, rel in ipairs(rels) do ids[i] = remoteStableId(rel) end
    local rows = BookDB.getMany(SOURCE_ID, ids)
    local pending = {}
    for i, rel in ipairs(rels) do
        local item, row = run.local_files[rel], rows[ids[i]]
        if run.remote[rel] then
            if not row or row.path ~= item.path then adoptLocal(item, ids[i]) end
        elseif not (row and row.deleted == 1 and row.sync_status == 0) then
            pending[#pending + 1] = rel
        end
    end
    local member = {}
    for _idx, rel in ipairs(run.files) do member[rel] = true end
    eachAsync(pending, function(rel, next_item, i)
        run.report(T(_("正在上传 %1"), rel), i, #pending)
        local item, stable_id = run.local_files[rel], remoteStableId(rel)
        local parent = rel:match("^(.+)/[^/]+$")
        run.active = self.dav:ensurePathAsync(self:webdavPath() .. (parent and "/" .. parent or ""),
            function(ok_dir, dir_err)
                if run.cancelled then return end
                if not ok_dir then
                    require("utils.log").warn("book webdav upload mkdir failed", rel, dir_err)
                    return next_item()
                end
                run.active = self.dav:putFileAsync(self:webdavPath() .. "/" .. rel, item.path, function(ok, err)
                    if run.cancelled then return end
                    if not ok then
                        require("utils.log").warn("book webdav upload failed", rel, err)
                        return next_item()
                    end
                    adoptLocal(item, stable_id)
                    local row = BookDB.get(SOURCE_ID, stable_id)
                    BookDB.upsertRemote({
                        source_id = SOURCE_ID, stable_id = stable_id, deleted = 0,
                        title = not (row and row.title) and stem(rel) or nil,
                    })
                    if not member[rel] then
                        member[rel] = true
                        run.files[#run.files + 1] = rel
                    end
                    next_item()
                end)
            end)
    end, function() next() end)
end

--- 刷新步骤：远端缺封面、本地有的，补传。
---@param self LocalClient
---@param run WebdavRun
---@param next fun(err: string|nil)
local function uploadCovers(self, run, next)
    local pending = {}
    for _idx, rel in ipairs(run.files) do
        if not run.covers[sidecarKey(rel)]
            and lfs.attributes(coverPath(remoteStableId(rel)), "mode") == "file" then
            pending[#pending + 1] = rel
        end
    end
    eachAsync(pending, function(rel, next_item, i)
        run.report(T(_("正在上传封面 %1"), rel), i, #pending)
        run.active = self.dav:putFileAsync(coverRemotePath(self, rel), coverPath(remoteStableId(rel)), function()
            if run.cancelled then return end
            next_item()
        end)
    end, function() next() end)
end

--- 书目整份写回：zlib 压缩 JSON，先确保 .Moon+ 目录存在（日常同步不列目录，远端可能还没有它）。
---@param self LocalClient
---@param list table[]
---@param cb fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function writeBooksSync(self, list, cb)
    local JSON = require("json")
    local ok_zlib, Zlib = pcall(require, "ffi/zlib")
    local temp = self:webdavCacheRoot() .. "/.books.sync.upload"
    ensureParent(temp)
    local data = ok_zlib and Zlib.zlib_compress(JSON.encode(#list > 0 and list or JSON.util.InitArray({})))
    if not data or not writeFile(temp, data) then
        defer(cb, false, "failed to encode books.sync")
        return nil
    end
    local cancelled, active = false, nil
    active = self.dav:ensurePathAsync(self:webdavPath() .. "/.Moon+", function(ok_dir, dir_err)
        if cancelled then return end
        if not ok_dir then os.remove(temp); return cb(false, dir_err) end
        active = self.dav:putFileAsync(moonPath(self, "books.sync"), temp, function(ok, err)
            os.remove(temp)
            if not cancelled then cb(ok and true or false, err) end
        end)
    end)
    return { cancel = function()
        cancelled = true
        if active and active.cancel then active:cancel() end
    end }
end

--- 按本轮书架成员重建 books.sync，只在内容有变化时回写。
--- 条目在远端原条目上改（保留评分/分组等字段）；成员以外的条目、本地删过还没推的（脏墓碑）剔除；
--- 确认上传后清脏。上传失败保留脏标记，下一轮重试。
---@param self LocalClient
---@param run WebdavRun
---@param next fun(err: string|nil)
local function pushBooksSync(self, run, next)
    if run.meta_failed then return next() end
    local BookDB = require("book.books_db")
    local ids = {}
    for i, rel in ipairs(run.files) do ids[i] = remoteStableId(rel) end
    local rows = BookDB.getMany(SOURCE_ID, ids)
    local ctx = {
        root = self:webdavPath(),
        device_id = require("utils.device_id").ensure(),
        array = require("json").util.InitArray,
    }
    local list, listed, dirty_ids = {}, {}, {}
    local changed = false
    for i, rel in ipairs(run.files) do
        local row, base = rows[ids[i]], run.entries[rel]
        if row and row.sync_status == 0 then dirty_ids[#dirty_ids + 1] = ids[i] end
        if row and row.deleted == 1 and row.sync_status == 0 then
            changed = changed or base ~= nil
        elseif row then
            local entry = rowEntry(row, rel, base, ctx)
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
        next()
    end
    if not changed then return confirm() end
    run.report(T(_("正在更新书目（%1 本）"), #list))
    run.active = writeBooksSync(self, list, function(ok, err)
        if run.cancelled then return end
        if not ok then
            require("utils.log").warn("book webdav books.sync upload failed", err)
            return next()
        end
        confirm()
    end)
end

--- 日常同步只认 books.sync（加进度 / 封面边车）；刷新再扫远端与本地目录合并。
local SYNC_STEPS = { pullBooksSync, pullProgress, pullCovers, enrichCached, pushBooksSync }
local REFRESH_STEPS = {
    listBooks, scanLocal, pullBooksSync, pullProgress, pullCovers,
    enrichCached, uploadLocal, uploadCovers, pushBooksSync,
}

--- WebDAV 书库同步，布局与静读天下 / book 服务端共用：
---   <根>/[分类/]书文件                正文
---   <根>/.Moon+/books.sync            书目（zlib 压缩 JSON）；书架成员只以它为准
---   <根>/.Moon+/Cover/<文件名>_2.png   封面
---   <根>/.Moon+/Cache/<文件名>.po      进度
---   <根>/.Moon+/Stats/stats.json       阅读统计（本插件私有，所有设备共用）
--- 正文不下载，openWebdavAsync 按需拉到本地书库目录。
---@param cb fun(ok: boolean, err: string|nil)
---@param opts { refresh?: boolean, on_progress?: fun(text: string, done: integer|nil, total: integer|nil) }|nil refresh=用户点刷新：另扫远端文件与本地目录合并
---@return { cancel: fun() }|nil
---@param self LocalClient
function Webdav.scanWebdavAsync(self, cb, opts)
    local ok, err = self:validatePath()
    if not ok then
        return defer(cb, false, err)
    end
    local steps = opts and opts.refresh and REFRESH_STEPS or SYNC_STEPS
    ---@type WebdavRun
    local run = { files = {}, entries = {}, covers = {}, cancelled = false,
        remote = steps == REFRESH_STEPS and {} or nil,
        report = opts and opts.on_progress or function() end }
    local index = 0
    local function nextStep(step_err)
        if run.cancelled then return end
        if step_err then return cb(false, step_err) end
        index = index + 1
        local step = steps[index]
        if not step then return cb(true) end
        step(self, run, nextStep)
    end
    nextStep()
    return { cancel = function()
        run.cancelled = true
        if run.active and run.active.cancel then run.active:cancel() end
    end }
end

---@param stable_id string
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
---@param self LocalClient
function Webdav.openWebdavAsync(self, stable_id, cb)
    local rel = remoteRelativePath(stable_id)
    if not rel then cb(nil, _("无效的 WebDAV 书籍路径")); return nil end
    local target = self:webdavBookRoot() .. "/" .. rel
    local attr = lfs.attributes(target, "mode")
    if attr == "file" then
        defer(cb, target)
        return { cancel = function() end }
    end
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

--- 删远端书文件，再顺手删它的封面、进度和笔记边车。
--- 边车删不掉（多半是本来就没有，404）不影响结果：书文件没了，边车就再也不会被引用。
--- 书文件已经不在（404）照样算删成功。
---@param self LocalClient
---@param rel string
---@param cb fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
local function deleteRemoteBook(self, rel, cb)
    local cancelled, active = false, nil
    active = self.dav:deleteAsync(self:webdavPath() .. "/" .. rel, function(ok, err, code)
        if cancelled then return end
        if not ok and code ~= 404 then return cb(false, err) end
        local sidecars = { coverRemotePath(self, rel), progressRemotePath(self, rel), notesRemotePath(self, rel) }
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

--- 读改写 books.sync 里 filename=rel 的条目：edit(原条目|nil) 返回新条目（原位替换，原来没有则追加），
--- 返回 nil 即删除；原来没有且 edit 也不给时不回写。书目不存在（404）按空书目处理。
--- cb(false) 表示书目没写成（读不出 / 写失败）。
---@param self LocalClient
---@param rel string
---@param edit fun(entry: table|nil): table|nil
---@param cb fun(listed: boolean)
---@return { cancel: fun() }
local function editBooksSync(self, rel, edit, cb)
    local temp = self:webdavCacheRoot() .. "/.books.sync.edit"
    ensureParent(temp)
    local cancelled, active = false, nil
    active = self.dav:getAsync(moonPath(self, "books.sync"), temp, nil, function(ok, _err, code)
        if cancelled then return end
        local raw = ok and readFile(temp)
        os.remove(temp)
        if not ok and code ~= 404 then return cb(false) end
        local decoded = {}
        if ok then decoded = raw and decodeBooksSync(raw) end
        if type(decoded) ~= "table" then return cb(false) end
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
        active = writeBooksSync(self, list, function(written)
            if not cancelled then cb(written) end
        end)
    end)
    return { cancel = function()
        cancelled = true
        if active and active.cancel then active:cancel() end
    end }
end

--- 删除 WebDAV 书：远端书文件与边车、本地镜像 / 缓存里的这本书，最后把条目从 books.sync 里删掉。
--- 云端的书只靠 books.sync 存活，远端文件已经不在也照样删书目条目。
--- listed=false 表示书目没写成（读不出/写失败），调用方留脏墓碑，下一轮 pushBooksSync 补删。
---@param stable_id string
---@param cb fun(ok: boolean, err: string|nil, listed: boolean|nil)
---@return { cancel: fun() }|nil
---@param self LocalClient
function Webdav.deleteWebdavAsync(self, stable_id, cb)
    local rel = remoteRelativePath(stable_id)
    if not rel then cb(false, _("无效的 WebDAV 书籍路径")); return nil end
    local cancelled, active = false, nil
    active = deleteRemoteBook(self, rel, function(ok, err)
        if cancelled then return end
        if not ok then return cb(false, err) end
        os.remove(self:webdavBookRoot() .. "/" .. rel)
        active = editBooksSync(self, rel, function() return nil end, function(listed)
            if not cancelled then cb(true, nil, listed) end
        end)
    end)
    return { cancel = function()
        cancelled = true
        if active and active.cancel then active:cancel() end
    end }
end

--- 单本书元数据立即上行（编辑 / 刮削后）：cover=true 时先把本地封面传上去，本地没封面就删远端封面
--- （否则下一轮 pullCovers 会把旧封面拉回来）；再把这本书的条目写进 books.sync，写成才清脏。
--- 非 webdav:// 身份没有远端，直接成功。书目没写成保留脏标记，下一轮 pushBooksSync 重试。
---@param stable_id string
---@param cover boolean 封面是否换过
---@param cb fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
---@param self LocalClient
function Webdav.pushBookAsync(self, stable_id, cover, cb)
    local rel = remoteRelativePath(stable_id)
    if not rel then return defer(cb, true) end
    local BookDB = require("book.books_db")
    -- upsertLocal 不标脏已有行；不标的话推送失败后下一轮 reconcile 会用远端书目把改动盖回去。
    BookDB.setLibraryMembership(SOURCE_ID, stable_id, true)
    local cancelled, active = false, nil
    local function pushEntry()
        local ctx = {
            root = self:webdavPath(),
            device_id = require("utils.device_id").ensure(),
            array = require("json").util.InitArray,
        }
        active = editBooksSync(self, rel, function(base)
            local row = BookDB.get(SOURCE_ID, stable_id)
            return row and rowEntry(row, rel, base, ctx) or base
        end, function(listed)
            if cancelled then return end
            if not listed then return cb(false, _("更新书目失败")) end
            BookDB.markSynced(SOURCE_ID, stable_id)
            cb(true)
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
                active = self.dav:putFileAsync(remote, path, afterCover)
            end)
        end
    end
    return { cancel = function()
        cancelled = true
        if active and active.cancel then active:cancel() end
    end }
end

--- 用转换后的临时 EPUB 替换 WebDAV 书（同目录同名 .epub）。
--- 顺序：查远端重名 → 传新文件 → 书目条目改名（其余字段原样保留）→ 换本地文件、迁移身份与 .sdr/封面 →
--- 删远端原书及其边车。书目写成之前失败都撤掉已传的新文件，远端与本地保持原样；
--- 之后的远端清理失败只记日志（新书已生效）。临时文件失败时留给调用方清理。
---@param temp_path string
---@param stable_id string webdav://rel
---@param cb fun(new_path: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
---@param self LocalClient
function Webdav.replaceWebdavAsync(self, temp_path, stable_id, cb)
    local rel = remoteRelativePath(stable_id)
    if not rel then return defer(cb, nil, _("无效的 WebDAV 书籍路径")) end
    local new_rel = rel:gsub("%.[^./]+$", ".epub")
    if new_rel == rel then return defer(cb, nil, _("原书已经是 EPUB")) end
    local BookDB = require("book.books_db")
    local new_id, name = remoteStableId(new_rel), sidecarKey(new_rel)
    local root = self:webdavBookRoot()
    local old_path, new_path = root .. "/" .. rel, root .. "/" .. new_rel
    local taken = BookDB.get(SOURCE_ID, new_id)
    if lfs.attributes(new_path) or (taken and taken.deleted ~= 1) then
        return defer(cb, nil, _("目标位置已有同名文件：") .. name)
    end
    local parent = rel:match("^(.+)/[^/]+$")
    local remote_new = self:webdavPath() .. "/" .. new_rel
    local cancelled, active = false, nil

    local function swapLocal()
        ensureParent(new_path)
        local placed, place_err = os.rename(temp_path, new_path)
        if not placed then return _("放置转换文件失败：") .. tostring(place_err) end
        if not BookDB.adoptStableId(SOURCE_ID, stable_id, new_id, new_path) then
            os.rename(new_path, temp_path)
            return _("更新书籍身份失败")
        end
        os.remove(old_path)
        -- 封面缓存按身份寻址，.sdr 按物理路径寻址。
        moveBookArtifacts(stable_id, new_id)
        moveBookArtifacts(old_path, new_path)
    end

    active = self.dav:listAsync(self:webdavPath() .. (parent and "/" .. parent or ""), function(entries, list_err)
        if cancelled then return end
        if not entries then return cb(nil, list_err) end
        for i = 1, #entries do
            if not entries[i].is_dir and entries[i].name == name then
                return cb(nil, _("目标位置已有同名文件：") .. name)
            end
        end
        active = self.dav:putFileAsync(remote_new, temp_path, function(ok, put_err)
            if cancelled then return end
            if not ok then return cb(nil, put_err) end
            active = editBooksSync(self, rel, function(entry)
                local renamed = {}
                for k, v in pairs(entry or {}) do renamed[k] = v end
                renamed.filename = new_rel
                if renamed.downloadUrl then renamed.downloadUrl = "[WebDav]/" .. remote_new end
                return renamed
            end, function(listed)
                if cancelled then return end
                if not listed then
                    self.dav:deleteAsync(remote_new, function() end)
                    return cb(nil, _("更新书目失败"))
                end
                local swap_err = swapLocal()
                if swap_err then return cb(nil, swap_err) end
                active = deleteRemoteBook(self, rel, function(deleted, del_err)
                    if not deleted then
                        require("utils.log").warn("book webdav replace cleanup failed", rel, del_err)
                    end
                    if not cancelled then cb(new_path) end
                end)
            end)
        end)
    end)
    return { cancel = function()
        cancelled = true
        if active and active.cancel then active:cancel() end
    end }
end


--- 连通性测试：在书库目录写入探针文件、读回比对、再删除。
---@param cb fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
---@param self LocalClient
function Webdav.testWebdavAsync(self, cb)
    if not self:isWebdav() then cb(false, _("未配置 WebDAV 地址")); return nil end
    local valid, valid_err = self:validatePath()
    if not valid then cb(false, valid_err); return nil end
    local remote = self:webdavPath() .. "/.moon-webdav-test"
    local upload = self:webdavCacheRoot() .. "/.test.upload"
    local download = self:webdavCacheRoot() .. "/.test.download"
    local token = "moon-webdav-test " .. os.time() .. " " .. math.random(1e9)
    ensureParent(upload)
    local file = io.open(upload, "wb")
    local written = file and file:write(token)
    local closed = file and file:close()
    if not (written and closed) then
        os.remove(upload)
        cb(false, _("无法创建测试文件"))
        return nil
    end
    local cancelled, active = false, nil
    local function finish(ok, stage, err)
        os.remove(upload)
        os.remove(download)
        if cancelled then return end
        cb(ok, not ok and (stage .. (err or "")) or nil)
    end
    local function verify()
        local f = io.open(download, "rb")
        local got = f and f:read("*a")
        if f then f:close() end
        if got ~= token then finish(false, _("读回内容与写入不一致")); return end
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
