--[[--
本地源：本地书库目录扫盘、导入、移动、排版替换、单本索引。
扫盘与补齐拆开：
  扫盘子进程只列目录 / 算指纹与 md5 / 新书用文件名入库，**不开文档**；
  批内落 local_scan + books，中断后续扫接着指纹走（续扫）；
  扫完（或库已最新）另开补齐子进程：缺封面且未试过的书开引擎提封面并补元数据，
  cover_tried 逐本落盘，取消 / 崩溃后续跑只啃剩下的。
落库在主进程；子进程不碰 sqlite。函数首参即 LocalClient，由 source.local.client 装配为方法。

@module koplugin.book.source.local.scan
--]]

local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local Text = require("utils.text")
local _ = require("gettext")
local T = require("ffi/util").template
local Job = require("workers.job")
local Perf = require("utils.perf")
local Common = require("source.local.common")

local SOURCE_ID = Common.SOURCE_ID
local defer, isBookFile, rootPath, coverPath = Common.defer, Common.isBookFile, Common.rootPath, Common.coverPath
local moveBookArtifacts = Common.moveBookArtifacts
local parseBookProps, scanFiles = Common.parseBookProps, Common.scanFiles
local remoteRelativePath = Common.remoteRelativePath
local ScanDB = require("source.local.scan_db")

local Scan = {}

local SCAN_BATCH = 100

--- 从文件名解析标题与作者（引擎解析失败时的兜底，保证扫到的书都入库）。
--- 支持格式："作者 - 书名.ext" / "书名 - 作者.ext" / "书名.ext"
---@param filename string
---@return string title, string|nil authors
local function parseFilename(filename)
    local name = filename:gsub("%.[^.]+$", "")
    name = Text.trim(name:gsub("[%[%(].-[%]%)]", ""))
    -- "作者 - 书名"（含空格的分隔符优先）
    local a, b = name:match("^(.+)%s+%-%s+(.+)$")
    if a and b then
        return b, a
    end
    -- "书名 - 作者"（无空格分隔符）
    a, b = name:match("^(.+)%-(.+)$")
    if a and b then
        return a, b
    end
    return name, nil
end

--- 扫盘的进程边界：
---   子进程只做文件系统轻活（遍历、md5），**不碰 sqlite、不开文档**。
---   主进程在 fork 前查好已入库行；批内落索引与书库；扫完再开补齐子进程提封面。

--- 主进程：扫盘解析过的行（有 md5 且有书名），按 stable_id（即路径）索引；
--- 另附全部行（含残缺行与墓碑）的内容 md5，供子进程识别同路径换了文件；以及全部行本身。
---@return table<string, Book> known, table<string, string> digests, table<string, Book> rows
local function knownBooks()
    local BookDB = require("book.books_db")
    local rows = BookDB.getMany(SOURCE_ID, BookDB.stableIdsBySource(SOURCE_ID))
    local known, digests = {}, {}
    for stable_id, row in pairs(rows) do
        digests[stable_id] = row.md5
        -- md5 只由扫盘/入库写入，有它就说明按当前内容对过账；作者/简介缺失多半是书本身没有。
        -- 无 md5 的身份行（开书时登记）下一轮扫盘当新书用文件名补齐，封面留给补齐进程。
        if row.md5 and type(row.title) == "string" and row.title ~= "" then
            known[stable_id] = row
        end
    end
    return known, digests, rows
end

--- 盘上与库里已经一致：每本都解析过、内容没变、在架且已确认，库里也没有盘上之外的在架已确认书。
--- 这时 commitFiles 的 reconcile + 清脏全是空写（几百行，主线程），整轮跳过。
---@param files table[] parseFile 产物
---@param known table<string, Book>
---@param rows table<string, Book> 本源全部行
---@param flat boolean|nil 关闭「按文件夹分类」：分类 / 系列不由目录派生，不参与比较
---@return boolean ok, string|nil err
local function upToDate(files, known, rows, flat, kept)
    local shelved = 0
    for _id, row in pairs(rows) do
        if row.deleted == 0 and row.sync_status == 1 then shelved = shelved + 1 end
    end
    if shelved ~= #files + #kept then return false end
    for _idx, f in ipairs(files) do
        local row = known[f.path]
        if not row or f.changed or row.md5 ~= f.md5 or row.deleted ~= 0 or row.sync_status ~= 1
            or row.path ~= f.path
            -- 打开「按文件夹分类」后分类 / 系列与目录不一致：要整轮写库
            or not flat and ((row.category or "") ~= (f.category or "") or (row.series or "") ~= (f.series or "")) then
            return false
        end
    end
    return true
end

--- 子进程轻解析：只算 md5；已入库且内容没变直接返回；新书 / 换内容用文件名标题，不开文档。
--- 同路径内容变了（删书后拷入同名新书 / 覆盖上传）标 changed 并删掉旧封面，cover_tried 清掉留给补齐。
---@param f table 扫描产物 { name, path, category, series, fp }
---@param known table<string, Book>
---@param digests table<string, string> 库内各路径的内容 md5
---@param index LocalScanIndex 上轮扫盘索引（local_scan 表）
---@return table f
local function parseFile(f, known, digests, index)
    local seen = index[f.path]
    f.md5 = seen and f.fp and seen.fp == f.fp and seen.md5 or util.partialMD5(f.path)
    f.cover_tried = seen and f.md5 and seen.md5 == f.md5 and seen.cover or nil
    local old = digests[f.path]
    f.changed = f.md5 ~= nil and old ~= nil and old ~= f.md5
    if f.changed then
        os.remove(coverPath(f.path))
        f.cover_tried = nil
    elseif known[f.path] then
        return f
    end
    f.title, f.authors = parseFilename(f.name)
    return f
end

--- 新路径是不是某本在架旧书移动/改名而来：新路径库里无任何行（known 不含元数据残缺行，要查库），
--- 且同 md5 的在架行里有文件已不在盘上的。同内容副本可以并存，必须挑真正被移走的那本，
--- 不能随便取一行：取到还在盘上的副本就会把移动当成新书，旧书的进度笔记留在下架行上。
---@param f table parseFile 产物
---@return Book|nil
local function movedFrom(f)
    local BookDB = require("book.books_db")
    if not f.md5 or BookDB.get(SOURCE_ID, f.path) then return nil end
    for _idx, stable_id in ipairs(BookDB.stableIdsByMd5(SOURCE_ID, f.md5)) do
        if not lfs.attributes(stable_id, "mode") then return BookDB.get(SOURCE_ID, stable_id) end
    end
end

--- 主进程：把子进程解析结果写入 books 表。
--- 已入库且内容未变的行只恢复书架成员（changed 行按新解析结果重写）；未命中时按 movedFrom 找移动来源（墓碑不收编），
--- 原地换 stable_id（身份以 md5 为准，不当新书），category/series 随新位置刷新；同内容副本并存时各自成书。
---@param files table[] parseFile 产物
---@param known table<string, Book>
---@param full_snapshot boolean|nil
---@param kept Book[]|nil 读不了的子目录下原有的在架行：不在快照里也照留
---@return boolean ok, string|nil err
local function commitFiles(files, known, full_snapshot, kept)
    local BookDB = require("book.books_db")
    for _idx, f in ipairs(files) do
        local cached = known[f.path]
        local moved = not cached and movedFrom(f)
        if moved then
            if not BookDB.renameStableId(SOURCE_ID, moved.stable_id, f.path, f.category, f.series) then
                return false, "rename " .. f.path
            end
            moveBookArtifacts(moved.stable_id, f.path)
        end
        if full_snapshot then
            f.source_id = SOURCE_ID
            f.stable_id = f.path
            f.deleted = 0
        end
        if cached and not f.changed then
            if not full_snapshot and cached.deleted ~= 0
                and not BookDB.setLibraryMembership(SOURCE_ID, f.path, true) then
                return false, "restore " .. f.path
            end
        -- knownBooks 只把解析过的行交给 worker；移动过来的旧行也会
        -- 在这里用本次解析结果补齐。不要把“已存在”误当成“无需更新”。
        -- 换了内容的行即便走快照也要本地可信写入：reconcile 对脏行保留旧书名。
        elseif (f.changed or not full_snapshot) and not BookDB.upsert({
            source_id = SOURCE_ID, stable_id = f.path, md5 = f.md5,
            title = f.title, authors = f.authors, intro = f.intro, meta = { language = f.language },
            category = f.category, series = f.series,
            inserted_at = moved and moved.inserted_at or os.time(), path = f.path,
        }) then
            return false, "upsert " .. f.path
        end
        if f.changed then
            require("ui.themes.widgets.image").invalidate(coverPath(f.path))
        end
        -- 批内续扫：后续 movedFrom / 去重认得出本轮刚写入的行
        if not cached or f.changed then
            known[f.path] = BookDB.get(SOURCE_ID, f.path) or known[f.path]
        end
    end
    if not full_snapshot then return true end
    -- 盘上就是真相：扫盘成功时空目录也要下架；读不了的子目录下原有的书由 kept 保留。
    local snapshot = files
    if kept and kept[1] then
        snapshot = {}
        for i, f in ipairs(files) do snapshot[i] = f end
        for _idx, row in ipairs(kept) do snapshot[#snapshot + 1] = row end
    end
    if not BookDB.reconcile(SOURCE_ID, snapshot, { clear_missing_paths = true, allow_empty = true }) then return false, "reconcile" end
    -- 库目录就是纯本地书的“远端”：扫到即确认。不清脏的话文件被外部删掉后 reconcile 永远不下架它。
    -- 库目录外开过的书不在快照里，保持脏行，不被下架。
    local ids = {}
    for i, f in ipairs(files) do ids[i] = f.path end
    if not BookDB.markSyncedMany(SOURCE_ID, ids) then return false, "mark synced" end
    return true
end

--- 把一条 cover_tried 写进 local_scan（补齐逐本落盘，中断后续跑）。
---@param index LocalScanIndex
---@param path string
---@param fp string|nil
---@param md5 string|nil
local function markCoverTried(index, path, fp, md5)
    local was = index[path]
    ScanDB.save(index, {
        { path = path, fp = fp or (was and was.fp) or "", md5 = md5 or (was and was.md5), cover_tried = true },
    }, true)
end

--- 补齐：缺封面且未试过的在架本地书，子进程开引擎提封面并升级元数据；已有封面只记 tried。
--- 可取消；崩溃记 skip 并落 tried，避免每轮同书再崩；没做完的下次 ensureEnrich 接着啃。
---@param self LocalClient
---@param cb fun()|nil
---@param report fun(text: string, done: integer|nil, total: integer|nil)|nil
---@return { cancel: fun() }
function Scan.enrichAsync(self, cb, report)
    report = report or function() end
    cb = cb or function() end
    local index = ScanDB.all()
    local BookDB = require("book.books_db")
    local rows = BookDB.getMany(SOURCE_ID, BookDB.stableIdsBySource(SOURCE_ID))
    local pending = {}
    for path, row in pairs(rows) do
        if row.deleted == 0 and type(row.path) == "string" and remoteRelativePath(path) == nil then
            local seen = index[path]
            if not (seen and seen.cover) then
                pending[#pending + 1] = {
                    path = path,
                    fp = seen and seen.fp,
                    md5 = row.md5 or (seen and seen.md5),
                    has_cover = lfs.attributes(coverPath(path), "mode") == "file",
                }
            end
        end
    end
    table.sort(pending, function(a, b) return a.path < b.path end)
    if #pending == 0 then
        return defer(cb)
    end

    self._crashed = self._crashed or {}
    local skip = self._crashed
    local job
    local function start()
        local opening
        local todo = {}
        for _idx, item in ipairs(pending) do
            if item.has_cover then
                markCoverTried(index, item.path, item.fp, item.md5)
            elseif not skip[item.path] then
                todo[#todo + 1] = item
            else
                markCoverTried(index, item.path, item.fp, item.md5)
            end
        end
        if #todo == 0 then return cb() end
        report(_("正在补齐封面…"), 0, #todo)
        job = Job.run(function(progress)
            local out = {}
            for i, item in ipairs(todo) do
                progress({ i, #todo, item.path:match("([^/]+)$") or item.path })
                progress(item.path)
                local props = parseBookProps(item.path) or {}
                progress(false)
                out[#out + 1] = {
                    path = item.path, fp = item.fp, md5 = item.md5,
                    title = props.title, authors = props.authors,
                    intro = props.intro, language = props.language,
                }
            end
            return { books = out }
        end, {
            name = "local.enrich",
            kind = "medium",
            on_progress = function(value)
                if type(value) == "table" then
                    report(T(_("正在补齐 %1"), value[3]), value[1], value[2])
                    return
                end
                opening = value or nil
            end,
            on_done = function(result)
                for _idx, f in ipairs(result.books or {}) do
                    markCoverTried(index, f.path, f.fp, f.md5)
                    local row = f.title and f.title ~= "" and BookDB.get(SOURCE_ID, f.path)
                    local name = f.path:match("([^/]+)$") or f.path
                    -- 只升级仍是文件名兜底的行，用户改过的书名 / 已有元数据不覆盖
                    local fallback = parseFilename(name)
                    if row and (not row.title or row.title == "" or row.title == fallback) then
                        BookDB.upsertLocal({
                            source_id = SOURCE_ID, stable_id = f.path,
                            title = f.title, authors = f.authors, intro = f.intro,
                            category = row.category, series = row.series,
                            meta = { language = f.language },
                        })
                    end
                end
                cb()
            end,
            on_failed = function(err)
                if opening and not skip[opening] then
                    require("utils.log").warn("book local enrich crashed; skip", opening, err)
                    skip[opening] = true
                    markCoverTried(index, opening)
                    -- 已完成的书不在 pending 里重做：只留下 opening 之后的
                    local rest = {}
                    local seen_crash = false
                    for _idx, item in ipairs(todo) do
                        if item.path == opening then
                            seen_crash = true
                        elseif seen_crash then
                            rest[#rest + 1] = item
                        end
                    end
                    pending = rest
                    return start()
                end
                require("utils.log").warn("book local enrich failed", err)
                cb()
            end,
        })
    end
    start()
    return { cancel = function()
            if job then job:cancel() end
        end }
end

--- 补齐未在跑才开一轮；句柄挂 client，取消扫盘时一并杀掉。
---@param self LocalClient
---@param report fun(text: string, done: integer|nil, total: integer|nil)|nil
---@return { cancel: fun() }|nil
function Scan.ensureEnrich(self, report)
    if self._enrich_job then return self._enrich_job end
    local handle
    handle = Scan.enrichAsync(self, function()
        if self._enrich_job == handle then self._enrich_job = nil end
    end, report)
    self._enrich_job = handle
    return handle
end

--- 扫盘写库（不查询），供 syncBooksAsync 使用。遍历与 md5 在子进程，落库在主进程，cancel 杀子进程与补齐。
--- 批内落索引 + upsert：取消 / 崩溃不丢已扫进度；整轮成功后再 reconcile，并 ensureEnrich 补封面。
--- 子进程 progress：`{ i, n, name }` 逐本计数；`{ files = batch }` 批结果。
---@param self LocalClient
---@param cb fun(ok: boolean, err: string|nil)
---@param report fun(text: string, done: integer|nil, total: integer|nil)|nil 真实步骤上报
---@return { cancel: fun() }
function Scan.scanAsync(self, cb, report)
    local valid, path_err = self:validatePath()
    if not valid then return defer(cb, false, path_err) end
    report = report or function() end
    local root = rootPath(self.cfg)
    local known, digests, rows = knownBooks()
    local index = ScanDB.all()
    local job
    local started_at = Perf.now()
    local cancelled = false
    local function start()
        local parsed = {}
        report(_("正在扫描书库…"))
        job = Job.run(function(progress)
            local files, skipped = scanFiles(root, self.cfg.folder_category == false)
            -- 结果帧有 4MB 上限，几千本一次回传必超：产物分批经 progress 送回，结果只带 skipped。
            local batch = {}
            for i = 1, #files do
                progress({ i, #files, files[i].name })
                batch[#batch + 1] = parseFile(files[i], known, digests, index)
                if #batch >= SCAN_BATCH or i == #files then
                    progress({ files = batch })
                    batch = {}
                end
            end
            return { skipped = skipped }
        end, {
            name = "local.scan",
            kind = "medium",
            on_progress = function(value)
                if type(value) == "table" and value.files then
                    for _idx, f in ipairs(value.files) do parsed[#parsed + 1] = f end
                    -- 指纹 / md5 / 书目逐批落盘：取消后续扫不重算已完成的
                    ScanDB.save(index, value.files, true)
                    local ok, step = commitFiles(value.files, known, false)
                    if not ok then
                        require("utils.log").warn("book local scan batch commit failed at", step)
                    end
                    return
                end
                if type(value) == "table" then
                    report(T(_("正在检查 %1"), value[3]), value[1], value[2])
                end
            end,
            on_done = function(result)
                if cancelled then return end
                local files = parsed
                -- 读不了的子目录是“未知”不是“没有”：其下原有的在架行原样保留
                local kept = {}
                for _id, row in pairs(rows) do
                    for _idx, dir in ipairs(result.skipped or {}) do
                        if row.deleted == 0 and type(row.path) == "string" and row.path:sub(1, #dir + 1) == dir .. "/" then
                            kept[#kept + 1] = row
                            break
                        end
                    end
                end
                if not ScanDB.save(index, files) then
                    require("utils.log").warn("book local scan index save failed")
                end
                local unchanged = upToDate(files, known, rows, self.cfg.folder_category == false, kept)
                local committed, step = true, nil
                if not unchanged then committed, step = commitFiles(files, known, true, kept) end
                if committed then
                    require("utils.log").dbg("book.perf local.scan", Perf.elapsedMs(started_at), "ms",
                        "files", #files, unchanged and "unchanged" or "committed")
                    cb(true)
                    Scan.ensureEnrich(self, report)
                else
                    require("utils.log").warn("book local scan commit failed at", step, "files", #files)
                    cb(false, "failed to commit local scan: " .. tostring(step))
                end
            end,
            on_failed = function(err)
                if cancelled then return end
                -- 轻扫不再开文档，子进程崩多半是列目录 / md5；整轮失败，已批落盘的索引与书目保留续扫
                require("utils.log").warn("book local scan failed", err)
                cb(false, err or "local scan failed")
                Scan.ensureEnrich(self, report)
            end,
            on_cancelled = function()
                -- 已批入库的留下；补齐接着啃已在架缺封面的
                Scan.ensureEnrich(self)
            end,
        })
    end
    start()
    return { cancel = function()
            cancelled = true
            if job then job:cancel() end
            if self._enrich_job then
                self._enrich_job:cancel()
                self._enrich_job = nil
            end
        end }
end

--- 把外部文件收进书库根目录并单本入库（不重扫）。
--- 防重名加 " (n)"；os.rename 失败（跨设备）退化为流式复制，失败不留半截文件。
---@param temp_path string
---@param filename string
---@param cb fun(ok: boolean|nil, err: any)
---@return { cancel: fun() }|nil
---@param self LocalClient
function Scan.importAsync(self, temp_path, filename, cb)
    local ok, path_err = self:validatePath()
    if not ok then return defer(cb, nil, path_err) end
    local root = rootPath(self.cfg)
    filename = filename:gsub("[/\\]", "_")
    if filename == "" then return defer(cb, nil, _("无效文件名")) end
    local stem, ext = filename:match("^(.*)(%.[^.]*)$")
    stem, ext = stem or filename, ext or ""
    local target, n = root .. "/" .. filename, 2
    while lfs.attributes(target) do
        target = string.format("%s/%s (%d)%s", root, stem, n, ext)
        n = n + 1
    end
    local moved = os.rename(temp_path, target)
    if not moved then
        local input, copy_err = io.open(temp_path, "rb")
        local output
        if input then
            output, copy_err = io.open(target, "wb")
        end
        if not input or not output then
            if input then input:close() end
            os.remove(target)
            return defer(cb, nil, copy_err)
        end
        local copy_ok = true
        while copy_ok do
            local chunk, read_err = input:read(64 * 1024)
            if not chunk then
                copy_ok, copy_err = read_err == nil, read_err
                break
            end
            local written
            written, copy_err = output:write(chunk)
            copy_ok = written ~= nil
        end
        input:close()
        -- 缓冲写的磁盘满 / IO 错误常在 close 刷盘时才报出来。
        local closed, close_err = output:close()
        if not copy_ok or not closed then
            os.remove(target)
            return defer(cb, nil, copy_err or close_err)
        end
    end
    return self:indexOneAsync(target, cb)
end

--- 手动改分类/系列 = 移动文件（仅「按文件夹分类」开启时）：分类是一级目录、系列是二级目录（无分类则系列无意义，丢弃）。
--- stable_id 即文件绝对路径，移动后跟着变；书籍相关身份经 renameStableId 迁移，
--- 封面缓存与 KOReader 的 .sdr 目录（阅读进度/书签/笔记）改名跟随。
--- 编辑对话框保存时同步调用 renameStableId 写库；FS 操作不另起子进程。
---@param stable_id string 当前文件绝对路径
---@param category string|nil
---@param series string|nil
---@return string|nil, string|nil err
---@param self LocalClient
function Scan.moveBook(self, stable_id, category, series)
    -- 关闭「按文件夹分类」：分类 / 系列只是书库字段，编辑只改库、不动文件（也不建目录）。
    if self.cfg.folder_category == false then
        return stable_id
    end
    local root = rootPath(self.cfg)
    if root == "" then
        return nil, _("未配置本地路径")
    end
    local filename = stable_id:match("([^/]+)$")
    if not filename then
        return nil, _("无效路径")
    end
    --- 单级目录名：去空白；含路径分隔符或以 . 开头（隐藏目录/逃逸书库根）拒绝。
    ---@return string|nil, boolean|nil
    local function dirName(s)
        s = Text.trim(type(s) == "string" and s or "")
        if s == "" then
            return nil
        end
        if s:find("[/\\]") or s:sub(1, 1) == "." then
            return nil, true
        end
        return s
    end
    local cat, bad_cat = dirName(category)
    local ser, bad_ser = dirName(series)
    if bad_cat or bad_ser then
        return nil, _("目录名不能含斜杠或以点开头")
    end
    if not cat then
        ser = nil
    end
    local dir = root
    if cat then
        dir = dir .. "/" .. cat
    end
    if ser then
        dir = dir .. "/" .. ser
    end
    local new_path = dir .. "/" .. filename
    if new_path == stable_id then
        return stable_id
    end
    if lfs.attributes(new_path) then
        return nil, _("目标位置已有同名文件：") .. filename
    end
    -- lfs.mkdir 不递归，逐级建；目录已存在会失败，忽略（os.rename 会做最终裁决）
    if cat then
        lfs.mkdir(root .. "/" .. cat)
    end
    if ser then
        lfs.mkdir(dir)
    end
    local moved, move_err = os.rename(stable_id, new_path)
    if not moved then
        return nil, _("移动失败：") .. tostring(move_err)
    end
    local artifacts_ok, artifacts_err = moveBookArtifacts(stable_id, new_path)
    if not artifacts_ok then
        moveBookArtifacts(new_path, stable_id)
        os.rename(new_path, stable_id)
        return nil, _("移动失败：") .. tostring(artifacts_err)
    end
    if not require("book.books_db").renameStableId(SOURCE_ID, stable_id, new_path, cat, ser) then
        moveBookArtifacts(new_path, stable_id)
        os.rename(new_path, stable_id)
        return nil, _("更新书籍身份失败")
    end
    return new_path
end

--- 单文件入库（不扫盘、不清失效）。同步解析在子进程跑——单本导入用户在等，开一次引擎拿元数据+封面。
--- 导入落根目录，category/series 恒为 nil（与扫盘根层语义一致）。
---@param path string 绝对路径（即 stable_id）
---@param cb fun(ok: boolean|nil, err: any)
---@return { cancel: fun() }|nil
---@param self LocalClient
function Scan.indexOneAsync(self, path, cb)
    local name = path:match("([^/]+)$") or path
    if not isBookFile(name) then
        return defer(cb, nil, _("不支持的文件格式"))
    end
    local known, digests = knownBooks()
    local index = ScanDB.all()
    local attr = lfs.attributes(path)
    local fp = attr and (attr.size .. ":" .. attr.modification) or nil
    local job = Job.run(function(progress)
        local f = parseFile({ name = name, path = path, fp = fp }, known, digests, index)
        progress(path)
        local props = parseBookProps(path) or {}
        progress(false)
        f.cover_tried = true
        if props.title and props.title ~= "" then
            f.title, f.authors, f.intro, f.language = props.title, props.authors, props.intro, props.language
        elseif not f.title or f.title == "" then
            f.title, f.authors = parseFilename(name)
        end
        return f
    end, {
        name = "local.index",
        kind = "light",
        on_done = function(f)
            if commitFiles({ f }, known) then
                ScanDB.save(index, { f }, true)
                cb(true)
            else
                cb(nil, "failed to commit local book")
            end
        end,
        on_failed = function(err)
            require("utils.log").warn("book local index failed", err)
            cb(nil, err)
        end,
    })
    return { cancel = function()
            job:cancel()
        end }
end
return Scan
