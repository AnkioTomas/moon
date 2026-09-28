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
local T = require("ffi/util").template
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
---@field dav WebdavClient
local Client = {}

--- cfg 是 utils.settings 的共享表，设置页和远程配置会原地改它；dav 每次按 cfg 现造，不存快照。
Client.__index = function(self, key)
    if key == "dav" then
        local cfg = rawget(self, "cfg")
        return Webdav.new{
            url = cfg.webdav_url,
            username = cfg.webdav_username,
            password = cfg.webdav_password,
        }
    end
    return Client[key]
end

local SOURCE_ID = "local"

--- 自动扫描节流间隔（秒）：桌面反复打开不重复扫盘
local AUTO_SCAN_INTERVAL = 60

local BOOK_EXT = {
    pdf = true,
    epub = true,
    djvu = true,
    mobi = true,
    azw = true,
    azw3 = true,
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

--- WebDAV 模式下的本地书库目录（书按需下载到这里）；没配置或不可用时为 nil。
---@param self LocalClient
---@return string|nil
local function localRoot(self)
    local root = rootPath(self.cfg)
    return root ~= "" and lfs.attributes(root, "mode") == "directory" and root or nil
end



--- 从配置构造本地客户端。
---@param cfg table|nil
---@return LocalClient
function Client.new(cfg)
    return setmetatable({ cfg = cfg or {} }, Client)
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

--- WebDAV 书文件落地目录（打开时按需下载到这里）：配置了本地书库目录就是它，否则落插件缓存。
---@return string
function Client:webdavBookRoot()
    return localRoot(self) or self:webdavCacheRoot()
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

--- 是否 WebDAV 书。配置 WebDAV 后，按绝对路径登记的书（未收编 / 书库外打开）仍是纯本地书。
---@param stable_id string
---@return boolean
function Client.isRemote(stable_id)
    return remoteRelativePath(stable_id) ~= nil
end

--- 静读天下的 Cover/Cache 边车按书文件 basename 寻址，不含分类目录。
---@param rel string
---@return string
local function sidecarKey(rel)
    return rel:match("([^/]+)$")
end

---@param rel string
---@return string
local function stem(rel)
    return (sidecarKey(rel):gsub("%.[^.]+$", ""))
end

---@param path string
---@return string|nil
local function readFile(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local raw = file:read("*a")
    file:close()
    return raw
end

---@param path string
---@param data string
---@return boolean
local function writeFile(path, data)
    ensureParent(path)
    local file = io.open(path, "wb")
    local written = file and file:write(data)
    local closed = file and file:close()
    if written and closed then return true end
    os.remove(path)
    return false
end

---@param v any
---@return string|nil
local function field(v)
    v = type(v) == "string" and Text.trim(v) or ""
    return v ~= "" and v or nil
end

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
    local _, prefix_num = category:match(SERIES_PREFIX)
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
    for _, key in ipairs(ENTRY_FIELDS) do
        if tostring(a[key] or "") ~= tostring(b[key] or "") then return false end
    end
    return true
end

--- Moon+ Reader 位置文件：`毫秒时间戳*章@分卷#字符偏移:全书百分比%`，如 `1703297605115*21@0#4826:11.1%`。
local function encodeProgress(pos)
    local ts = tonumber(pos.updated_at) or os.time()
    return string.format("%d*%d@0#0:%.1f%%", ts * 1000,
        tonumber(pos.chapter_idx) or 0, (tonumber(pos.fraction) or 0) * 100)
end

--- 兼容旧版写出的 `{秒}*...` 花括号格式与省略 `@分卷#偏移` 的短格式；时间戳统一换算成秒。
local function decodeProgress(raw)
    if type(raw) ~= "string" then return nil end
    local ts, chapter, pct = raw:match("^%s*{?%s*(%d+)%s*}?%*(%-?%d+)[^:]*:([%d%.]+)%%")
    if not ts then return nil end
    ts = tonumber(ts)
    if ts > 1e12 then ts = math.floor(ts / 1000) end
    return {
        updated_at = ts, chapter_idx = tonumber(chapter),
        fraction = math.min(100, tonumber(pct) or 0) / 100,
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

--- 逐项串行异步遍历：step(item, next, index) 处理完一项调 next()，全部处理完调 done()。
---@param list any[]
---@param step fun(item: any, next: fun(), index: integer)
---@param done fun()
local function eachAsync(list, step, done)
    local index = 0
    local function next_item()
        index = index + 1
        local item = list[index]
        if item == nil then
            return done()
        end
        step(item, next_item, index)
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
---@param doc table
---@param path string 封面缓存键（stable_id）
local function saveDocumentCover(doc, path)
    require("book.cover").save(doc, coverPath(path))
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
---@param path string 书路径
---@param cover_key string|nil 封面缓存键（stable_id）；缺省即 path
---@return { title: string|nil, authors: string|nil, intro: string|nil }|nil
local function parseBookProps(path, cover_key)
    local ok, props = pcall(withDocument, path, function(doc)
        local p = doc:getProps()
        -- 封面：与元数据同会话提取（无封面的格式返回 nil）
        saveDocumentCover(doc, cover_key or path)
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

--- 主进程：扫盘解析过的行（有 md5 且有书名），按 stable_id（即路径）索引；
--- 另附全部行（含残缺行与墓碑）的内容 md5，供子进程识别同路径换了文件。
---@return table<string, Book> known, table<string, string> digests
local function knownBooks()
    local BookDB = require("db.book")
    local rows = BookDB.getMany(SOURCE_ID, BookDB.stableIdsBySource(SOURCE_ID))
    local digests = {}
    for stable_id, row in pairs(rows) do
        digests[stable_id] = row.md5
        -- md5 只由扫盘/入库写入，有它就说明按当前内容解析过；作者/简介缺失多半是书本身没有，
        -- 按缺字段判定会让每次扫盘重开几乎所有书。无 md5 的身份行（开书时登记）照常解析补齐。
        if not row.md5 or type(row.title) ~= "string" or row.title == "" then
            rows[stable_id] = nil
        end
    end
    return rows, digests
end

--- 子进程：算 md5；已入库且内容没变的书只补缺失封面，否则解析元数据（引擎失败回退文件名）。
--- 同路径内容变了（删书后拷入同名新书 / 覆盖上传）标 changed 并删掉旧封面，按新书重新提取。
--- 引擎段错误 pcall 接不住，子进程直接死：打开文档前后各报一次 progress（path / false），
--- 父进程据此认出致死的书，下一轮放进 skip 只按文件名入库。
---@param f table 扫描产物 { name, path, category, series }
---@param known table<string, Book>
---@param digests table<string, string> 库内各路径的内容 md5
---@param skip table<string, boolean> 曾让子进程崩溃的书，不再打开
---@param tried table<string, boolean> 本会话已为补封面打开过的书（本身没封面的书不必每轮重开）
---@param progress fun(value: string|false)
---@return table f 原表，补上 md5/changed/cover_tried，需解析时再补 title/authors/intro
local function parseFile(f, known, digests, skip, tried, progress)
    local open = not skip[f.path]
    f.md5 = util.partialMD5(f.path)
    local old = digests[f.path]
    f.changed = f.md5 ~= nil and old ~= nil and old ~= f.md5
    if f.changed then
        os.remove(coverPath(f.path))
    elseif known[f.path] then
        if open and not tried[f.path] and lfs.attributes(coverPath(f.path), "mode") ~= "file" then
            f.cover_tried = true
            progress(f.path)
            ensureCover(f.path)
            progress(false)
        end
        return f
    end
    local props = {}
    if open then
        f.cover_tried = true
        progress(f.path)
        props = parseBookProps(f.path) or {}
        progress(false)
    end
    f.title, f.authors, f.intro = props.title, props.authors, props.intro
    if not f.title or f.title == "" then
        f.title, f.authors = parseFilename(f.name)
    end
    return f
end

--- 主进程：把子进程解析结果写入 books 表。
--- 已入库且内容未变的行只恢复书架成员（changed 行按新解析结果重写）；未命中时按内容 md5 找旧行——旧文件已不在盘上且新路径无任何行
--- （known 不含元数据残缺行与墓碑）才算移动/改名，原地换 stable_id（身份以 md5 为准，不当新书），
--- category/series 随新位置刷新；同内容副本并存时各自成书，否则改名会撞主键让整次扫盘失败。
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
            if by_md5 and by_md5.stable_id ~= f.path
                and not lfs.attributes(by_md5.stable_id, "mode")
                and not BookDB.get(SOURCE_ID, f.path) then
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
        end
        if cached and not f.changed then
            if not full_snapshot and (tonumber(cached.deleted) or 0) ~= 0
                and not BookDB.setLibraryMembership(SOURCE_ID, f.path, true) then
                return false
            end
        -- knownBooks 只把解析过的行交给 worker；移动过来的旧行也会
        -- 在这里用本次解析结果补齐。不要把“已存在”误当成“无需更新”。
        -- 换了内容的行即便走快照也要本地可信写入：reconcile 对脏行保留旧书名。
        elseif (f.changed or not full_snapshot) and not BookDB.upsert({
            source_id = SOURCE_ID, stable_id = f.path, md5 = f.md5,
            title = f.title, authors = f.authors, intro = f.intro,
            category = f.category, series = f.series,
            inserted_at = moved and moved.inserted_at or os.time(), path = f.path,
        }) then
            return false
        end
        if f.changed then
            require("ui.components.image").invalidate(coverPath(f.path))
        end
    end
    return not full_snapshot
        or BookDB.reconcile(SOURCE_ID, files, { clear_missing_paths = true })
end

--- 扫盘任务：遍历与解析在子进程，落库在主进程，cancel 杀子进程。
--- 子进程死在某本书的引擎里时跳过它重扫（每轮至少多跳一本，必然收敛），本会话内不再打开它；
--- 其余失败照常回调，库里是旧数据，照查，不让 UI 空转。
--- 子进程 progress 两种帧：`{ i, n, name }` 是逐本计数；路径 / false 是开文档前后的崩溃探针。
---@param self LocalClient
---@param cb fun(ok: boolean, err: string|nil)
---@param report fun(text: string, done: integer|nil, total: integer|nil)|nil
---@return { cancel: fun() }
local function scanJob(self, cb, report)
    report = report or function() end
    local root = rootPath(self.cfg)
    local known, digests = knownBooks()
    local job
    -- 崩溃记录跨轮保留：入库后缺封面还会被补提，不记住的话每轮扫盘都要再崩一次、整轮重来
    self._crashed = self._crashed or {}
    self._cover_tried = self._cover_tried or {}
    local skip, tried = self._crashed, self._cover_tried
    local function start()
        local opening, count
        report(_("正在扫描书库…"))
        job = Job.run(function(progress)
            local files = scanFiles(root)
            for i = 1, #files do
                progress({ i, #files, files[i].name })
                files[i] = parseFile(files[i], known, digests, skip, tried, progress)
            end
            return files
        end, {
            name = "local.scan",
            kind = "medium",
            on_progress = function(value)
                if type(value) == "table" then
                    count = value
                    report(T(_("正在检查 %1"), value[3]), value[1], value[2])
                    return
                end
                opening = value or nil
                if opening and count then
                    report(T(_("正在解析 %1"), count[3]), count[1], count[2])
                end
            end,
            on_done = function(files)
                for _, f in ipairs(files or {}) do
                    if f.cover_tried then tried[f.path] = true end
                end
                if commitFiles(files or {}, known, true) then
                    cb(true)
                else
                    require("utils.log").warn("book local scan commit failed")
                    cb(false, "failed to commit local scan")
                end
            end,
            on_failed = function(err)
                if opening and not skip[opening] then
                    require("utils.log").warn("book local scan crashed; skip", opening, err)
                    skip[opening] = true
                    return start()
                end
                require("utils.log").warn("book local scan failed", err)
                cb(false, err or "local scan failed")
            end,
        })
    end
    start()
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
    local known, digests = knownBooks()
    local job = Job.run(function(progress)
        return parseFile({ name = name, path = path }, known, digests, {}, {}, progress)
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
---@param report fun(text: string, done: integer|nil, total: integer|nil)|nil 真实步骤上报
---@return { cancel: fun() }|nil
function Client:scanAsync(cb, report)
    if self:isWebdav() then
        return self:scanWebdavAsync(cb, { refresh = true, on_progress = report })
    end
    local ok, err = self:validatePath()
    if not ok then
        return defer(cb, false, err)
    end
    return scanJob(self, cb, report)
end

--- 远端 .Moon+ 下的路径。
---@param self LocalClient
---@param name string
---@return string
local function moonPath(self, name)
    return self:webdavPath() .. "/.Moon+/" .. name
end

---@param self LocalClient
---@param rel string
local function coverRemotePath(self, rel)
    return moonPath(self, "Cover/" .. sidecarKey(rel) .. "_2.png")
end

---@param self LocalClient
---@param rel string
local function progressRemotePath(self, rel)
    return moonPath(self, "Cache/" .. sidecarKey(rel) .. ".po")
end

--- 本插件自有格式（Moon+ 没有笔记文件）：`{ [device_id] = KOReader 注解数组 }`。
---@param self LocalClient
---@param rel string
local function notesRemotePath(self, rel)
    return moonPath(self, "Notes/" .. sidecarKey(rel) .. ".json")
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
            for _, item in ipairs(files) do run.local_files[item.path:sub(#root + 2)] = item end
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
    local BookDB = require("db.book")
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
    for _, row in ipairs(require("db.book").unsynced(SOURCE_ID)) do
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
            for _, entry in ipairs(decoded) do
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

        local BookDB = require("db.book")
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
        for _, rel in ipairs(run.files) do member[rel] = true end
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
    local ProgressDB = require("db.progress")
    run.report(_("正在检查阅读进度…"))
    run.active = self.dav:listAsync(moonPath(self, "Cache"), function(entries, err)
        if run.cancelled then return end
        if not entries then
            require("utils.log").warn("book webdav progress list failed", err)
            return next()
        end
        local by_key = {}
        for _, rel in ipairs(run.files) do by_key[sidecarKey(rel)] = rel end
        local pending = {}
        for _, entry in ipairs(entries) do
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
            for _, rel in ipairs(run.files) do run.covers[sidecarKey(rel)] = true end
            return next()
        end
        for _, entry in ipairs(entries) do
            local key = entry.name:match("^(.+)_2%.png$")
            if key then run.covers[key] = true end
        end
        local pending = {}
        for _, rel in ipairs(run.files) do
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
    local rows = require("db.book").getMany(SOURCE_ID, ids)
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
            local BookDB = require("db.book")
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
    local BookDB = require("db.book")
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
    local BookDB = require("db.book")
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
    for _, rel in ipairs(run.files) do member[rel] = true end
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
    for _, rel in ipairs(run.files) do
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
    local BookDB = require("db.book")
    local ids = {}
    for i, rel in ipairs(run.files) do ids[i] = remoteStableId(rel) end
    local rows = BookDB.getMany(SOURCE_ID, ids)
    local ctx = {
        root = self:webdavPath(),
        device_id = require("utils.settings").ensureDeviceId(),
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
        for _, stable_id in ipairs(dirty_ids) do BookDB.markSynced(SOURCE_ID, stable_id) end
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
function Client:scanWebdavAsync(cb, opts)
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
function Client:openWebdavAsync(stable_id, cb)
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
    active = self.dav:getAsync(moonPath(self, "books.sync"), temp, nil, function(ok, _, code)
        if cancelled then return end
        local raw = ok and readFile(temp)
        os.remove(temp)
        if not ok and code ~= 404 then return cb(false) end
        local decoded = {}
        if ok then decoded = raw and decodeBooksSync(raw) end
        if type(decoded) ~= "table" then return cb(false) end
        local list, old, at = {}, nil, nil
        for _, entry in ipairs(decoded) do
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
function Client:deleteWebdavAsync(stable_id, cb)
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
function Client:pushBookAsync(stable_id, cover, cb)
    local rel = remoteRelativePath(stable_id)
    if not rel then return defer(cb, true) end
    local BookDB = require("db.book")
    -- upsertLocal 不标脏已有行；不标的话推送失败后下一轮 reconcile 会用远端书目把改动盖回去。
    BookDB.setLibraryMembership(SOURCE_ID, stable_id, true)
    local cancelled, active = false, nil
    local function pushEntry()
        local ctx = {
            root = self:webdavPath(),
            device_id = require("utils.settings").ensureDeviceId(),
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
function Client:replaceWebdavAsync(temp_path, stable_id, cb)
    local rel = remoteRelativePath(stable_id)
    if not rel then return defer(cb, nil, _("无效的 WebDAV 书籍路径")) end
    local new_rel = rel:gsub("%.[^./]+$", ".epub")
    if new_rel == rel then return defer(cb, nil, _("原书已经是 EPUB")) end
    local BookDB = require("db.book")
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

--- 用转换后的临时 EPUB 替换原书，按身份分派：webdav:// 走远端替换，其余是本地文件替换。
---@param temp_path string
---@param stable_id string
---@param cb fun(new_path: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:replaceBookAsync(temp_path, stable_id, cb)
    if remoteRelativePath(stable_id) then
        return self:replaceWebdavAsync(temp_path, stable_id, cb)
    end
    return defer(cb, self:replaceBook(temp_path, stable_id))
end

--- 连通性测试：在书库目录写入探针文件、读回比对、再删除。
---@param cb fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function Client:testWebdavAsync(cb)
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

--- 下载远端小文件并读出内容；远端不存在时 cb(nil, nil, true)。
---@param self LocalClient
---@param remote string
---@param temp string
---@param cb fun(raw: string|nil, err: string|nil, missing: boolean|nil)
---@return { cancel: fun() }
local function fetchText(self, remote, temp, cb)
    ensureParent(temp)
    return self.dav:getAsync(remote, temp, nil, function(ok, err, code)
        local raw = ok and readFile(temp)
        os.remove(temp)
        if raw then return cb(raw) end
        cb(nil, err or _("读取失败"), code == 404)
    end)
end

--- 上传一段文本到远端（先建父目录）。
---@param self LocalClient
---@param remote string
---@param temp string
---@param data string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function putText(self, remote, temp, data, cb)
    if not writeFile(temp, data) then
        cb(nil, _("无法写入临时文件"))
        return nil
    end
    local cancelled, active = false, nil
    active = self.dav:ensurePathAsync(remote:match("(.+)/[^/]+$"), function(ok_dir, dir_err)
        if cancelled then return end
        if not ok_dir then os.remove(temp); return cb(nil, dir_err) end
        active = self.dav:putFileAsync(remote, temp, function(ok, err)
            os.remove(temp)
            if not cancelled then cb(ok, err) end
        end)
    end)
    return { cancel = function()
        cancelled = true
        if active and active.cancel then active:cancel() end
        os.remove(temp)
    end }
end

--- 拉取单本进度（开书时由 book.progress 调用，冲突弹窗在那边）。
---@param stable_id string
---@param cb fun(pos: ProgressPosition|nil, err: string|nil, meta: table|nil)
---@return { cancel: fun() }|nil
function Client:getProgressAsync(stable_id, cb)
    local rel = remoteRelativePath(stable_id)
    if not rel then defer(cb, nil, nil, { empty = true }); return nil end
    return fetchText(self, progressRemotePath(self, rel), self:webdavCacheRoot() .. "/.progress.get",
        function(raw, err, missing)
            if missing then return cb(nil, nil, { empty = true }) end
            if not raw then return cb(nil, err) end
            local pos = decodeProgress(raw)
            if pos then cb(pos) else cb(nil, _("进度为空")) end
        end)
end

--- 推送单本进度（关书 / 网络恢复时由 book.progress 推脏行）。非 webdav:// 身份没有远端，直接成功。
---@param stable_id string
---@param pos ProgressPosition
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:putProgressAsync(stable_id, pos, cb)
    local rel = remoteRelativePath(stable_id)
    if not rel then defer(cb, true); return nil end
    return putText(self, progressRemotePath(self, rel), self:webdavCacheRoot() .. "/.progress.upload",
        encodeProgress(pos), cb)
end

--- 统计行在 stats.json 里的身份：同一设备同一本书同一开始时间只算一条。
local function statKey(row)
    return tostring(row.device_id) .. "\31" .. tostring(row.filename) .. "\31" .. tostring(row.start_time)
end

--- 读 stats.json（JSON 数组，行形如 book 服务端 /index/stats/import 的 stats[]，外加 device_id）。
---@param self LocalClient
---@param cb fun(rows: table[]|nil, err: string|nil, missing: boolean|nil)
---@return { cancel: fun() }
local function readStats(self, cb)
    return fetchText(self, moonPath(self, "Stats/stats.json"), self:webdavCacheRoot() .. "/.stats.json",
        function(raw, err, missing)
            if missing then return cb({}, nil, true) end
            if not raw then return cb(nil, err) end
            local ok, rows = pcall(require("json").decode, raw)
            if not ok or type(rows) ~= "table" then return cb(nil, _("阅读统计文件损坏")) end
            cb(rows)
        end)
end

--- 上报统计：读远端全量、按 statKey 合并、整文件写回。所有设备共用一个文件，
--- 写前先读能把并发覆盖缩到“两台设备同一时刻写”的窗口，但消不掉。
--- WebDAV 书写相对路径（和 book 服务端同构）；其它本地书写绝对路径，拉取时只认本设备的。
---@param rows BookStatsRow[]
---@param cb fun(result: BookStatsPushResult|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:pushStatsAsync(rows, cb)
    local device_id = require("utils.settings").ensureDeviceId()
    local cancelled, active = false, nil
    active = readStats(self, function(remote, err)
        if cancelled then return end
        if not remote then return cb(nil, err) end
        local seen, added = {}, 0
        for _, row in ipairs(remote) do
            if type(row) == "table" then seen[statKey(row)] = true end
        end
        for _, row in ipairs(rows) do
            local wire = {
                filename = remoteRelativePath(row.stable_id) or row.stable_id, device_id = device_id,
                page = row.page, start_time = row.start_time,
                duration = row.duration, total_pages = row.total_pages,
            }
            if not seen[statKey(wire)] then
                seen[statKey(wire)] = true
                remote[#remote + 1] = wire
                added = added + 1
            end
        end
        if added == 0 then return cb({}) end
        active = putText(self, moonPath(self, "Stats/stats.json"), self:webdavCacheRoot() .. "/.stats.upload",
            require("json").encode(remote), function(ok, put_err)
                if cancelled then return end
                if ok then cb({}) else cb(nil, put_err) end
            end)
    end)
    return { cancel = function()
        cancelled = true
        if active and active.cancel then active:cancel() end
    end }
end

--- 拉取统计。远端是全部设备的全量快照：非空时覆盖本地全部已同步行
--- （含本地 30 天压缩出的汇总行，否则汇总行 + 原始行会重复计时）；
--- 文件不存在或为空时只追加，不能拿空快照抹掉本地历史。
---@param cb fun(result: BookStatsRow[]|BookStatsPullResult|nil, err: string|nil)
---@return { cancel: fun() }
function Client:pullStatsAsync(cb)
    local device_id = require("utils.settings").ensureDeviceId()
    return readStats(self, function(remote, err)
        if not remote then return cb(nil, err) end
        local rows = {}
        for _, item in ipairs(remote) do
            local filename = type(item) == "table" and field(item.filename)
            local stable_id = filename and (filename:sub(1, 1) ~= "/" and remoteStableId(filename)
                or item.device_id == device_id and filename or nil)
            if stable_id then
                rows[#rows + 1] = {
                    source_id = SOURCE_ID, stable_id = stable_id, record_type = "page",
                    page = tonumber(item.page) or 0, start_time = tonumber(item.start_time),
                    duration = tonumber(item.duration), total_pages = tonumber(item.total_pages) or 0,
                }
            end
        end
        cb(#rows > 0 and { rows = rows, replace = { mode = "all_synced" } } or rows)
    end)
end

--- 读一本书的笔记文件；远端没有时 missing。
---@param self LocalClient
---@param rel string
---@param cb fun(devices: table|nil, err: string|nil, missing: boolean|nil)
---@return { cancel: fun() }
local function readNotes(self, rel, cb)
    return fetchText(self, notesRemotePath(self, rel), self:webdavCacheRoot() .. "/.notes.get",
        function(raw, err, missing)
            if missing then return cb({}, nil, true) end
            if not raw then return cb(nil, err) end
            local ok, devices = pcall(require("json").decode, raw)
            if not ok or type(devices) ~= "table" then return cb(nil, _("笔记文件损坏")) end
            cb(devices)
        end)
end

--- 注解坐标：分页文档的 pos 是 {x,y,page} 表，不能直接 tostring。
local function posKey(pos)
    if type(pos) == "table" then
        return table.concat({ tostring(pos.x), tostring(pos.y), tostring(pos.page) }, ",")
    end
    return tostring(pos or "")
end

--- 上传本设备这本书的完整注解快照；别的设备的快照原样保留（语义同 book 服务端 annotations 接口）。
--- 非 webdav:// 身份没有远端，直接成功。
---@param stable_id string
---@param annotations table[]
---@param cb fun(value: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:pushNotesAsync(stable_id, annotations, cb)
    local rel = remoteRelativePath(stable_id)
    if not rel then defer(cb, {}); return nil end
    local JSON = require("json")
    local device_id = require("utils.settings").ensureDeviceId()
    local cancelled, active = false, nil
    active = readNotes(self, rel, function(devices, err)
        if cancelled then return end
        if not devices then return cb(nil, err) end
        devices[device_id] = #annotations > 0 and annotations or JSON.util.InitArray({})
        active = putText(self, notesRemotePath(self, rel), self:webdavCacheRoot() .. "/.notes.upload",
            JSON.encode(devices), function(ok, put_err)
                if cancelled then return end
                if ok then cb({}) else cb(nil, put_err) end
            end)
    end)
    return { cancel = function()
        cancelled = true
        if active and active.cancel then active:cancel() end
    end }
end

--- 拉取所有设备快照的并集，同一位置（页 + 起止坐标）只留最后修改的一条。
--- 删除只在删过它的设备快照里消失：另一台设备的快照还带着它时会被并回来（与 book 服务端一致）。
--- 远端还没有笔记文件时不报权威快照，免得把本地已同步的笔记当成“云端已删”清掉。
---@param stable_id string
---@param cb fun(annotations: table[]|nil, err: string|nil, meta: table|nil)
---@return { cancel: fun() }|nil
function Client:pullNotesAsync(stable_id, cb)
    local rel = remoteRelativePath(stable_id)
    if not rel then defer(cb, {}, nil, nil); return nil end
    return readNotes(self, rel, function(devices, err, missing)
        if not devices then return cb(nil, err) end
        local by_pos, order = {}, {}
        for _, items in pairs(devices) do
            for _, item in ipairs(type(items) == "table" and items or {}) do
                if type(item) == "table" and item.page ~= nil then
                    local key = posKey(item.page) .. "\31" .. posKey(item.pos0) .. "\31" .. posKey(item.pos1)
                    local cur = by_pos[key]
                    local stamp = tostring(item.datetime_updated or item.datetime or "")
                    if not cur then order[#order + 1] = key end
                    if not cur or stamp > tostring(cur.datetime_updated or cur.datetime or "") then
                        by_pos[key] = item
                    end
                end
            end
        end
        local out = {}
        for i, key in ipairs(order) do out[i] = by_pos[key] end
        cb(out, nil, { authoritative = not missing })
    end)
end

--- 打开桌面时的自动扫描（节流 AUTO_SCAN_INTERVAL 秒）：扫盘写库 + 清失效。
---@param cb fun(scanned: boolean, err: string|nil, skipped: boolean|nil)
---@param report fun(text: string, done: integer|nil, total: integer|nil)|nil 真实步骤上报
---@return { cancel: fun() }|nil
function Client:autoScanAsync(cb, report)
    local path_ok, path_err = self:validatePath()
    if not path_ok then
        cb(false, path_err)
        return nil
    end
    if self:isWebdav() then
        return self:scanWebdavAsync(cb, { on_progress = report })
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
    return scanJob(self, cb, report)
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
