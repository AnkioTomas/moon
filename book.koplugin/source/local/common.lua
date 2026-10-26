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
    prc = true,
    htm = true,
    xhtml = true,
    doc = true,
    odt = true,
    ["fb2.zip"] = true,
}

--- 判断文件是否为可打开的书籍。
---@param name string
---@return boolean
local function isBookFile(name)
    local ext = name:lower():match("%.(fb2%.zip)$") or name:match("%.([^.]+)$")
    if not ext then
        return false
    end
    return BOOK_EXT[string.lower(ext)] == true
end

local MOBI_EXT = { mobi = true, azw = true, azw3 = true }

--- 带 DRM 的 mobi / azw / azw3：KOReader 打不开，扫盘跳过。
---@param name string
---@param path string
---@return boolean
local function isDrmMobi(name, path)
    local ext = name:match("%.([^.]+)$")
    return ext ~= nil and MOBI_EXT[ext:lower()] == true and require("utils.mobi").encrypted(path)
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
---@param done fun(err: any)
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
--- 用户在 KOReader 里给书设过自定义封面（sidecar 里的 cover.*）时优先用它，和文件管理器显示的一致。
---@param doc table
---@param path string 封面缓存键（stable_id，本地书即文件路径）
local function saveDocumentCover(doc, path)
    local ok, custom = pcall(function() return require("docsettings"):findCustomCoverFile(path) end)
    local cover_doc = ok and custom and require("document/documentregistry"):openDocument(custom)
    if cover_doc then
        local saved_ok, saved = pcall(require("book.cover").save, cover_doc, coverPath(path))
        pcall(function() cover_doc:close() end)
        if saved_ok and saved then return end
    end
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
    -- crengine 读不了时 loadDocument 仍返回 true，换成一份标题为 "ERROR: ..." 的错误文档，格式记为 Unknown format。
    -- 只在引擎真加载过（_loaded）时看格式：AZW3 提供者只探文件头（EXTH 元数据 + 封面）时引擎没载文档，格式恒为 Unknown format
    if doc.loadDocument and not doc:loadDocument(false)
        or doc._loaded and doc.getDocumentFormat and doc:getDocumentFormat() == "Unknown format" then
        -- crengine 加载失败后调其它方法会 segfault，必须直接 close
        pcall(function() doc:close() end)
        return nil
    end
    -- fn 抛错也要关文档：crengine 文档不关会一直占着内存。
    local ok, result = pcall(fn, doc)
    pcall(function() doc:close() end)
    if not ok then error(result, 0) end
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
--- 根目录列不出来就抛错；子目录列不出来（无权限）记一行日志跳过，收进 skipped：
--- 调用方按全量快照 reconcile 时要把 skipped 下已入库的书当“未知”保留，不能软删。
--- fp = 文件指纹（大小:修改时间），没变就不重算内容 md5。
--- flat=true（关闭「按文件夹分类」）：不看目录结构、不派生分类 / 系列（库里的手动编辑保留），不限层数下钻；
--- 软链接目录跳过，免得成环。
---@param root string
---@param flat boolean|nil
---@return { name: string, path: string, category: string|nil, series: string|nil, fp: string }[], string[] skipped
local function scanFiles(root, flat)
    local files, skipped = {}, {}
    --- 递归遍历一层目录，把书籍文件连同继承来的分类/系列收进 files。
    --- 跳过 . 前缀项与 .sdr 边车目录；depth 超过 2 不再下钻（flat 时不限）。
    ---@param dir string 当前目录绝对路径
    ---@param category string|nil 继承的分类（一级子目录名）
    ---@param series string|nil 继承的系列（二级子目录名）
    ---@param depth number 当前层级，根为 1
    local function walk(dir, category, series, depth)
        local ok, iter, state = pcall(lfs.dir, dir)
        if not ok then
            if depth == 1 then error(iter, 0) end
            require("utils.log").warn("book local scan skip unreadable dir", dir, iter)
            skipped[#skipped + 1] = dir
            return
        end
        for name in iter, state do
            -- 跳过 . .. 及一切 . 前缀项（.moon 等隐藏目录/文件）
            if name:sub(1, 1) ~= "." then
                local path = dir .. "/" .. name
                local attr = lfs.attributes(path)
                if attr then
                    if attr.mode == "directory" then
                        -- KOReader 的 .sdr 边车目录不是书籍分类，不下钻；软链接目录也不跟（可能指回上级，扫出根外）
                        if name:sub(-4) ~= ".sdr" and lfs.symlinkattributes(path, "mode") ~= "link" then
                            -- 下钻：根下的一级目录名是分类，分类下的二级目录名是系列
                            if flat then
                                walk(path, category, series, depth + 1)
                            elseif depth == 1 then
                                walk(path, name, nil, depth + 1)
                            elseif depth == 2 then
                                walk(path, category, name, depth + 1)
                            end
                        end
                    elseif attr.mode == "file" and isBookFile(name) and not isDrmMobi(name, path) then
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
    return files, skipped
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
    isDrmMobi = isDrmMobi,
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
