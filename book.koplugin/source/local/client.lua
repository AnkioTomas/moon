--[[--
本地目录扫描客户端（仅异步）

数据流：扫描器只负责把目录状态写进 books 表（增/改/删 + 封面 PNG），
书库/筛选/搜索/最近阅读/统计一律直查数据库，不做内存缓存。


@module koplugin.book.source.local.client
--]]

local lfs = require("libs/libkoreader-lfs")
local UIManager = require("ui/uimanager")
local util = require("util")
local _ = require("gettext")
local Task = require("utils.task")

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
    return (((cfg and cfg.path) or ""):gsub("%s+$", ""):gsub("/+$", ""))
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
    local path = (self.cfg.path or ""):gsub("%s+", "")
    return path ~= ""
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
    local function clean(s)
        if type(s) ~= "string" then
            return nil
        end
        s = s:gsub("^%s+", ""):gsub("%s+$", "")
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
                        -- 下钻：根下的一级目录名是分类，分类下的二级目录名是系列
                        if depth == 1 then
                            walk(path, name, nil, depth + 1)
                        elseif depth == 2 then
                            walk(path, category, name, depth + 1)
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
    name = name:gsub("[%[%(].-[%]%)]", ""):gsub("^%s+", ""):gsub("%s+$", "")
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
    })
end

--- 扫描后清理失效书籍：books 表本源的、本次未扫到的记录删除（不动 reading_stats），连同封面。
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
            BookDB.remove(SOURCE_ID, stable_id)
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
    UIManager:nextTick(function()
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

--- 书库查询（异步）：默认直查数据库；opts.force 先真实扫盘写库再查。
---@param opts table|nil { force, page, page_size, category, series, search }
---@param cb fun(rows: table[]|nil, count: number, err: any)
---@return { cancel: fun() }|nil
function Client:listAsync(opts, cb)
    local ok, err = self:validatePath()
    if not ok then
        UIManager:nextTick(function()
            cb(nil, 0, err)
        end)
        return nil
    end

    if not (type(opts) == "table" and opts.force == true) then
        queryDb(opts, cb)
        return nil
    end

    local root = rootPath(self.cfg)
    return scanJob(root, function()
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
    UIManager:nextTick(function()
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

--- 最近阅读（opens 表按 last_open 倒序）。
---@param limit number|nil
---@param cb fun(rows: table[])
---@return nil
function Client:recentAsync(limit, cb)
    UIManager:nextTick(function()
        cb(require("utils.db.open").recentBySource(SOURCE_ID, limit or 24))
    end)
    return nil
end

--- 阅读统计聚合（reading_stats 表）。
---@param cb fun(summary: table, daily: table[], daily_books: table[])
---@return nil
function Client:insightAsync(cb)
    UIManager:nextTick(function()
        local StatsDB = require("utils.db.stats")
        cb(
            StatsDB.summaryBySource(SOURCE_ID),
            StatsDB.dailyBySource(SOURCE_ID),
            StatsDB.dailyBooksBySource(SOURCE_ID)
        )
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
