--[[--
本地目录扫描客户端（仅异步）

数据流：扫描器只负责把目录状态写进 books 表（增/改/删 + 封面 PNG），
书库/筛选/搜索/最近阅读/统计一律直查数据库，不做内存缓存。

扫描规则：
- 最多探测 2 层：根目录直属书（无分类）+ 一级子目录内书（目录名即分类）；更深不识别
- 跳过一切 . 前缀项（.moon 是本插件配置/缓存目录，隐藏项本就不该进书库）
- 书库目录不得落在插件数据目录内（自己的数据不入库）
- 每本书解析元数据（书名/作者/介绍）与封面，缓存进 books 表 / image 目录；命中缓存跳过解析
- 扫描结束删除 books 表本次未扫到的本源记录（保留阅读统计），并删对应封面

@module koplugin.book.source.local.client
--]]

local lfs = require("libs/libkoreader-lfs")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Client = {}
Client.__index = Client

local SOURCE_ID = "local"

--- 自动扫描最小间隔（秒）：桌面反复打开不重复扫盘
local AUTO_SCAN_MIN_INTERVAL = 60

--- 封面缓存最大宽度（等比缩放，控制缓存体积）
local COVER_MAX_W = 320
--- 封面缓存最大高度
local COVER_MAX_H = 480

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

--- 文件内容 partialMD5（非均匀采样：头部权重大，尾部权重小，避免整本读入）。
--- 失败（文件不可读）返回 nil。
---@param path string
---@return string|nil
local function fileMd5(path)
    local md5 = require("ffi/sha2").md5
    local bit = require("bit")
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local step, size = 1024, 1024
    local update = md5()
    for i = -1, 10 do
        f:seek("set", bit.lshift(step, 2 * i))
        local sample = f:read(size)
        if sample then
            update(sample)
        else
            break
        end
    end
    f:close()
    return update()
end

--- 从配置构造本地客户端。
---@param cfg table|nil
---@return LocalClient
function Client.new(cfg)
    cfg = cfg or {}
    return setmetatable({ cfg = cfg, _auto_scan_at = 0 }, Client)
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
    local path = (self.cfg.path or ""):gsub("%s+$", ""):gsub("/+$", "")
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

--- 把封面 blitbuffer 缩放落盘为 PNG。
---@param bb any
---@param stable_id string
local function saveCover(bb, stable_id)
    if not bb then
        return
    end
    local w = tonumber(bb.getWidth and bb:getWidth()) or 0
    local h = tonumber(bb.getHeight and bb:getHeight()) or 0
    if w <= 0 or h <= 0 then
        return
    end
    if w > COVER_MAX_W or h > COVER_MAX_H then
        local ok_r, RenderImage = pcall(require, "ui/renderimage")
        if ok_r and RenderImage and RenderImage.scaleBlitBuffer then
            local scaled = RenderImage:scaleBlitBuffer(bb, COVER_MAX_W, COVER_MAX_H)
            if scaled and scaled ~= bb then
                pcall(function() bb:free() end)
                bb = scaled
            end
        end
    end
    local path = coverPath(stable_id)
    local tmp = path .. ".part"
    local ok = pcall(function() bb:writePNG(tmp) end)
    pcall(function() bb:free() end)
    if not ok then
        pcall(os.remove, tmp)
        return
    end
    pcall(os.remove, path)
    if not os.rename(tmp, path) then
        pcall(os.remove, tmp)
    end
end

--- 解析单本书元数据 + 封面；失败返回 nil（损坏 / 无引擎）。
--- crengine 需 loadDocument(false) 仅载元数据；close 后注册表引用归零自动清。
---@param path string
---@param stable_id string
---@return { title: string|nil, authors: string|nil, intro: string|nil }|nil
local function parseBookProps(path, stable_id)
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
        if lfs.attributes(coverPath(stable_id), "mode") ~= "file" then
            local ok_cover, cover_bb = pcall(function()
                return doc:getCoverPageImage()
            end)
            if ok_cover and cover_bb then
                saveCover(cover_bb, stable_id)
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

--- 目录遍历（协程式分片，最多 2 层），产出书籍文件列表。
--- 根目录直属文件 category=nil；一级子目录内文件 category=目录名；更深忽略。
---@param root string
---@param is_cancelled fun(): boolean
---@param cb fun(files: table[])
local function scanFiles(root, is_cancelled, cb)
    local files = {}
    local queue = { { path = root, category = nil, depth = 1 } }
    local budget = 32
    local function step()
        if is_cancelled() then
            return
        end
        local n = 0
        while n < budget and #queue > 0 do
            n = n + 1
            local task = table.remove(queue)
            local iter_ok, iter, state = pcall(lfs.dir, task.path)
            if iter_ok and iter then
                for name in iter, state do
                    -- 跳过 . .. 及一切 . 前缀项（.moon 等隐藏目录/文件）
                    if name:sub(1, 1) ~= "." then
                        local path = task.path .. "/" .. name
                        local attr = lfs.attributes(path)
                        if attr then
                            if attr.mode == "directory" then
                                if task.depth < 2 then
                                    queue[#queue + 1] = { path = path, category = name, depth = 2 }
                                end
                            elseif attr.mode == "file" and isBookFile(name) then
                                files[#files + 1] = {
                                    name = name,
                                    path = path,
                                    category = task.category,
                                }
                            end
                        end
                    end
                end
            end
        end
        if #queue > 0 then
            UIManager:nextTick(step)
        else
            table.sort(files, function(a, b)
                return a.path < b.path
            end)
            cb(files)
        end
    end
    UIManager:nextTick(step)
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

--- 逐本解析元数据（每 tick 一本，解析重活不堵 UI），写入 books 表。
--- 命中 books 表缓存（title 非空）则跳过解析。路径未命中时按内容 md5 找旧行：
--- 命中说明文件被移动/改名，原地把 stable_id 换成新路径（身份以 md5 为准，不当新书）；
--- 否则才是真新书，解析引擎失败回退文件名。
---@param files table[]
---@param is_cancelled fun(): boolean
---@param cb fun()
local function resolveMeta(files, is_cancelled, cb)
    local BookDB = require("utils.db.book")
    local DbQueue = require("utils.db.queue")
    local i = 0
    local function step()
        if is_cancelled() then
            return
        end
        i = i + 1
        local f = files[i]
        if not f then
            cb()
            return
        end
        local cached = BookDB.get(SOURCE_ID, f.path)
        if cached and type(cached.title) == "string" and cached.title ~= "" then
            UIManager:nextTick(step)
            return
        end
        local digest = fileMd5(f.path)
        local moved_from = nil
        if digest then
            local by_md5 = BookDB.getByMd5(SOURCE_ID, digest)
            if by_md5 and by_md5.stable_id ~= f.path then
                moved_from = by_md5.stable_id
            end
        end
        if moved_from then
            DbQueue.run(function()
                BookDB.renameStableId(SOURCE_ID, moved_from, f.path)
            end)
            local old_cover, new_cover = coverPath(moved_from), coverPath(f.path)
            if lfs.attributes(old_cover, "mode") == "file" then
                pcall(os.rename, old_cover, new_cover)
            end
            UIManager:nextTick(step)
            return
        end
        local props = parseBookProps(f.path, f.path) or {}
        local title, authors, intro = props.title, props.authors, props.intro
        if not title or title == "" then
            title, authors = parseFilename(f.name)
        end
        DbQueue.run(function()
            BookDB.upsert({
                source_id = SOURCE_ID,
                stable_id = f.path,
                md5 = digest,
                title = title,
                authors = authors,
                intro = intro,
                category = f.category,
                fetched_at = os.time(),
            })
        end)
        UIManager:nextTick(step)
    end
    UIManager:nextTick(step)
end

--- 扫描后清理失效书籍：books 表本源的、本次未扫到的记录删除（不动 reading_stats），连同封面。
--- 改名/移动的书已在 resolveMeta 里原地更新 stable_id，这里的 keep 集合天然包含它们。
---@param files table[]
local function pruneMissing(files)
    local keep = {}
    for _, f in ipairs(files) do
        keep[f.path] = true
    end
    local BookDB = require("utils.db.book")
    local DbQueue = require("utils.db.queue")
    DbQueue.run(function()
        for _, stable_id in ipairs(BookDB.stableIdsBySource(SOURCE_ID)) do
            if not keep[stable_id] then
                BookDB.remove(SOURCE_ID, stable_id)
                pcall(os.remove, coverPath(stable_id))
            end
        end
    end)
end

--- 真实扫盘并写库：遍历 → 解析元数据/封面 → 清失效。
---@param root string
---@param is_cancelled fun(): boolean
---@param cb fun()
local function scanIntoDb(root, is_cancelled, cb)
    require("utils.paths").ensureLayout(SOURCE_ID)
    scanFiles(root, is_cancelled, function(files)
        if is_cancelled() then
            return
        end
        resolveMeta(files, is_cancelled, function()
            if is_cancelled() then
                return
            end
            pruneMissing(files)
            cb()
        end)
    end)
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

    local root = (self.cfg.path or ""):gsub("%s+$", ""):gsub("/+$", "")
    local cancelled = false
    scanIntoDb(root, function()
        return cancelled
    end, function()
        if cancelled then
            return
        end
        queryDb(opts, cb)
    end)
    return {
        cancel = function()
            cancelled = true
        end,
    }
end

--- 打开桌面时的自动扫描（节流 AUTO_SCAN_MIN_INTERVAL 秒）：扫盘写库 + 清失效。
---@param cb fun(scanned: boolean)|nil
---@return { cancel: fun() }|nil
function Client:autoScanAsync(cb)
    cb = cb or function() end
    local ok = self:validatePath()
    if not ok then
        UIManager:nextTick(function()
            cb(false)
        end)
        return nil
    end
    local now = os.time()
    if now - (self._auto_scan_at or 0) < AUTO_SCAN_MIN_INTERVAL then
        UIManager:nextTick(function()
            cb(false)
        end)
        return nil
    end
    self._auto_scan_at = now
    local root = (self.cfg.path or ""):gsub("%s+$", ""):gsub("/+$", "")
    local cancelled = false
    scanIntoDb(root, function()
        return cancelled
    end, function()
        if not cancelled then
            cb(true)
        end
    end)
    return {
        cancel = function()
            cancelled = true
        end,
    }
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
