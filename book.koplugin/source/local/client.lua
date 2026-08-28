--[[--
本地目录扫描客户端（仅异步）

数据流：扫描器只负责把目录状态写进 books 表（增/改/删 + 封面 PNG），
书库/筛选/搜索/最近阅读/统计一律直查数据库，不做内存缓存。


@module koplugin.book.source.local.client
--]]

local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local Text = require("utils.text")
local _ = require("gettext")
local Task = require("utils.task")

-- 源模块顶部不许 require KOReader UI 模块（离线测试直接 require 源文件）
local _uimanager
--- 延迟取 UIManager 并缓存；顶层 require UI 模块会让离线测试直接炸。
---@return table
local function uiManager()
    _uimanager = _uimanager or require("ui/uimanager")
    return _uimanager
end

local Client = {}
Client.__index = Client

local SOURCE_ID = "local"

--- 自动扫描节流间隔（秒）：桌面反复打开不重复扫盘
local AUTO_SCAN_INTERVAL = 60

local BOOK_EXT = {
    pdf = true,
    epub = true,
    djvu = true,
    mobi = true,
    cbz = true,
    cbt = true,
    docx = true,
    rtf = true,
    html = true,
    txt = true,
    xps = true,
    fb2 = true,
    pdb = true,
    chm = true,
    md = true,
}

--- 判断文件是否为可打开的书籍。
---@param name string
---@return boolean
local function isBookFile(name)
    local ext = name:match("%.([^.]+)$")
    if not ext then
        return false
    end
    return BOOK_EXT[string.lower(ext)] == true
end

--- 书库根目录：去尾部空白与斜杠。
---@param cfg table|nil
---@return string
local function rootPath(cfg)
    return Text.rtrimSlashes(Text.rtrim(cfg and cfg.path))
end



--- 从配置构造本地客户端。
---@param cfg table|nil
---@return LocalClient
function Client.new(cfg)
    cfg = cfg or {}
    return setmetatable({ cfg = cfg }, Client)
end

--- 是否已配置本地路径。
---@return boolean
function Client:configured()
    return Text.stripWhitespace(self.cfg.path) ~= ""
end

--- 本地路径是否有效（存在、是目录、且不在插件数据目录内）。
---@return boolean, string|nil
function Client:validatePath()
    local path = rootPath(self.cfg)
    if path == "" then
        return false, _("未配置本地路径")
    end
    local moon_root = require("utils.paths").root()
    if path == moon_root or path:sub(1, #moon_root + 1) == moon_root .. "/" then
        return false, _("书库目录不能是插件数据目录")
    end
    local attr = lfs.attributes(path)
    if not attr then
        return false, _("路径不存在: ") .. path
    end
    if attr.mode ~= "directory" then
        return false, _("路径不是目录: ") .. path
    end
    return true
end

--- 封面缓存路径（存在即封面可用，无需入库）。
---@param stable_id string
---@return string
local function coverPath(stable_id)
    return require("utils.paths").coverPath(stable_id, SOURCE_ID)
end

--- 把书籍附属资源从旧路径迁移到新路径。
---@param old_path string
---@param new_path string
local function moveBookArtifacts(old_path, new_path)
    local old_cover = coverPath(old_path)
    if lfs.attributes(old_cover, "mode") == "file" then
        os.rename(old_cover, coverPath(new_path))
    end
    local old_sdr = old_path .. ".sdr"
    if lfs.attributes(old_sdr, "mode") == "directory" then
        os.rename(old_sdr, new_path .. ".sdr")
    end
end

--- 把封面 blitbuffer 落盘为 PNG（os.remove/os.rename 不抛异常，无需 pcall）。
---@param bb any
---@param stable_id string
local function saveCover(bb, stable_id)
    if not bb then
        return
    end
    local path = coverPath(stable_id)
    local tmp = path .. ".part"
    local ok = pcall(function() bb:writePNG(tmp) end)
    pcall(function() bb:free() end)
    if not ok then
        os.remove(tmp)
        return
    end
    os.remove(path)
    if not os.rename(tmp, path) then
        os.remove(tmp)
    end
end

--- 解析单本书元数据 + 封面；失败返回 nil（损坏 / 无引擎）。
--- crengine 需 loadDocument(false) 仅载元数据；close 后注册表引用归零自动清。
---@param path string 书路径，即 stable_id
---@return { title: string|nil, authors: string|nil, intro: string|nil }|nil
local function parseBookProps(path)
    local ok, props = pcall(function()
        local DocumentRegistry = require("document/documentregistry")
        if not DocumentRegistry:hasProvider(path) then
            return nil
        end
        local doc = DocumentRegistry:openDocument(path)
        if not doc then
            return nil
        end
        if doc.loadDocument and not doc:loadDocument(false) then
            -- crengine 加载失败后调其它方法会 segfault，必须直接 close
            pcall(function() doc:close() end)
            return nil
        end
        local p = doc:getProps()
        -- 封面：与元数据同会话提取（无封面的格式返回 nil）
        if lfs.attributes(coverPath(path), "mode") ~= "file" then
            local ok_cover, cover_bb = pcall(function()
                return doc:getCoverPageImage()
            end)
            if ok_cover and cover_bb then
                saveCover(cover_bb, path)
            end
        end
        pcall(function() doc:close() end)
        return p
    end)
    if not ok or type(props) ~= "table" then
        return nil
    end
    --- 元数据字段归一：非字符串或去空白后为空一律当作缺失。
    ---@param s any
    ---@return string|nil
    local function clean(s)
        if type(s) ~= "string" then
            return nil
        end
        s = Text.trim(s)
        return s ~= "" and s or nil
    end
    return {
        title = clean(props.title),
        authors = clean(props.authors),
        intro = clean(props.description),
    }
end

--- 目录遍历（最多 3 层），产出按路径排序的书籍文件列表。
--- 根目录直属文件无分类无系列；一级子目录名 = 分类；二级子目录名 = 系列；更深忽略。
--- 同步阻塞，只在子进程里跑。
---@param root string
---@return table[]
local function scanFiles(root)
    local files = {}
    --- 递归遍历一层目录，把书籍文件连同继承来的分类/系列收进 files。
    --- 跳过 . 前缀项与 .sdr 边车目录；depth 超过 2 不再下钻。
    ---@param dir string 当前目录绝对路径
    ---@param category string|nil 继承的分类（一级子目录名）
    ---@param series string|nil 继承的系列（二级子目录名）
    ---@param depth number 当前层级，根为 1
    local function walk(dir, category, series, depth)
        local iter_ok, iter, state = pcall(lfs.dir, dir)
        if not (iter_ok and iter) then
            return
        end
        for name in iter, state do
            -- 跳过 . .. 及一切 . 前缀项（.moon 等隐藏目录/文件）
            if name:sub(1, 1) ~= "." then
                local path = dir .. "/" .. name
                local attr = lfs.attributes(path)
                if attr then
                    if attr.mode == "directory" then
                        -- KOReader 的 .sdr 边车目录不是书籍分类，不下钻
                        if name:sub(-4) ~= ".sdr" then
                            -- 下钻：根下的一级目录名是分类，分类下的二级目录名是系列
                            if depth == 1 then
                                walk(path, name, nil, depth + 1)
                            elseif depth == 2 then
                                walk(path, category, name, depth + 1)
                            end
                        end
                    elseif attr.mode == "file" and isBookFile(name) then
                        files[#files + 1] = {
                            name = name,
                            path = path,
                            category = category,
                            series = series,
                        }
                    end
                end
            end
        end
    end
    walk(root, nil, nil, 1)
    table.sort(files, function(a, b)
        return a.path < b.path
    end)
    return files
end

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

--- 解析单本书并写入 books 表。同步阻塞，只在子进程里跑（BookDB 自带 ensure，首用即开子进程连接）。
--- 命中 books 表缓存（title 非空）则跳过解析。路径未命中时按内容 md5 找旧行：
--- 命中说明文件被移动/改名，原地把 stable_id 换成新路径（身份以 md5 为准，不当新书），
--- category/series 由所在目录派生，随新位置一并刷新；
--- 否则才是真新书，解析引擎失败回退文件名。
---@param f table 扫描产物 { name, path, category, series }
local function resolveOne(f)
    local BookDB = require("utils.db.book")
    local cached = BookDB.get(SOURCE_ID, f.path)
    if cached and type(cached.title) == "string" and cached.title ~= "" then
        if cached.in_library == false then
            BookDB.setLibraryMembership(SOURCE_ID, f.path, true)
        end
        return
    end
    local digest = util.partialMD5(f.path)
    local moved_from = nil
    if digest then
        local by_md5 = BookDB.getByMd5(SOURCE_ID, digest)
        if by_md5 and by_md5.stable_id ~= f.path then
            moved_from = by_md5.stable_id
        end
    end
    if moved_from then
        BookDB.renameStableId(SOURCE_ID, moved_from, f.path, f.category, f.series)
        local old_cover = coverPath(moved_from)
        if lfs.attributes(old_cover, "mode") == "file" then
            os.rename(old_cover, coverPath(f.path))
        end
        -- KOReader 的 .sdr 目录（阅读进度/书签/笔记）跟着书走
        local old_sdr = moved_from .. ".sdr"
        if lfs.attributes(old_sdr, "mode") == "directory" then
            os.rename(old_sdr, f.path .. ".sdr")
        end
        return
    end
    local props = parseBookProps(f.path) or {}
    local title, authors, intro = props.title, props.authors, props.intro
    if not title or title == "" then
        title, authors = parseFilename(f.name)
    end
    BookDB.upsert({
        source_id = SOURCE_ID,
        stable_id = f.path,
        md5 = digest,
        title = title,
        authors = authors,
        intro = intro,
        category = f.category,
        series = f.series,
        fetched_at = os.time(),
        path = f.path,
    })
end

--- 扫描后隐藏失效书籍并清路径，身份、进度、笔记和统计保留。
--- 改名/移动的书已在 resolveOne 里原地更新 stable_id，这里的 keep 集合天然包含它们。
--- 同步阻塞，只在子进程里跑。
---@param files table[]
local function pruneMissing(files)
    local keep = {}
    for _, f in ipairs(files) do
        keep[f.path] = true
    end
    local BookDB = require("utils.db.book")
    for _, stable_id in ipairs(BookDB.stableIdsBySource(SOURCE_ID)) do
        if not keep[stable_id] then
            BookDB.setLibraryMembership(SOURCE_ID, stable_id, false, true)
            os.remove(coverPath(stable_id))
        end
    end
end

--- 扫盘任务：重活全在子进程，cancel 杀子进程。
--- 扫描成败都调 on_done：子进程崩溃/启动失败时库里是旧数据，照查，不让 UI 空转。
---@param root string
---@param on_done fun()
---@return { cancel: fun() }
local function scanJob(root, on_done)
    local job = Task.run(function()
        local files = scanFiles(root)
        for _, f in ipairs(files) do
            resolveOne(f)
        end
        pruneMissing(files)
    end, {
        on_done = on_done,
        on_failed = function(err)
            require("logger").warn("book local scan failed", err)
            on_done()
        end,
    })
    return {
        cancel = function()
            job:abort()
        end,
    }
end

--- 直查 books 表（图书馆分页/分类/系列/搜索）。
---@param opts table|nil { page, page_size, category, series, search }
---@param cb fun(rows: table[]|nil, count: number, err: any)
local function queryDb(opts, cb)
    opts = opts or {}
    local page = math.max(1, tonumber(opts.page) or 1)
    local page_size = math.max(1, tonumber(opts.page_size) or 24)
    uiManager():nextTick(function()
        local BookDB = require("utils.db.book")
        local rows, count = BookDB.listBySource(SOURCE_ID, {
            category = opts.category,
            series = opts.series,
            search = opts.search,
            limit = page_size,
            offset = (page - 1) * page_size,
        })
        cb(rows, count)
    end)
end

--- 把外部文件收进书库根目录并单本入库（不重扫）。
--- 防重名加 " (n)"；os.rename 失败（跨设备）退化为流式复制，失败不留半截文件。
---@param temp_path string
---@param filename string
---@param cb fun(ok: boolean|nil, err: any)
---@return { cancel: fun() }|nil
function Client:importAsync(temp_path, filename, cb)
    local ok, path_err = self:validatePath()
    if not ok then
        cb(nil, path_err)
        return nil
    end
    local root = rootPath(self.cfg)
    filename = tostring(filename or ""):gsub("[/\\]", "_")
    if filename == "" then
        cb(nil, _("无效文件名"))
        return nil
    end
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
            pcall(os.remove, target)
            cb(nil, tostring(copy_err))
            return nil
        end
        while true do
            local chunk = input:read(64 * 1024)
            if not chunk then break end
            local written, write_err = output:write(chunk)
            if not written then
                input:close()
                output:close()
                pcall(os.remove, target)
                cb(nil, tostring(write_err))
                return nil
            end
        end
        input:close()
        output:close()
    end
    return self:indexOneAsync(target, cb)
end

--- 手动改分类/系列 = 移动文件：分类是一级目录、系列是二级目录（无分类则系列无意义，丢弃）。
--- stable_id 即文件绝对路径，移动后跟着变；四表身份经 renameStableId 迁移，
--- 封面缓存与 KOReader 的 .sdr 目录（阅读进度/书签/笔记）改名跟随。
--- 编辑对话框保存时经 DbQueue 调用（renameStableId 写库）；FS 操作同步快，不另起子进程。
---@param stable_id string 当前文件绝对路径
---@param category string|nil
---@param series string|nil
---@return string|nil new_stable_id 位置没变返回原值；失败返回 nil + err
function Client:moveBook(stable_id, category, series)
    local root = rootPath(self.cfg)
    if root == "" then
        return nil, _("未配置本地路径")
    end
    local filename = type(stable_id) == "string" and stable_id:match("([^/]+)$")
    if not filename then
        return nil, _("无效路径")
    end
    --- 单级目录名：去空白；含路径分隔符或以 . 开头（隐藏目录/逃逸书库根）拒绝。
    ---@param s any
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
    moveBookArtifacts(stable_id, new_path)
    require("utils.db.book").renameStableId(SOURCE_ID, stable_id, new_path, cat, ser)
    return new_path
end

--- 用转换后的临时 EPUB 替换本地原书。
--- 新文件使用原文件名的 .epub 扩展名；原书、封面、.sdr 和数据库身份一起迁移。
--- 目标 EPUB 已存在或任一步骤失败时拒绝操作，避免覆盖另一册书。
---@param temp_path string 转换器生成的临时 EPUB
---@param stable_id string 原书绝对路径
---@return string|nil new_stable_id, string|nil err
function Client:replaceBook(temp_path, stable_id)
    local ok, path_err = self:validatePath()
    if not ok then
        return nil, path_err
    end
    if type(temp_path) ~= "string" or temp_path == ""
        or type(stable_id) ~= "string" or stable_id == ""
    then
        return nil, _("无效路径")
    end
    local root = rootPath(self.cfg)
    if stable_id ~= root and stable_id:sub(1, #root + 1) ~= root .. "/" then
        return nil, _("原书不在书库目录内")
    end
    local new_path = stable_id:gsub("%.[^./]+$", ".epub")
    if new_path == stable_id then
        return nil, _("原书已经是 EPUB")
    end
    if lfs.attributes(new_path) then
        return nil, _("目标位置已有同名文件：") .. (new_path:match("([^/]+)$") or new_path)
    end
    if lfs.attributes(new_path .. ".sdr") then
        return nil, _("目标位置已有同名文件：") .. (new_path:match("([^/]+)$") or new_path) .. ".sdr"
    end

    local backup = stable_id .. ".moon-reflow-backup"
    if lfs.attributes(backup) then
        return nil, _("存在未完成的排版替换，请清理后重试")
    end
    local moved, move_err = os.rename(stable_id, backup)
    if not moved then
        return nil, _("暂存原书失败：") .. tostring(move_err)
    end
    local created, create_err = os.rename(temp_path, new_path)
    if not created then
        os.rename(backup, stable_id)
        return nil, _("放置转换文件失败：") .. tostring(create_err)
    end

    local BookDB = require("utils.db.book")
    local row = BookDB.get(SOURCE_ID, stable_id)
    local renamed = BookDB.renameStableId(
        SOURCE_ID,
        stable_id,
        new_path,
        row and row.category or nil,
        row and row.series or nil
    )
    if not renamed then
        os.remove(new_path)
        os.rename(backup, stable_id)
        return nil, _("更新书籍身份失败")
    end

    if not os.remove(backup) then
        BookDB.renameStableId(
            SOURCE_ID,
            new_path,
            stable_id,
            row and row.category or nil,
            row and row.series or nil
        )
        os.remove(new_path)
        os.rename(backup, stable_id)
        return nil, _("删除原书失败")
    end
    local digest_ok, digest = pcall(util.partialMD5, new_path)
    if row and digest_ok and type(digest) == "string" and digest ~= "" then
        local updated = {}
        for key, value in pairs(row) do updated[key] = value end
        updated.source_id = SOURCE_ID
        updated.stable_id = new_path
        updated.path = new_path
        updated.md5 = digest
        BookDB.upsert(updated)
    end
    moveBookArtifacts(stable_id, new_path)
    return new_path
end

--- 单文件入库（不扫盘、不清失效）。同步解析在子进程跑。
--- 导入落根目录，category/series 恒为 nil（与扫盘根层语义一致）。
---@param path string 绝对路径（即 stable_id）
---@param cb fun(ok: boolean|nil, err: any)
---@return { cancel: fun() }|nil
function Client:indexOneAsync(path, cb)
    if type(path) ~= "string" or path == "" then
        uiManager():nextTick(function()
            cb(nil, _("无效路径"))
        end)
        return nil
    end
    local name = path:match("([^/]+)$") or path
    if not isBookFile(name) then
        uiManager():nextTick(function()
            cb(nil, _("不支持的文件格式"))
        end)
        return nil
    end
    local job = Task.run(function()
        resolveOne({
            name = name,
            path = path,
            category = nil,
            series = nil,
        })
    end, {
        on_done = function()
            cb(true)
        end,
        on_failed = function(err)
            require("logger").warn("book local index failed", err)
            cb(nil, err)
        end,
    })
    return {
        cancel = function()
            job:abort()
        end,
    }
end

--- 强制扫盘写库（不查询）。供 syncBooksAsync(force) 使用。
---@param cb fun(ok: boolean, err: any)
---@return { cancel: fun() }|nil
function Client:scanAsync(cb)
    local ok, err = self:validatePath()
    if not ok then
        uiManager():nextTick(function()
            cb(false, err)
        end)
        return nil
    end
    local root = rootPath(self.cfg)
    return scanJob(root, function()
        cb(true)
    end)
end

--- 书库查询（异步）：默认直查数据库；opts.force 先真实扫盘写库再查。
---@param opts table|nil { force, page, page_size, category, series, search }
---@param cb fun(rows: table[]|nil, count: number, err: any)
---@return { cancel: fun() }|nil
function Client:listAsync(opts, cb)
    local ok, err = self:validatePath()
    if not ok then
        uiManager():nextTick(function()
            cb(nil, 0, err)
        end)
        return nil
    end

    if not (type(opts) == "table" and opts.force == true) then
        queryDb(opts, cb)
        return nil
    end

    return self:scanAsync(function(scan_ok, scan_err)
        if not scan_ok then
            cb(nil, 0, scan_err)
            return
        end
        queryDb(opts, cb)
    end)
end

--- 打开桌面时的自动扫描（节流 AUTO_SCAN_INTERVAL 秒）：扫盘写库 + 清失效。
---@param cb fun(scanned: boolean)
---@return { cancel: fun() }|nil
function Client:autoScanAsync(cb)
    if not self:validatePath() then
        cb(false)
        return nil
    end
    if not self._auto_scan then
        -- 门闩：窗口内再调返回 nil
        self._auto_scan = require("utils.timing").throttle(function()
            return true
        end, AUTO_SCAN_INTERVAL)
    end
    if not self._auto_scan() then
        cb(false)
        return nil
    end
    local root = rootPath(self.cfg)
    return scanJob(root, function()
        cb(true)
    end)
end

--- 分类和系列列表（DISTINCT 直查数据库）。
---@param cb fun(data: BookFiltersResult|nil, err: any)
---@return { cancel: fun() }|nil
function Client:filtersAsync(cb)
    local ok, err = self:validatePath()
    uiManager():nextTick(function()
        if not ok then
            cb(nil, err)
            return
        end
        local BookDB = require("utils.db.book")
        cb({
            data = {
                category = BookDB.categoriesBySource(SOURCE_ID),
                series = BookDB.seriesBySource(SOURCE_ID),
            },
        })
    end)
    return nil
end

--- 封面缓存路径（已存在才返回；绝不现提取，coverRequest 在 UI 线程同步调用）。
---@param stable_id string
---@return string|nil
function Client:cachedCoverPath(stable_id)
    if type(stable_id) ~= "string" or stable_id == "" then
        return nil
    end
    local path = coverPath(stable_id)
    if lfs.attributes(path, "mode") == "file" then
        return path
    end
    return nil
end

return Client
