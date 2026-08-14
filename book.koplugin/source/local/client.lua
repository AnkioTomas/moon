--[[--
本地目录扫描客户端（仅异步）

扫描规则：
- 最多探测 2 层：根目录直属书（无分类）+ 一级子目录内书（目录名即分类）；更深不识别
- 跳过一切 . 前缀项（.moon 是本插件配置/缓存目录，隐藏项本就不该进书库）
- 书库目录不得落在插件数据目录内（自己的数据不入库）
- 每本书解析元数据（书名/作者/介绍），缓存进 books 表；命中缓存跳过解析
- 扫描结果缓存 5 分钟；TTL 内直接返回缓存，不扫盘、不清理失效书
- opts.force 手动强扫：真实扫盘，并删除 books 表本次未扫到的本源记录（保留阅读统计）

@module koplugin.book.source.local.client
--]]

local lfs = require("libs/libkoreader-lfs")
local UIManager = require("ui/uimanager")
local BookRef = require("types.book").BookRef
local _ = require("gettext")

local Client = {}
Client.__index = Client

local SOURCE_ID = "local"

--- 扫描结果缓存 TTL（秒）
local SCAN_TTL = 5 * 60

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

--- 从配置构造本地客户端。
---@param cfg table|nil
---@return LocalClient
function Client.new(cfg)
    cfg = cfg or {}
    return setmetatable({ cfg = cfg, _cache = { at = 0, files = nil } }, Client)
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

function Client:pingAsync(cb)
    local ok, err = self:validatePath()
    if not ok then
        UIManager:nextTick(function()
            cb(nil, err)
        end)
        return nil
    end
    UIManager:nextTick(function()
        cb({ data = { display_name = _("本地书籍"), username = "" } })
    end)
    return nil
end

--- 解析单本书元数据；失败返回 nil（损坏 / 无引擎）。
--- crengine 需 loadDocument(false) 仅载元数据；close 后注册表引用归零自动清。
---@param path string
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
                                    size = attr.size or 0,
                                    mtime = attr.modification or 0,
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

--- 逐本解析元数据（每 tick 一本，解析重活不堵 UI），写入 f.title/authors/intro。
--- 命中 books 表缓存（title 非空）则跳过解析。
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
        local ref = BookRef.new(SOURCE_ID, f.path)
        local cached = BookDB.get(ref.book_key)
        if cached and type(cached.title) == "string" and cached.title ~= "" then
            f.title = cached.title
            f.authors = cached.authors
            f.intro = cached.intro
        else
            local props = parseBookProps(f.path)
            if props then
                f.title = props.title
                f.authors = props.authors
                f.intro = props.intro
                DbQueue.run(function()
                    BookDB.upsert({
                        book_key = ref.book_key,
                        source_id = SOURCE_ID,
                        stable_id = f.path,
                        filename = f.name,
                        title = props.title,
                        authors = props.authors,
                        intro = props.intro,
                        category = f.category,
                        fetched_at = os.time(),
                    })
                end)
            end
        end
        UIManager:nextTick(step)
    end
    UIManager:nextTick(step)
end

--- 按筛选条件过滤文件列表（当前仅分类，UI「分类」对应 opts.favorite）。
---@param files table[]
---@param opts table|nil
---@return table[]
local function applyFilter(files, opts)
    local category = opts and opts.favorite
    if type(category) ~= "string" or category == "" then
        return files
    end
    local out = {}
    for _, f in ipairs(files) do
        if f.category == category then
            out[#out + 1] = f
        end
    end
    return out
end

--- 手动强扫后清理失效书籍：books 表本源的、本次未扫到的记录删除（不动 reading_stats）。
---@param files table[]
local function pruneMissing(files)
    local keep = {}
    for _, f in ipairs(files) do
        keep[BookRef.keyOf(SOURCE_ID, f.path)] = true
    end
    local BookDB = require("utils.db.book")
    local DbQueue = require("utils.db.queue")
    DbQueue.run(function()
        for _, key in ipairs(BookDB.keysBySource(SOURCE_ID)) do
            if not keep[key] then
                BookDB.remove(key)
            end
        end
    end)
end

--- 扫描目录下的书籍文件（异步）：遍历 → 解析元数据（缓存进 db）。
--- TTL 内直接返回缓存结果（不扫盘、不清理）；opts.force 强扫并清理失效书。
---@param opts table|nil { force: boolean|nil, favorite: string|nil }
---@param cb fun(files: table[]|nil, err: any)
---@return { cancel: fun() }|nil
function Client:listAsync(opts, cb)
    local ok, err = self:validatePath()
    if not ok then
        UIManager:nextTick(function()
            cb(nil, err)
        end)
        return nil
    end

    local force = type(opts) == "table" and opts.force == true
    local cache = self._cache
    if not force and cache.files and (os.time() - cache.at) < SCAN_TTL then
        UIManager:nextTick(function()
            cb(applyFilter(cache.files, opts))
        end)
        return nil
    end

    local root = (self.cfg.path or ""):gsub("%s+$", ""):gsub("/+$", "")
    local cancelled = false
    local function is_cancelled()
        return cancelled
    end

    scanFiles(root, is_cancelled, function(files)
        if is_cancelled() then
            return
        end
        resolveMeta(files, is_cancelled, function()
            if is_cancelled() then
                return
            end
            self._cache = { at = os.time(), files = files }
            if force then
                pruneMissing(files)
            end
            cb(applyFilter(files, opts))
        end)
    end)

    return {
        cancel = function()
            cancelled = true
        end,
    }
end

--- 聚合扫描结果的一级目录名为分类列表（经 listAsync，TTL 内走缓存）。
--- UI「分类」筛选读 favorites 键。
---@param cb fun(data: BookFiltersResult|nil, err: any)
---@return { cancel: fun() }|nil
function Client:filtersAsync(cb)
    return self:listAsync({}, function(files, err)
        if not files then
            cb(nil, err)
            return
        end
        local seen, categories = {}, {}
        for _, f in ipairs(files) do
            local c = f.category
            if c and not seen[c] then
                seen[c] = true
                categories[#categories + 1] = c
            end
        end
        table.sort(categories)
        cb({ data = { favorites = categories } })
    end)
end

--- 本地文件不需要下载，直接复制到缓存目录（保持接口一致）。
---@param local_path string
---@param temp_path string
---@param _on_progress fun(bytes: number)|nil
---@param cb fun(ok: boolean|nil, err: any)
---@return nil
function Client:downloadAsync(local_path, temp_path, _on_progress, cb)
    local ok, err = pcall(function()
        local src = io.open(local_path, "rb")
        if not src then
            error("cannot read: " .. local_path)
        end
        local dst = io.open(temp_path, "wb")
        if not dst then
            src:close()
            error("cannot write: " .. temp_path)
        end
        local chunk_size = 64 * 1024
        while true do
            local chunk = src:read(chunk_size)
            if not chunk then
                break
            end
            dst:write(chunk)
        end
        src:close()
        dst:close()
    end)
    UIManager:nextTick(function()
        if ok then
            cb(true)
        else
            cb(nil, tostring(err))
        end
    end)
    return nil
end

return Client
