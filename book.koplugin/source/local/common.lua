--[[--
本地源客户端的共享原语：路径与边车寻址、文件读写、远端小文件读写、串行异步遍历、Moon+ 进度编解码，
以及扫盘和 WebDAV 都要用的磁盘 / 文档操作（目录遍历、元数据与封面解析、附属资源迁移）。
零 UI 依赖。

@module koplugin.book.source.local.common
--]]

local lfs = require("libs/libkoreader-lfs")
local Text = require("utils.text")
local Paths = require("utils.paths")
local _ = require("gettext")
local defer = require("source.base").defer

local SOURCE_ID = "local"
--- 扫盘最多下钻的目录层数（根为 1）：防止误选 / 之类的大目录时无止境遍历。
local MAX_DEPTH = 8

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
    -- KOReader（crengine）也能开的：Kindle 老格式、网页、Office、压缩 fb2/html。
    prc = true,
    htm = true,
    xhtml = true,
    doc = true,
    odt = true,
    epub3 = true,
    ["fb2.zip"] = true,
    ["htm.zip"] = true,
    ["html.zip"] = true,
}

--- DocumentRegistry 登记了、但不是书的后缀：图片（PicDocument / MuPDF）、表格演示、日志与通用容器。
local NOT_BOOK_EXT = {
    gif = true, jpg = true, jpeg = true, png = true, webp = true, svg = true, bmp = true,
    tif = true, tiff = true, hdp = true, wdp = true, jxr = true, j2k = true, jp2 = true,
    pam = true, pbm = true, pgm = true, pnm = true, ppm = true,
    xml = true, log = true, ["log.zip"] = true, tar = true, zip = true, cfb = true,
    xlsx = true, pptx = true,
}

--- 文件名后缀（小写）；fb2.zip 这类复合后缀整体返回，与 DocumentRegistry 的寻址一致。
---@param name string
---@return string|nil
local function bookSuffix(name)
    local lower = string.lower(name)
    local compound = lower:match("%.([%w]+%.zip)$")
    if compound then return compound end
    return lower:match("%.([^.]+)$")
end

--- KOReader 已登记的文档后缀表；拿不到（测试 / 未初始化）返回 nil，退回静态白名单。
---@return table<string, any>|nil
local function registeredSuffixes()
    local ok, Registry = pcall(require, "document/documentregistry")
    if ok and type(Registry) == "table" and type(Registry.filetype_provider) == "table"
        and next(Registry.filetype_provider) ~= nil then
        return Registry.filetype_provider
    end
    return nil
end

--- 判断文件是否为可打开的书籍。
---@param name string
---@return boolean
local function isBookFile(name)
    local ext = bookSuffix(name)
    if not ext or NOT_BOOK_EXT[ext] then
        return false
    end
    if BOOK_EXT[ext] then
        return true
    end
    -- 用 KOReader 自己的格式登记表判定（只按后缀查表，不走 hasProvider 的 sidecar 磁盘读取）。
    local registered = registeredSuffixes()
    return registered ~= nil and registered[ext] ~= nil
end

--- 书库根目录：去尾部空白与斜杠。
---@param cfg table|nil
---@return string
local function rootPath(cfg)
    local path = Text.rtrimSlashes(Text.rtrim(cfg and cfg.path))
    -- 没配置书库目录（且不是 WebDAV）时默认用 KOReader 的主目录（Kindle 的 /mnt/us/documents 等）。
    if path == "" and not (cfg and type(cfg.webdav_url) == "string" and cfg.webdav_url ~= "") then
        local home = G_reader_settings and G_reader_settings:readSetting("home_dir")
        home = type(home) == "string" and Text.rtrimSlashes(home) or ""
        if home ~= "" and lfs.attributes(home, "mode") == "directory" then
            path = home
        end
    end
    return path
end

--- WebDAV 模式下的本地书库目录（书按需下载到这里）；没配置或不可用时为 nil。
---@param self LocalClient
---@return string|nil
local function localRoot(self)
    local root = rootPath(self.cfg)
    return root ~= "" and lfs.attributes(root, "mode") == "directory" and root or nil
end

--- 确保文件所在目录存在。
---@param path string
local function ensureParent(path)
    Paths.ensureDir(path:match("(.+)/[^/]+$") or path)
end

--- 同步、推脏、关书推送会并发读写同一个远端文件，临时文件按次唯一，免得一方删掉另一方正在用的文件。
local temp_seq = 0
---@param temp string
---@return string
local function uniqueTemp(temp)
    temp_seq = temp_seq + 1
    return temp .. "." .. temp_seq
end

---@param rel string
---@return string
local function remoteStableId(rel)
    return "webdav://" .. rel
end

--- 远端相对路径来自 books.sync，会拼进本地路径读写删：绝对路径、反斜杠、空段、. / .. 段一律拒绝。
---@param rel string
---@return boolean
local function safeRel(rel)
    if rel:find("\\", 1, true) or rel:find("^/") or rel:find("/$") or rel:find("//", 1, true) then
        return false
    end
    for seg in rel:gmatch("[^/]+") do
        if seg == "." or seg == ".." then return false end
    end
    return true
end

---@param stable_id string
---@return string|nil
local function remoteRelativePath(stable_id)
    local rel = stable_id:match("^webdav://(.+)$")
    return rel and safeRel(rel) and rel or nil
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

--- 封面缓存路径（存在即封面可用，无需入库）。
---@param stable_id string
---@return string
local function coverPath(stable_id)
    return Paths.coverPath(stable_id, SOURCE_ID)
end

--- 封面缓存按 stable_id 寻址，跟着身份迁移；只是缓存，失败仅记日志。
---@param old_id string
---@param new_id string
local function moveCover(old_id, new_id)
    local old_cover = coverPath(old_id)
    if lfs.attributes(old_cover, "mode") == "file" then
        local ok, err = os.rename(old_cover, coverPath(new_id))
        if not ok then
            require("utils.log").warn("book local cover move failed", old_cover, err)
        end
    end
end

--- 纯本地书 stable_id 即路径：封面与 KOReader 的 .sdr（进度与高亮）一起迁，.sdr 搬不动要报给调用方。
---@param old_path string
---@param new_path string
---@return boolean ok, string|nil err
local function moveBookArtifacts(old_path, new_path)
    moveCover(old_path, new_path)
    local ok, err = require("book.sidecar").move(old_path, new_path)
    if not ok then require("utils.log").warn("book local sdr move failed", old_path, err) end
    return ok, err
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
    -- crengine 读不了时 loadDocument 仍返回 true，换成一份标题为 "ERROR: ..." 的错误文档，格式记为 Unknown format
    if doc.loadDocument and not doc:loadDocument(false)
        or doc.getDocumentFormat and doc:getDocumentFormat() == "Unknown format" then
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
---@return { title: string|nil, authors: string|nil, intro: string|nil, language: string|nil }|nil
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
    return {
        title = field(props.title),
        authors = field(props.authors),
        intro = field(Text.stripHtml(props.description)),
        language = field(props.language),
    }
end

--- 目录遍历（最多 3 层），产出按路径排序的书籍文件列表。
--- 根目录直属文件无分类无系列；一级子目录名 = 分类；二级子目录名 = 系列；更深忽略。
--- 同步阻塞，只在子进程里跑。
--- 任一目录列不出来就抛错：扫盘结果要按全量快照 reconcile，漏一个目录等于软删其中所有书。
--- fp = 文件指纹（大小:修改时间），没变就不重算内容 md5。
---@param root string
---@return { name: string, path: string, category: string|nil, series: string|nil, fp: string }[]
local function scanFiles(root)
    local files = {}
    --- 递归遍历一层目录，把书籍文件连同继承来的分类/系列收进 files。
    --- 跳过 . 前缀项与 .sdr 边车目录；分类 / 系列只取前两级目录名，更深的子目录照样下钻（至多 MAX_DEPTH 层）。
    --- 按 realpath 去重，软链接成环或指回已扫目录时不重复进入。
    local visited = {}
    local ok_util, ffiUtil = pcall(require, "ffi/util")
    local function realKey(path)
        local real = ok_util and type(ffiUtil.realpath) == "function" and ffiUtil.realpath(path)
        return type(real) == "string" and real or path
    end
    ---@param dir string 当前目录绝对路径
    ---@param category string|nil 继承的分类（一级子目录名）
    ---@param series string|nil 继承的系列（二级子目录名）
    ---@param depth number 当前层级，根为 1
    local function walk(dir, category, series, depth)
        local key = realKey(dir)
        if visited[key] then return end
        visited[key] = true
        for name in lfs.dir(dir) do
            -- 跳过 . .. 及一切 . 前缀项（.moon 等隐藏目录/文件）
            if name:sub(1, 1) ~= "." then
                local path = dir .. "/" .. name
                local attr = lfs.attributes(path)
                if attr then
                    if attr.mode == "directory" then
                        -- KOReader 的 .sdr 边车目录不是书籍分类，不下钻
                        if name:sub(-4) ~= ".sdr" and depth < MAX_DEPTH then
                            -- 根下的一级目录名是分类，分类下的二级目录名是系列，再深沿用
                            if depth == 1 then
                                walk(path, name, nil, depth + 1)
                            elseif depth == 2 then
                                walk(path, category, name, depth + 1)
                            else
                                walk(path, category, series, depth + 1)
                            end
                        end
                    elseif attr.mode == "file" and isBookFile(name) then
                        files[#files + 1] = {
                            name = name,
                            path = path,
                            category = category,
                            series = series,
                            fp = attr.size .. ":" .. attr.modification,
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

--- 下载远端小文件并读出内容；远端不存在时 cb(nil, nil, true)。
---@param self LocalClient
---@param remote string
---@param temp string 临时文件前缀（按次唯一化）
---@param cb fun(raw: string|nil, err: string|nil, missing: boolean|nil)
---@return { cancel: fun() }
local function fetchText(self, remote, temp, cb)
    temp = uniqueTemp(temp)
    ensureParent(temp)
    return self.dav:getAsync(remote, temp, nil, function(ok, err, code)
        local raw = ok and readFile(temp)
        os.remove(temp)
        if raw then return cb(raw) end
        cb(nil, err or _("读取失败"), code == 404)
    end)
end

--- 上传一段内容到远端（先建父目录）。
---@param self LocalClient
---@param remote string
---@param temp string 临时文件前缀（按次唯一化）
---@param data string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
local function putText(self, remote, temp, data, cb)
    temp = uniqueTemp(temp)
    if not writeFile(temp, data) then return defer(cb, nil, _("无法写入临时文件")) end
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

return {
    SOURCE_ID = SOURCE_ID,
    defer = defer,
    isBookFile = isBookFile,
    rootPath = rootPath,
    localRoot = localRoot,
    ensureParent = ensureParent,
    uniqueTemp = uniqueTemp,
    remoteStableId = remoteStableId,
    safeRel = safeRel,
    remoteRelativePath = remoteRelativePath,
    sidecarKey = sidecarKey,
    stem = stem,
    readFile = readFile,
    writeFile = writeFile,
    field = field,
    encodeProgress = encodeProgress,
    decodeProgress = decodeProgress,
    eachAsync = eachAsync,
    coverPath = coverPath,
    moveBookArtifacts = moveBookArtifacts,
    ensureCover = ensureCover,
    parseBookProps = parseBookProps,
    scanFiles = scanFiles,
    moonPath = moonPath,
    coverRemotePath = coverRemotePath,
    progressRemotePath = progressRemotePath,
    notesRemotePath = notesRemotePath,
    fetchText = fetchText,
    putText = putText,
}
