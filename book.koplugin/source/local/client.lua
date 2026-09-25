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
local Job = require("workers.job")
local Webdav = require("http.webdav")
local Paths = require("utils.paths")

--- 下一帧调 cb(...)。源模块顶部不许 require KOReader UI 模块（离线测试直接 require 源文件），
--- UIManager 在这里延迟加载。
---@param cb function
local function defer(cb, ...)
    local args = { n = select("#", ...), ... }
    require("ui/uimanager"):nextTick(function()
        cb(unpack(args, 1, args.n))
    end)
end

---@class LocalClient
---@field cfg table
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
    return setmetatable({
        cfg = cfg,
        dav = Webdav.new{
            url = cfg.webdav_url,
            username = cfg.webdav_username,
            password = cfg.webdav_password,
        },
    }, Client)
end

---@return boolean
function Client:isWebdav()
    return Text.trim(self.cfg.webdav_url or "") ~= ""
end

---@return string
function Client:webdavPath()
    local path = Text.trimSlashes(Text.trim(self.cfg.webdav_path or "Apps/Books"))
    return path ~= "" and path or "Apps/Books"
end

---@return string
function Client:webdavCacheRoot()
    return Paths.bookDir(SOURCE_ID) .. "/webdav"
end

--- 确保文件所在目录存在。
---@param path string
local function ensureParent(path)
    Paths.ensureDir(path:match("(.+)/[^/]+$") or path)
end

---@param rel string
---@return string
local function remoteStableId(rel)
    return "webdav://" .. rel
end

---@param stable_id string
---@return string|nil
local function remoteRelativePath(stable_id)
    if type(stable_id) ~= "string" then return nil end
    local rel = stable_id:match("^webdav://(.+)$")
    return rel and rel ~= "" and rel or nil
end

local function progressFileName(rel)
    return rel:match("([^/]+)$")
end

local function encodeProgress(pos)
    local ts = tonumber(pos.updated_at) or os.time()
    local pct = math.floor((tonumber(pos.fraction) or 0) * 100 + 0.5)
    if pos.chapter_idx ~= nil then
        return string.format("{%d}*%d@%d#0:%d%%", ts,
            tonumber(pos.chapter_idx) or 0, tonumber(pos.page) or 1, pct)
    end
    return string.format("{%d}*%d:%d%%", ts, tonumber(pos.page) or 1, pct)
end

local function decodeProgress(raw)
    if type(raw) ~= "string" then return nil end
    local ts, chapter, page, pct = raw:match("{%s*(%d+)%s*}%*(%-?%d+)@(%d+)[^:]*:(%d+)%%")
    if not ts then
        ts, page, pct = raw:match("{%s*(%d+)%s*}%*(%d+):(%d+)%%")
    end
    if not ts then return nil end
    return {
        updated_at = tonumber(ts), chapter_idx = chapter and tonumber(chapter) or nil,
        page = tonumber(page), fraction = math.min(100, tonumber(pct) or 0) / 100,
    }
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
    for _, size in ipairs({ 65536, 262144, 1048576, 4194304, 16777216 }) do
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

--- 逐项串行异步遍历：step(item, next) 处理完一项调 next()，全部处理完调 done()。
---@param list any[]
---@param step fun(item: any, next: fun())
---@param done fun()
local function eachAsync(list, step, done)
    local index = 0
    local function next_item()
        index = index + 1
        local item = list[index]
        if item == nil then
            return done()
        end
        step(item, next_item)
    end
    next_item()
end

--- 是否已配置本地路径。
---@return boolean
function Client:configured()
    return self:isWebdav() or Text.stripWhitespace(self.cfg.path) ~= ""
end

--- 本地路径是否有效（存在、是目录、且不在插件数据目录内）。
---@return boolean, string|nil
function Client:validatePath()
    if self:isWebdav() then
        if not self.cfg.webdav_url:match("^https?://") then
            return false, _("WebDAV 地址必须以 http:// 或 https:// 开头")
        end
        return true
    end
    local path = rootPath(self.cfg)
    if path == "" then
        return false, _("未配置本地路径")
    end
    local moon_root = Paths.root()
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
    return Paths.coverPath(stable_id, SOURCE_ID)
end

--- 把书籍附属资源从旧路径迁移到新路径。
--- 封面只是缓存，失败仅记日志；.sdr 装着 KOReader 进度与高亮，失败要报给调用方。
---@param old_path string
---@param new_path string
---@return boolean ok, string|nil err
local function moveBookArtifacts(old_path, new_path)
    local old_cover = coverPath(old_path)
    if lfs.attributes(old_cover, "mode") == "file" then
        local ok, err = os.rename(old_cover, coverPath(new_path))
        if not ok then
            require("utils.log").warn("book local cover move failed", old_cover, err)
        end
    end
    local old_sdr = old_path .. ".sdr"
    if lfs.attributes(old_sdr, "mode") == "directory" then
        local ok, err = os.rename(old_sdr, new_path .. ".sdr")
        if not ok then
            require("utils.log").warn("book local sdr move failed", old_sdr, err)
            return false, err
        end
    end
    return true
end

--- 从已打开的文档提取封面并落盘为 PNG；封面缓存独立于 books 元数据缓存。
--- os.remove/os.rename 不抛异常，无需 pcall。
---@param doc table
---@param path string
local function saveDocumentCover(doc, path)
    local target = coverPath(path)
    if lfs.attributes(target, "mode") == "file" then
        return
    end
    local ok_cover, bb = pcall(function()
        return doc:getCoverPageImage()
    end)
    if not (ok_cover and bb) then
        return
    end
    local tmp = target .. ".part"
    local ok = pcall(function() bb:writePNG(tmp) end)
    pcall(function() bb:free() end)
    if not ok then
        os.remove(tmp)
        return
    end
    os.remove(target)
    if not os.rename(tmp, target) then
        os.remove(tmp)
    end
end

--- 打开文档调 fn(doc) 并返回其结果；无引擎 / 打开失败返回 nil。异常不在这里吞，由调用方 pcall。
--- crengine 需 loadDocument(false) 仅载元数据；close 后注册表引用归零自动清。
---@param path string
---@param fn fun(doc: table): any
local function withDocument(path, fn)
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
    local result = fn(doc)
    pcall(function() doc:close() end)
    return result
end

--- 打开文档并补齐缺失封面；不读取或更新元数据。
---@param path string
local function ensureCover(path)
    local ok, err = pcall(withDocument, path, function(doc)
        saveDocumentCover(doc, path)
    end)
    if not ok then
        require("utils.log").warn("book local cover extraction failed", path, err)
    end
end

--- 解析单本书元数据 + 封面；失败返回 nil（损坏 / 无引擎）。
---@param path string 书路径，即 stable_id
---@return { title: string|nil, authors: string|nil, intro: string|nil }|nil
local function parseBookProps(path)
    local ok, props = pcall(withDocument, path, function(doc)
        local p = doc:getProps()
        -- 封面：与元数据同会话提取（无封面的格式返回 nil）
        saveDocumentCover(doc, path)
        return p
    end)
    if not ok or type(props) ~= "table" then
        return nil
    end
    --- 元数据字段归一：非字符串或去空白后为空一律当作缺失。
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
--- 任一目录列不出来就抛错：扫盘结果要按全量快照 reconcile，漏一个目录等于软删其中所有书。
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
        for name in lfs.dir(dir) do
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

--- 扫盘的进程边界：
---   子进程只做文件系统 / 渲染引擎重活（遍历、md5、解析元数据、落封面），**不碰 sqlite**——
---   db.base 禁止子进程访问库（fork 会继承父进程的连接句柄）。
---   主进程在 fork 前查好「已入库且标题非空」的行交给子进程判断是否要解析，
---   子进程返回扫描产物列表，主进程收齐后落库。

--- 主进程：本地源已入库且标题非空的行，按 stable_id（即路径）索引。
---@return table<string, Book>
local function knownBooks()
    local BookDB = require("db.book")
    local rows = BookDB.getMany(SOURCE_ID, BookDB.stableIdsBySource(SOURCE_ID))
    for stable_id, row in pairs(rows) do
        -- 任何展示元数据缺失都要允许本次扫描补齐；只看 title 会把
        -- “有书名但没有作者/简介”的旧行永久冻结。
        if (type(row.title) ~= "string" or row.title == "")
            or (type(row.authors) ~= "string" or row.authors == "")
            or (type(row.intro) ~= "string" or row.intro == "") then
            rows[stable_id] = nil
        end
    end
    return rows
end

--- 子进程：已入库的书只补封面；否则算 md5 并解析元数据（引擎失败回退文件名）。
---@param f table 扫描产物 { name, path, category, series }
---@param known table<string, Book>
---@return table f 原表，未入库时补上 md5/title/authors/intro
local function parseFile(f, known)
    if known[f.path] then
        ensureCover(f.path)
        return f
    end
    f.md5 = util.partialMD5(f.path)
    local props = parseBookProps(f.path) or {}
    f.title, f.authors, f.intro = props.title, props.authors, props.intro
    if not f.title or f.title == "" then
        f.title, f.authors = parseFilename(f.name)
    end
    return f
end

--- 主进程：把子进程解析结果写入 books 表。
--- 已入库行只恢复书架成员；未命中时按内容 md5 找旧行——命中说明文件被移动/改名，
--- 原地换 stable_id（身份以 md5 为准，不当新书），category/series 随新位置刷新；
--- 否则才是真新书。
---@param files table[] parseFile 产物
---@param known table<string, Book>
---@param full_snapshot boolean|nil
---@return boolean
local function commitFiles(files, known, full_snapshot)
    local BookDB = require("db.book")
    for _, f in ipairs(files) do
        local cached = known[f.path]
        local moved
        if not cached then
            local by_md5 = f.md5 and BookDB.getByMd5(SOURCE_ID, f.md5)
            if by_md5 and by_md5.stable_id ~= f.path then
                if not BookDB.renameStableId(
                    SOURCE_ID, by_md5.stable_id, f.path, f.category, f.series
                ) then
                    return false
                end
                moveBookArtifacts(by_md5.stable_id, f.path)
                moved = by_md5
            end
        end
        if full_snapshot then
            f.source_id = SOURCE_ID
            f.stable_id = f.path
            f.deleted = 0
        elseif cached then
            if (tonumber(cached.deleted) or 0) ~= 0
                and not BookDB.setLibraryMembership(SOURCE_ID, f.path, true) then
                return false
            end
        -- knownBooks 只把元数据完整的行交给 worker；移动过来的旧行也会
        -- 在这里用本次解析结果补齐。不要把“已存在”误当成“无需更新”。
        elseif not BookDB.upsert({
            source_id = SOURCE_ID, stable_id = f.path, md5 = f.md5,
            title = f.title, authors = f.authors, intro = f.intro,
            category = f.category, series = f.series,
            inserted_at = moved and moved.inserted_at or os.time(), path = f.path,
        }) then
            return false
        end
    end
    return not full_snapshot
        or BookDB.reconcile(SOURCE_ID, files, { clear_missing_paths = true })
end

--- 扫盘任务：遍历与解析在子进程，落库在主进程，cancel 杀子进程。
--- 扫描成败都调 cb：子进程崩溃/启动失败时库里是旧数据，照查，不让 UI 空转。
---@param root string
---@param cb fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
local function scanJob(root, cb)
    local known = knownBooks()
    local job = Job.run(function()
        local files = scanFiles(root)
        for i = 1, #files do
            files[i] = parseFile(files[i], known)
        end
        return files
    end, {
        name = "local.scan",
        kind = "medium",
        on_done = function(files)
            if commitFiles(files or {}, known, true) then
                cb(true)
            else
                require("utils.log").warn("book local scan commit failed")
                cb(false, "failed to commit local scan")
            end
        end,
        on_failed = function(err)
            require("utils.log").warn("book local scan failed", err)
            cb(false, err or "local scan failed")
        end,
    })
    return { cancel = function()
            job:cancel()
        end }
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
--- stable_id 即文件绝对路径，移动后跟着变；书籍相关身份经 renameStableId 迁移，
--- 封面缓存与 KOReader 的 .sdr 目录（阅读进度/书签/笔记）改名跟随。
--- 编辑对话框保存时同步调用 renameStableId 写库；FS 操作不另起子进程。
---@param stable_id string 当前文件绝对路径
---@param category string|nil
---@param series string|nil
---@return string|nil, string|nil err
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
    if not require("db.book").renameStableId(SOURCE_ID, stable_id, new_path, cat, ser) then
        moveBookArtifacts(new_path, stable_id)
        os.rename(new_path, stable_id)
        return nil, _("更新书籍身份失败")
    end
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
    local taken = lfs.attributes(new_path) and new_path
        or lfs.attributes(new_path .. ".sdr") and new_path .. ".sdr"
    if taken then
        return nil, _("目标位置已有同名文件：") .. taken:match("([^/]+)$")
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

    local BookDB = require("db.book")
    local row = BookDB.get(SOURCE_ID, stable_id)
    local category, series = row and row.category, row and row.series
    if not BookDB.renameStableId(SOURCE_ID, stable_id, new_path, category, series) then
        os.remove(new_path)
        os.rename(backup, stable_id)
        return nil, _("更新书籍身份失败")
    end

    if not os.remove(backup) then
        BookDB.renameStableId(SOURCE_ID, new_path, stable_id, category, series)
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
        return defer(cb, nil, _("无效路径"))
    end
    local name = path:match("([^/]+)$") or path
    if not isBookFile(name) then
        return defer(cb, nil, _("不支持的文件格式"))
    end
    local known = knownBooks()
    local job = Job.run(function()
        return parseFile({ name = name, path = path }, known)
    end, {
        name = "local.index",
        kind = "light",
        on_done = function(f)
            if commitFiles({ f }, known) then
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

--- 强制扫盘写库（不查询）。供 syncBooksAsync(force) 使用。
---@param cb fun(ok: boolean, err: any)
---@return { cancel: fun() }|nil
function Client:scanAsync(cb)
    if self:isWebdav() then
        return self:scanWebdavAsync(cb)
    end
    local ok, err = self:validatePath()
    if not ok then
        return defer(cb, false, err)
    end
    return scanJob(rootPath(self.cfg), cb)
end

--- WebDAV 只同步书目，不下载正文；正文由 openAsync 按需拉取。
---@param cb fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function Client:scanWebdavAsync(cb)
    local ok, err = self:validatePath()
    if not ok then
        return defer(cb, false, err)
    end
    local files = {}
    local progress_files = {}
    local cover_files = {}
    local has_meta = false
    local cancelled = false
    local active
    local function walk(path, prefix, done)
        if cancelled then return end
        active = self.dav:listAsync(path, function(entries, list_err)
            if cancelled then return end
            if list_err then done(nil, list_err); return end
            eachAsync(entries, function(entry, next_entry)
                if cancelled then return end
                local rel = prefix ~= "" and prefix .. "/" .. entry.name or entry.name
                if entry.is_dir then
                    walk(entry.path, rel, function(ok_walk, walk_err)
                        if not ok_walk then done(nil, walk_err); return end
                        next_entry()
                    end)
                    return
                end
                if rel == ".Moon+/books.sync" then
                    has_meta = true
                end
                if isBookFile(entry.name) then
                    files[#files + 1] = rel
                elseif rel:match("^%.Moon%+/Cache/[^/]+%.po$") then
                    progress_files[#progress_files + 1] = rel
                elseif rel:match("^%.Moon%+/Cover/[^/]+%.png$") then
                    cover_files[#cover_files + 1] = rel
                end
                next_entry()
            end, function() done(true) end)
        end)
    end
    walk(self:webdavPath(), "", function(walk_ok, walk_err)
        if cancelled then return end
        if not walk_ok then cb(false, walk_err); return end
        local BookDB = require("db.book")
        local metadata = {}
        local remote_by_rel = {}
        local by_name = {}
        for _, rel in ipairs(files) do
            remote_by_rel[rel] = true
            by_name[progressFileName(rel)] = remoteStableId(rel)
        end
        local function saveBooksSync(done)
            if not has_meta then done(); return end
            local temp = self:webdavCacheRoot() .. "/.books.sync"
            ensureParent(temp)
            self.dav:getAsync(self:webdavPath() .. "/.Moon+/books.sync", temp, nil, function(ok_meta)
                local file = ok_meta and io.open(temp, "rb")
                local raw = file and file:read("*a")
                if file then file:close() end
                local decoded = raw and decodeBooksSync(raw)
                if type(decoded) == "table" then
                    for _, row in ipairs(decoded) do
                        if type(row) == "table" and type(row.filename) == "string" then
                            metadata[row.filename] = row
                        end
                    end
                end
                done()
            end)
        end
        local function uploadBooksSync(done)
            local rows = {}
            for _, rel in ipairs(files) do
                local row = BookDB.get(SOURCE_ID, remoteStableId(rel))
                if row then
                    rows[#rows + 1] = {
                        filename = rel, bookName = row.title,
                        authors = row.authors, category = row.category,
                        series = row.series, intro = row.intro,
                        coverUrl = row.cover,
                    }
                end
            end
            local JSON = require("json")
            local ok_json, encoded = pcall(JSON.encode, rows)
            if not ok_json then done(); return end
            local ok_zlib, Zlib = pcall(require, "ffi/zlib")
            if not ok_zlib then done(); return end
            local ok_compress, compressed = pcall(Zlib.zlib_compress, encoded)
            if not ok_compress then done(); return end
            local temp = self:webdavCacheRoot() .. "/.books.sync.upload"
            ensureParent(temp)
            local out = io.open(temp, "wb")
            local written = out and out:write(compressed)
            local closed = out and out:close()
            if not (written and closed) then os.remove(temp); done(); return end
            self.dav:ensurePathAsync(self:webdavPath() .. "/.Moon+", function(ok_dir)
                if not ok_dir then os.remove(temp); done(); return end
                self.dav:putFileAsync(self:webdavPath() .. "/.Moon+/books.sync", temp, function()
                    os.remove(temp)
                    done()
                end)
            end)
        end
        local function uploadLocalCovers(done)
            local pending = {}
            for _, rel in ipairs(files) do
                local local_cover = coverPath(remoteStableId(rel))
                if lfs.attributes(local_cover, "mode") == "file" then
                    pending[#pending + 1] = { rel = rel, path = local_cover }
                end
            end
            if #pending == 0 then done(); return end
            self.dav:ensurePathAsync(self:webdavPath() .. "/.Moon+/Cover", function(ok_dir)
                if not ok_dir then done(); return end
                eachAsync(pending, function(item, next_cover)
                    self.dav:putFileAsync(
                        self:webdavPath() .. "/.Moon+/Cover/" .. progressFileName(item.rel) .. "_2.png",
                        item.path,
                        function() next_cover() end
                    )
                end, done)
            end)
        end
        local function uploadLocalFiles(done)
            local root = rootPath(self.cfg)
            if root == "" or not lfs.attributes(root, "mode") then done(); return end
            Job.run(function()
                return scanFiles(root)
            end, {
                name = "local.webdav.upload",
                kind = "medium",
                on_done = function(local_files)
                    local pending = {}
                    for _, item in ipairs(local_files or {}) do
                        -- scanFiles 的 path 恒为 root/[分类/[系列/]]文件名，去掉 root 即远端相对路径
                        local rel = item.path:sub(#root + 2)
                        if not remote_by_rel[rel] then
                            pending[#pending + 1] = { item = item, rel = rel }
                        end
                    end
                    eachAsync(pending, function(pending_item, next_file)
                        local item, rel = pending_item.item, pending_item.rel
                        local parent = rel:match("(.+)/[^/]+$")
                        local function upload()
                            self.dav:putFileAsync(self:webdavPath() .. "/" .. rel, item.path,
                                function(ok_upload)
                                    if ok_upload then
                                        local title, authors = parseFilename(item.name)
                                        files[#files + 1] = rel
                                        BookDB.upsertRemote({
                                            source_id = SOURCE_ID, stable_id = remoteStableId(rel),
                                            title = title, authors = authors,
                                            category = item.category, series = item.series,
                                            deleted = 0,
                                        })
                                    end
                                    next_file()
                                end)
                        end
                        if parent then
                            self.dav:ensurePathAsync(self:webdavPath() .. "/" .. parent,
                                function(ok_dir)
                                    if ok_dir then upload() else next_file() end
                                end)
                        else
                            upload()
                        end
                    end, done)
                end,
                on_failed = function()
                    done()
                end,
            })
        end
        local function syncRemoteProgress(done)
            local ProgressDB = require("db.progress")
            local temp = self:webdavCacheRoot() .. "/.progress"
            eachAsync(progress_files, function(rel, next_progress)
                ensureParent(temp)
                self.dav:getAsync(self:webdavPath() .. "/" .. rel, temp, nil, function(ok_progress)
                    local file = ok_progress and io.open(temp, "rb")
                    local raw = file and file:read("*a")
                    if file then file:close() end
                    local pos = decodeProgress(raw)
                    local stable_id = by_name[progressFileName(rel)]
                    if pos and stable_id then
                        local local_pos = ProgressDB.get(SOURCE_ID, stable_id)
                        if not local_pos or (local_pos.sync_status ~= 0 and
                                pos.updated_at > (local_pos.updated_at or 0)) then
                            ProgressDB.upsertRemote(SOURCE_ID, stable_id, pos)
                        end
                    end
                    os.remove(temp)
                    next_progress()
                end)
            end, done)
        end
        local function syncRemoteCovers(done)
            eachAsync(cover_files, function(rel, next_cover)
                -- cover_files 已按 Cover/<书名>[_2].png 过滤，文件名必然存在
                local stable_id = by_name[(rel:match("([^/]+)%.png$"):gsub("_2$", ""))]
                if not stable_id then next_cover(); return end
                local target = coverPath(stable_id)
                if lfs.attributes(target, "mode") == "file" then next_cover(); return end
                ensureParent(target)
                self.dav:getAsync(self:webdavPath() .. "/" .. rel, target .. ".part", nil, function(ok_cover)
                    if ok_cover then
                        os.remove(target)
                        os.rename(target .. ".part", target)
                    else
                        os.remove(target .. ".part")
                    end
                    next_cover()
                end)
            end, done)
        end
        saveBooksSync(function()
            local seen = {}
            for _, rel in ipairs(files) do
                local stable_id = remoteStableId(rel)
                seen[stable_id] = true
                local remote = metadata[rel] or {}
                local title = remote.bookName or remote.title or rel:match("([^/]+)$") or rel
                title = title:gsub("%.[^.]+$", "")
                if not BookDB.upsertRemote({
                    source_id = SOURCE_ID, stable_id = stable_id,
                    title = title, authors = remote.authors,
                    category = remote.category, series = remote.series,
                    intro = remote.intro, cover = remote.coverUrl, deleted = 0,
                }) then
                    cb(false, "failed to save WebDAV book metadata")
                    return
                end
            end
            for _, stable_id in ipairs(BookDB.stableIdsBySource(SOURCE_ID)) do
                if stable_id:match("^webdav://") and not seen[stable_id] then
                    BookDB.setLibraryMembership(SOURCE_ID, stable_id, false, false)
                end
            end
            syncRemoteProgress(function()
                syncRemoteCovers(function()
                    uploadLocalFiles(function()
                        uploadLocalCovers(function()
                            uploadBooksSync(function() cb(true) end)
                        end)
                    end)
                end)
            end)
        end)
    end)
    return { cancel = function()
        cancelled = true
        if active and active.cancel then active:cancel() end
    end }
end

---@param stable_id string
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:openWebdavAsync(stable_id, cb)
    local rel = remoteRelativePath(stable_id)
    if not rel then cb(nil, _("无效的 WebDAV 书籍路径")); return nil end
    local root = self:webdavCacheRoot()
    local target = root .. "/" .. rel
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

---@param stable_id string
---@param cb fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function Client:deleteWebdavAsync(stable_id, cb)
    local rel = remoteRelativePath(stable_id)
    if not rel then cb(false, _("无效的 WebDAV 书籍路径")); return nil end
    return self.dav:deleteAsync(self:webdavPath() .. "/" .. rel, function(ok, err)
        cb(ok == true, err)
    end)
end

--- 推送本地 WebDAV 书的阅读进度；关书时只推脏行。
---@param identity table|nil
---@param cb fun(ok: boolean, err: string|nil)
function Client:syncWebdavProgressAsync(identity, cb)
    local ProgressDB = require("db.progress")
    local pending
    if identity and identity.stable_id then
        local pos = ProgressDB.get(SOURCE_ID, identity.stable_id)
        pending = pos and pos.sync_status == 0 and { pos } or {}
    else
        pending = ProgressDB.unsynced(SOURCE_ID)
    end
    local cancelled = false
    local active
    eachAsync(pending, function(pos, next_progress)
        if cancelled then return end
        local rel = remoteRelativePath(pos.stable_id)
        if not rel then next_progress(); return end
        local temp = self:webdavCacheRoot() .. "/.progress.upload"
        ensureParent(temp)
        local file = io.open(temp, "wb")
        local written = file and file:write(encodeProgress(pos))
        local closed = file and file:close()
        if not (written and closed) then
            os.remove(temp)
            cb(false, "无法保存 WebDAV 阅读进度")
            return
        end
        local path = self:webdavPath() .. "/.Moon+/Cache/" .. progressFileName(rel)
        active = self.dav:ensurePathAsync(self:webdavPath() .. "/.Moon+/Cache", function(ok_dir, dir_err)
            if not ok_dir then os.remove(temp); cb(false, dir_err); return end
            active = self.dav:putFileAsync(path, temp, function(ok_put, put_err)
                os.remove(temp)
                if not ok_put then cb(false, put_err); return end
                ProgressDB.markSynced(SOURCE_ID, pos.stable_id, pos.updated_at)
                next_progress()
            end)
        end)
    end, function()
        if not cancelled then cb(true) end
    end)
    return { cancel = function()
        cancelled = true
        if active and active.cancel then active:cancel() end
    end }
end

--- 打开桌面时的自动扫描（节流 AUTO_SCAN_INTERVAL 秒）：扫盘写库 + 清失效。
---@param cb fun(scanned: boolean, err: string|nil, skipped: boolean|nil)
---@return { cancel: fun() }|nil
function Client:autoScanAsync(cb)
    local path_ok, path_err = self:validatePath()
    if not path_ok then
        cb(false, path_err)
        return nil
    end
    if self:isWebdav() then
        return self:scanWebdavAsync(cb)
    end
    if not self._auto_scan then
        -- 门闩：窗口内再调返回 nil
        self._auto_scan = require("utils.timing").throttle(function()
            return true
        end, AUTO_SCAN_INTERVAL)
    end
    if not self._auto_scan() then
        cb(false, nil, true)
        return nil
    end
    return scanJob(rootPath(self.cfg), cb)
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
