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
local fetchText, putText = Common.fetchText, Common.putText
local remoteStableId, remoteRelativePath = Common.remoteStableId, Common.remoteRelativePath
local sidecarKey, stem, readFile, writeFile, field = Common.sidecarKey, Common.stem, Common.readFile, Common.writeFile, Common.field
local decodeProgress, eachAsync, coverPath = Common.decodeProgress, Common.eachAsync, Common.coverPath
local safeRel = Common.safeRel
local parseBookProps, scanFiles = Common.parseBookProps, Common.scanFiles
local moonPath, coverRemotePath = Common.moonPath, Common.coverRemotePath
local progressRemotePath, notesRemotePath = Common.progressRemotePath, Common.notesRemotePath

local Webdav = {}

-- 上传失败的书多久内不再自动重传（秒）；每轮同步都重传整个失败批次会拖垮网络
local UPLOAD_COOLDOWN = 3600

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
---@param self LocalClient
---@param row Book
---@param rel string
---@param base table|nil 远端原条目
---@return table
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
---@field upload_pending boolean|nil 是否还有待上传的本地书
---@field files string[] 本轮书架成员（相对路径）：books.sync 条目 + 未推的本地新增；刷新时再并入扫描结果
---@field entries table<string, table> books.sync 条目，按 filename
---@field remote table<string, boolean>|nil 刷新时列出的远端书文件；日常同步不列目录，为 nil
---@field local_files table<string, table>|nil 扫出的本地书库目录文件（相对路径 → scanFiles 条目；推脏不扫，为 nil）
---@field meta_failed boolean|nil books.sync 存在但读不出：本轮不能回写，否则会覆盖别的设备的书目
---@field reconcile_skipped boolean|nil 书目与远端列表都为空，本轮 pullBooksSync 没有 reconcile
---@field covers table<string, boolean> 远端已有封面的 sidecar 键
---@field report fun(text: string, done: integer|nil, total: integer|nil) 真实步骤上报
---@field active table|nil
---@field cancelled boolean
---@field deleted integer|nil 本轮推删成功（墓碑已撕）的本数
---@field push_error string|nil 本地改动没推上去的第一条原因（脏标记保留，本轮其余步骤照跑）

--- 刷新步骤：列远端书文件（跳过 . 前缀项，含 .Moon+）。列不出来就中止整轮：
--- 合并时把“无法确认”当成“不存在”会误删书目条目。层级与本地 scanFiles 一致：根 / 分类 / 系列，更深忽略。
---@param self LocalClient
---@param run WebdavRun
---@param done fun(err: string|nil)
local function listBooks(self, run, done)
    local function walk(path, prefix, depth, finish)
        run.report(T(_("正在列出远端目录 %1"), path))
        run.active = self.dav:listAsync(path, function(entries, err)
            if run.cancelled then return end
            if not entries then finish(err or "WebDAV list failed"); return end
            eachAsync(entries, function(entry, next_entry)
                if entry.name:sub(1, 1) == "." then return next_entry() end
                local rel = prefix ~= "" and prefix .. "/" .. entry.name or entry.name
                if entry.is_dir then
                    if depth >= 3 then return next_entry() end
                    return walk(entry.path, rel, depth + 1, function(walk_err)
                        if walk_err then finish(walk_err) else next_entry() end
                    end)
                end
                if isBookFile(entry.name) then run.remote[rel] = true end
                next_entry()
            end, function() finish() end)
        end)
    end
    -- 固定布局目录（书库根、.Moon+、Cache、Cover）不存在就建，已存在时 MKCOL 返回 405 视为成功。
    run.report(_("正在检查远端目录…"))
    run.active = self.dav:ensurePathAsync(moonPath(self, "Cache"), function(ok, err)
        if run.cancelled then return end
        if not ok then return done(err) end
        run.active = self.dav:ensurePathAsync(moonPath(self, "Cover"), function(ok_cover, cover_err)
            if run.cancelled then return end
            if not ok_cover then return done(cover_err) end
            walk(self:webdavPath(), "", 1, done)
        end)
    end)
end

--- 同步步骤：扫本地书库目录。扫不全就中止整轮：合并时会把“本地也没有”的条目删掉。
---@param self LocalClient
---@param run WebdavRun
---@param done fun(err: string|nil)
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
---@param done fun(err: string|nil)
local function pullBooksSync(self, run, done)
    run.report(_("正在下载书目…"))
    run.active = fetchText(self, moonPath(self, "books.sync"), self:webdavCacheRoot() .. "/.books.sync",
        function(raw, err, missing)
        if run.cancelled then return end
        -- 连不上、认证 / 权限错误：后面每一步都会同样失败，中止整轮把原因报给用户。
        if not raw and not missing then return done(err) end
        local decoded = raw and decodeBooksSync(raw)
        if type(decoded) == "table" then
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
            return done()
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
        local root, member = localRoot(self), {}
        for _idx, rel in ipairs(run.files) do member[rel] = true end
        for stable_id, row in pairs(before) do
            local rel = remoteRelativePath(stable_id)
            if root and rel and not member[rel] and row.sync_status == 1 and row.path == root .. "/" .. rel then
                os.remove(row.path)
                tombstone(stable_id)
            end
        end
        done()
    end)
end

--- 同步步骤：拉进度。版本以 .po 文件 mtime 为准，只下载比本地新的；本地脏行由 upsertRemote 保留。
---@param self LocalClient
---@param run WebdavRun
---@param done fun(err: string|nil)
local function pullProgress(self, run, done)
    local ProgressDB = require("book.progress_db")
    run.report(_("正在检查阅读进度…"))
    run.active = self.dav:listAsync(moonPath(self, "Cache"), function(entries, err)
        if run.cancelled then return end
        if not entries then
            require("utils.log").warn("book webdav progress list failed", err)
            return done()
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
        eachAsync(pending, function(item, next_item, i)
            run.report(T(_("正在下载进度 %1"), item.rel), i, #pending)
            run.active = fetchText(self, progressRemotePath(self, item.rel), self:webdavCacheRoot() .. "/.progress",
                function(raw)
                if run.cancelled then return end
                local pos = decodeProgress(raw)
                if pos then
                    pos.updated_at = item.mtime
                    ProgressDB.upsertRemote(SOURCE_ID, remoteStableId(item.rel), pos)
                end
                next_item()
            end)
        end, done)
    end)
end

--- 同步步骤：列远端封面，本地缺的下载下来。
---@param self LocalClient
---@param run WebdavRun
---@param done fun(err: string|nil)
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
        end, done)
    end)
end

--- 同步步骤：已下载到本地、却还没封面或书名还只是文件名的书，解析一次元数据和封面（子进程）。
--- （阅读时会话会先从已打开的文档补封面，所以不能只拿“缺封面”当没解析过。）
--- 解析结果只补空字段，已有值（远端书目或用户编辑）优先；每本书每个会话只试一次，
--- 本身没有封面的书不会每轮都重新打开。
---@param self LocalClient
---@param run WebdavRun
---@param done fun(err: string|nil)
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

---@param path string
---@return boolean
local function isOpenInReader(path)
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    local ui = ok and ReaderUI.instance
    return ui and ui.document and ui.document.file == path or false
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

--- 设置「上传本地书到 WebDAV」（默认开）；关了本地书不上传，也不会被当成待上传。
local function uploadEnabled()
    return require("utils.settings").getSource(SOURCE_ID).webdav_upload_local ~= false
end

--- 同步步骤：合并本地书库目录。远端已有的收编身份；远端没有的先在本地入库（按绝对路径登记，用户立刻能读），
--- 并标记 run.upload_pending，整轮同步结束后由后台上传（见 backgroundUpload），传成功再并成 WebDAV 书。
--- 入库是纯本地操作：远端书目读不出 / 远端为空被跳过时照常做，只是不收编、不上传（远端信息不可信）。
--- 本地已有行（含用户在 KOReader 删过的）不再重复解析。
---@param self LocalClient
---@param run WebdavRun
---@param done fun(err: string|nil)
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
            if trusted and (not row or row.path ~= item.path) then adoptLocal(item, ids[i]) end
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

--- 后台上传步骤（设置关了则跳过）：本地书库里远端没有的书上传到同一相对路径；成功后绝对路径身份并成 WebDAV 身份，进书目。
--- 书在入库（indexLocal）时已可阅读，这里只负责上云，不阻塞用户。
--- 刷新时「远端已有」以列出的远端文件为准（书目有条目、文件却丢了也补传）；日常同步不列目录，以书目为准。
--- 用户在 KOReader 删过、删除还没推上去的（脏墓碑）不传。
--- 日常同步遇到远端书库为空而本地书架非空（reconcile 被跳过）不传：此时写出的书目只含本地书，
--- 下一轮会把云端其余的书当成被删；留给会列远端目录的刷新处理。
---@param self LocalClient
---@param run WebdavRun
---@param done fun(err: string|nil)
local function uploadLocal(self, run, done)
    if run.meta_failed or (run.reconcile_skipped and not run.remote) or not uploadEnabled() then return done() end
    local remote = run.remote or run.entries
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
        if remote[rel] then
            if not row or row.path ~= item.path then adoptLocal(item, ids[i]) end
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
                    -- 正在阅读的书先不换身份（关书时进度会写回旧身份）；下一轮同步 indexLocal 再收编。
                    if not isOpenInReader(item.path) then adoptLocal(item, stable_id) end
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

--- 同步步骤：远端缺封面、本地有的，补传。
---@param self LocalClient
---@param run WebdavRun
---@param done fun(err: string|nil)
local function uploadCovers(self, run, done)
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
    end, done)
end

--- 书目整份写回：zlib 压缩 JSON；putText 先建 .Moon+（日常同步不列目录，远端可能还没有它）。
---@param self LocalClient
---@param list table[]
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
local function writeBooksSync(self, list, cb)
    local JSON = require("json")
    local ok_zlib, Zlib = pcall(require, "ffi/zlib")
    local data = ok_zlib and Zlib.zlib_compress(JSON.encode(#list > 0 and list or JSON.util.InitArray({})))
    if not data then return defer(cb, false, _("无法生成 WebDAV 书目文件")) end
    return putText(self, moonPath(self, "books.sync"), self:webdavCacheRoot() .. "/.books.sync.upload", data, cb)
end

--- 按本轮书架成员重建 books.sync，只在内容有变化时回写。
--- 条目在远端原条目上改（保留评分/分组等字段）；成员以外的条目、本地删过还没推的（脏墓碑）剔除；
--- 确认上传后清脏。上传失败保留脏标记，下一轮重试。脏墓碑不清脏：远端文件还没删掉，留给 pushDeletes 重试。
--- 远端书库为空而跳过了 reconcile 的日常同步 / 推脏不写：这时写出的书目只含本地脏行，
--- 下一轮会把其余的书当成别的设备删了，连本地下载一起删；留给会列远端目录的刷新。
---@param self LocalClient
---@param run WebdavRun
---@param done fun(err: string|nil)
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
    run.active = writeBooksSync(self, list, function(ok, err)
        if run.cancelled then return end
        if not ok then
            require("utils.log").warn("book webdav books.sync upload failed", err)
            run.push_error = run.push_error or err
            return done()
        end
        confirm()
    end)
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
--- cb(false, err) 表示书目没写成（读不出 / 写失败）。
---@param self LocalClient
---@param rel string
---@param edit fun(entry: table|nil): table|nil
---@param cb fun(listed: boolean, err: string|nil)
---@return { cancel: fun() }
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
        active = writeBooksSync(self, list, function(written, write_err)
            if not cancelled then cb(written, write_err) end
        end)
    end)
    return { cancel = function()
        cancelled = true
        if active and active.cancel then active:cancel() end
    end }
end

--- 推本地删除：逐本删远端书文件与边车、把条目剔出 books.sync，两样都成了才撕墓碑。
--- 云端的书只靠 books.sync 存活，远端文件已经不在也照样删书目条目。失败的留脏墓碑等下一轮。
---@param self LocalClient
---@param run WebdavRun
---@param done fun(err: string|nil)
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

--- 日常同步以 books.sync 为准，并扫本地书库目录、本地新书先入库、整轮结束后台再上传（扫在拉书目之后：别的设备删掉的书先删了本地那份，
--- 不会被当成新书传回去）；推脏只推删除与书目改动（改书目要先读远端）；刷新再列远端目录合并。
local SYNC_STEPS = {
    pushDeletes, pullBooksSync, scanLocal, pullProgress, pullCovers,
    indexLocal, enrichCached, uploadCovers, pushBooksSync,
}
local DIRTY_STEPS = { pushDeletes, pullBooksSync, pushBooksSync }

--- 刷新收尾：远端原本为空而跳过了 reconcile 时，按刚写出的书目再 reconcile 一次（服务端被清空后一轮收敛）。
---@param self LocalClient
---@param run WebdavRun
---@param done fun(err: string|nil)
local function reconcileSkipped(self, run, done)
    if not run.reconcile_skipped then return done() end
    run.reconcile_skipped = nil
    pullBooksSync(self, run, done)
end

local REFRESH_STEPS = {
    pushDeletes, listBooks, scanLocal, pullBooksSync, pullProgress, pullCovers,
    indexLocal, enrichCached, uploadCovers, pushBooksSync, reconcileSkipped,
}

--- 后台上传：重读书目再上传，不复用前台那一轮的快照（排队期间 books.sync 可能已被别的写入改过）。
local UPLOAD_STEPS = { scanLocal, pullBooksSync, uploadLocal, uploadCovers, pushBooksSync, reconcileSkipped }

--- books.sync 是整份读改写：两轮交错时后写的那份会盖掉先写的改动（删掉的书复活、新传的书丢条目）。
--- 锁跟着远端书目文件走、不跟源实例走：换源 / 重载配置后旧实例的同步可能还在飞。
---@type table<string, function[]> 书目 URL → 排队的启动函数，[1] 是正在跑的
local queues = {}

--- 同一书目文件上的读改写排队串行：轮到时调 start(release)，做完（含失败）必须调 release()。
--- 取消时没轮到的直接出队；已开始的先取消在飞操作再放行下一个。
---@param self LocalClient
---@param start fun(release: fun()): table|nil 返回可取消句柄
---@return { cancel: fun() }
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

--- 前台同步结束后把本地新书传上云：与前台同经 serial 排队，同一时间只跑一个；用户不用等。
--- 失败的书进冷却期，传输层失败本轮停手，下一次同步再试。
---@param self LocalClient
---@param remote table|nil 前台刷新列出的远端文件，传上来避免把远端已有的书重传
---@param report fun(text: string|nil, done: integer|nil, total: integer|nil) 进度
---@param done fun(err: string|nil) 整轮结束（含失败）
---@return { cancel: fun() }|nil
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

--- WebDAV 书库同步，布局与静读天下 / book 服务端共用：
---   <根>/[分类/]书文件                正文
---   <根>/.Moon+/books.sync            书目（zlib 压缩 JSON）；书架成员只以它为准
---   <根>/.Moon+/Cover/<文件名>_2.png   封面
---   <根>/.Moon+/Cache/<文件名>.po      进度
---   <根>/.Moon+/Stats/                 阅读统计：index.json 总表 + books/<md5>.json 按书（本插件私有，见 remote_data）
--- 正文不下载，openWebdavAsync 按需拉到本地书库目录。
--- 与单本上行同经 serial 排队：桌面同步、推脏、编辑上行不会交错读改写 books.sync。
---@param cb fun(ok: boolean, err: string|nil, push_error: string|nil) push_error=整轮跑完但有本地改动没推上去
---@param opts { refresh?: boolean, dirty_only?: boolean, on_progress?: fun(text: string, done: integer|nil, total: integer|nil), on_background?: fun(start: fun(report: function, done: fun(err: string|nil)): { cancel: fun() }|nil) }|nil on_background=有本地新书要上传时把后台上传交给调用方排队并展示进度；refresh=用户点刷新：另列远端文件合并；dirty_only=只推本地改动
---@return { cancel: fun() }|nil
---@param self LocalClient
function Webdav.scanWebdavAsync(self, cb, opts)
    local ok, err = self:validatePath()
    if not ok then
        return defer(cb, false, err)
    end
    opts = opts or {}
    local steps = opts.refresh and REFRESH_STEPS or opts.dirty_only and DIRTY_STEPS or SYNC_STEPS
    return serial(self, function(release)
        ---@type WebdavRun
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
        end }
    end)
end

---@param stable_id string
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
---@param self LocalClient
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
                    active = self.dav:putFileAsync(remote, path, afterCover)
                end)
            end
        end
        return { cancel = function()
            cancelled = true
            if active and active.cancel then active:cancel() end
        end }
    end)
end

--- 书城导入：传到书库根目录（远端或书库已有同名就加 " (n)"），登记进书架并写书目条目。
--- 书目没写成保留脏行，下一轮 pushBooksSync 补上；正文不留本地，打开时按需下载。
---@param temp_path string
---@param filename string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }|nil
---@param self LocalClient
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
        while remote[name] or BookDB.get(SOURCE_ID, remoteStableId(name)) do
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
                    if not cancelled then cb(true) end
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
