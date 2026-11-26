--[[--
本地源客户端的共享原语：路径与边车寻址、文件读写、远端小文件读写、串行异步遍历、Moon+ 进度编解码，
以及扫盘和 WebDAV 都要用的磁盘 / 文档操作（目录遍历、元数据与封面解析、附属资源迁移）。
零 UI 依赖。

@module koplugin.book.source.local.common
--]]

local lfs = require("libs/libkoreader-lfs")
local Text = require("utils.text")
local Paths = require("utils.paths")
local _ = require("l10n").get("source.local")
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

--- 从文件名、路径或 stable_id 取出已识别的书籍后缀（小写）。
--- `fb2.zip` 是一种格式，不会当成 zip；无法识别则返回 nil。
---@param name string|nil
---@return string|nil
local function bookExt(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    local base = name:match("[^/]+$") or name
    local ext = base:lower():match("%.(fb2%.zip)$") or base:match("%.([^.]+)$")
    if not ext then
        return nil
    end
    ext = string.lower(ext)
    return BOOK_EXT[ext] and ext or nil
end

--- 判断文件是否为可打开的书籍。
---@param name string
---@return boolean
local function isBookFile(name)
    return bookExt(name) ~= nil
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

local Fs = require("utils.fs")
local readFile = Fs.read

---@param path string
---@param data string
---@return boolean
local function writeFile(path, data)
    ensureParent(path)
    return Fs.write(path, data) == true
end

---@param v any
---@return string|nil
local function field(v)
    v = type(v) == "string" and Text.trim(v) or ""
    return v ~= "" and v or nil
end

--- 一位小数的百分比只给静读天下显示。它跳转看的是 `#` 后面的章内字符数；写成 0 会把书拉回章首。
--- 没有真实偏移时省略 `@分卷#偏移`。固定版式没有字符偏移，页码放在章号那个位置，和百分比一起写。
local PAGED_EXT = { pdf = true, djvu = true, cbz = true, cbt = true, xps = true }

local function encodeProgress(pos)
    local ts = tonumber(pos.updated_at) or os.time()
    local pct = (tonumber(pos.fraction) or 0) * 100
    local chapter = tonumber(pos.chapter_idx) or 0
    local extra = type(pos.extra) == "table" and pos.extra or nil
    local offset = extra and tonumber(extra.offset)
    local anchored = extra and tonumber(extra.at_fraction)
    if offset and offset >= 0 and anchored and math.abs((tonumber(pos.fraction) or 0) - anchored) > 0.001 then
        offset = nil
    end
    local volume = extra and tonumber(extra.volume) or 0
    if not offset and chapter == 0 then
        local page = tonumber(pos.page)
        if page and page >= 1 then
            chapter = math.floor(page)
            offset = 0
            volume = 0
        end
    end
    if not offset then
        return string.format("%d*%d:%.1f%%", ts * 1000, chapter, pct)
    end
    return string.format("%d*%d@%d#%d:%.1f%%", ts * 1000, chapter, volume, math.floor(offset), pct)
end

--- 兼容旧版写出的 `{秒}*...` 花括号格式与省略 `@分卷#偏移` 的短格式；时间戳统一换算成秒。
--- 完整格式把字符偏移放进 extra，关书时同一章会原样保留（见阅读进度保存）。
local function decodeProgress(raw)
    if type(raw) ~= "string" then return nil end
    local ts, chapter, volume, offset, pct = raw:match(
        "^%s*{?%s*(%d+)%s*}?%s*%*%s*(%-?%d+)%s*@%s*(%-?%d+)%s*#%s*(%-?%d+)%s*:%s*([%d%.]+)%s*%%")
    if not ts then
        ts, chapter, pct = raw:match("^%s*{?%s*(%d+)%s*}?%s*%*%s*(%-?%d+)%s*:%s*([%d%.]+)%s*%%")
    end
    if not ts then return nil end
    ts = tonumber(ts)
    if ts > 1e12 then ts = math.floor(ts / 1000) end
    local fraction = math.min(100, tonumber(pct) or 0) / 100
    local pos = { updated_at = ts, chapter_idx = tonumber(chapter), fraction = fraction }
    if offset then
        pos.extra = {
            chapter_idx = pos.chapter_idx,
            volume = tonumber(volume) or 0,
            offset = tonumber(offset) or 0,
            at_fraction = fraction,
        }
    end
    return pos
end

--- 关书时把当前章内字符数写进 extra。静读天下认这个数，不认百分比。
---@param pos ProgressPosition
---@param ui table|nil
---@return ProgressPosition
local function captureProgress(pos, ui)
    local doc = ui and ui.document
    local rolling = ui and ui.rolling
    local xp = rolling and rolling.xpointer
    if not doc or type(xp) ~= "string" or xp == "" then return pos end
    if type(doc.getToc) ~= "function" or type(doc.getTextFromXPointers) ~= "function" then return pos end
    local ok_toc, toc = pcall(doc.getToc, doc)
    local idx = tonumber(pos.chapter_idx)
    local item = ok_toc and idx and toc and toc[idx]
    local start_xp = item and item.xpointer
    if type(start_xp) ~= "string" or start_xp == "" then return pos end
    local ok_text, text = pcall(doc.getTextFromXPointers, doc, start_xp, xp)
    if not ok_text or type(text) ~= "string" then return pos end
    local extra = type(pos.extra) == "table" and pos.extra or {}
    extra.chapter_idx = idx
    extra.volume = tonumber(extra.volume) or 0
    extra.offset = Text.len(text)
    extra.at_fraction = tonumber(pos.fraction) or 0
    pos.extra = extra
    return pos
end

local function copyPos(pos)
    local out = {}
    for key, value in pairs(pos) do out[key] = value end
    return out
end

--- 固定版式：静读天下把页码放在 `*` 后面。页码落在这本书的页数里就用页码，否则留下百分比。
local function refinePaged(pos, doc)
    local ext = bookExt(pos.stable_id or "")
    if not ext or not PAGED_EXT[ext] or type(doc.getPageCount) ~= "function" then return pos end
    local ok, total = pcall(doc.getPageCount, doc)
    total = ok and tonumber(total) or nil
    if not total or total < 1 then return pos end
    local page = tonumber(pos.page)
    if page and tonumber(pos.total_pages) == total and page >= 1 and page <= total then return pos end
    local moon_page = tonumber(pos.chapter_idx)
    if not moon_page or moon_page < 1 or moon_page > total then return pos end
    local refined = copyPos(pos)
    refined.page = math.floor(moon_page)
    refined.total_pages = total
    return refined
end

--- 流式书：静读天下的位置是章号 + 章内字符数。百分比是显示值，不参与落点。
--- 字符数超出本章能数到的文本时停在章末。这一章的文本数不到，才把原位置交回上层。
local function refineFlow(pos, doc)
    local extra = type(pos.extra) == "table" and pos.extra or nil
    local offset = extra and tonumber(extra.offset)
    if not offset or offset < 0 then return pos end
    if type(doc.getToc) ~= "function" or type(doc.getPageCount) ~= "function"
        or type(doc.getPageXPointer) ~= "function" or type(doc.getTextFromXPointers) ~= "function" then
        return pos
    end
    local ok_toc, toc = pcall(doc.getToc, doc)
    local idx = tonumber(pos.chapter_idx)
    local item = ok_toc and idx and toc and toc[idx]
    local start_xp = item and item.xpointer
    local start_page = item and tonumber(item.page)
    if type(start_xp) ~= "string" or not start_page then return pos end
    local ok_total, total = pcall(doc.getPageCount, doc)
    total = ok_total and tonumber(total) or nil
    if not total or total < 1 then return pos end
    local next_item = toc[idx + 1]
    local end_page = next_item and tonumber(next_item.page) or (total + 1)
    local function charsUntil(page)
        local ok_xp, xp = pcall(doc.getPageXPointer, doc, page)
        if not ok_xp or type(xp) ~= "string" then return nil end
        local ok_text, text = pcall(doc.getTextFromXPointers, doc, start_xp, xp)
        if not ok_text or type(text) ~= "string" then return nil end
        return Text.len(text)
    end
    local last = math.max(start_page, end_page - 1)
    local end_count = charsUntil(last)
    if not end_count then return pos end
    local found = last
    if offset <= end_count then
        local lo, hi = start_page, last
        found = start_page
        while lo <= hi do
            local mid = math.floor((lo + hi) / 2)
            local count = charsUntil(mid)
            if not count then return pos end
            if count <= offset then
                found = mid
                lo = mid + 1
            else
                hi = mid - 1
            end
        end
    end
    local ok_xp, xp = pcall(doc.getPageXPointer, doc, found)
    if not ok_xp or type(xp) ~= "string" or xp == "" then return pos end
    local refined = copyPos(pos)
    refined.locator = xp
    return refined
end

--- 开书落地前选更精确的坐标。已有 XPointer 就用它。
---@param pos ProgressPosition
---@param ui table|nil
---@return ProgressPosition
local function refinePosition(pos, ui)
    if type(pos) ~= "table" or (type(pos.locator) == "string" and pos.locator ~= "") then return pos end
    local doc = ui and ui.document
    if not doc then return pos end
    if ui.rolling then return refineFlow(pos, doc) end
    return refinePaged(pos, doc)
end


--- 有限并发异步遍历：step(item, next, index) 处理完一项调 next()，全部处理完调 done()。
--- 最多 limit 路同时 step（缺省 1 即串行）；step 同步回调 next 时在循环里排空，不递归、不涨栈。
---@param list any[]
---@param step fun(item: any, next: fun(), index: integer)
---@param done fun()
---@param limit integer|nil
local function eachAsync(list, step, done, limit)
    limit = limit or 1
    local next_i, live, finished, pumping = 1, 0, false, false
    local function pump()
        if finished or pumping then return end
        pumping = true
        while live < limit and next_i <= #list do
            local i = next_i
            next_i = next_i + 1
            live = live + 1
            step(list[i], function()
                live = live - 1
                pump()
            end, i)
        end
        pumping = false
        if next_i > #list and live == 0 then
            finished = true
            done()
        end
    end
    pump()
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

--- 远端 .Moon+ 下的路径。静读天下边车走这里。别的布局在 source.local.layout。
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
    -- 书目 / 进度 / 笔记 / 统计都是小文件。下载档超时（默认 300 秒）会让一次卡住的请求占满界面。
    return self.dav:getAsync(remote, temp, { timeout = require("http.timeout").net(1) }, function(ok, err, code)
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
    local directory_job = self.dav:ensurePathAsync(remote:match("(.+)/[^/]+$"), function(ok_dir, dir_err)
        if cancelled then return end
        if not ok_dir then os.remove(temp); return cb(nil, dir_err) end
        active = self.dav:putFileAsync(remote, temp, function(ok, err)
            os.remove(temp)
            if not cancelled then cb(ok, err) end
        end, require("http.timeout").net(1))
    end)
    active = active or directory_job
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
    bookExt = bookExt,
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
    captureProgress = captureProgress,
    refinePosition = refinePosition,
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
