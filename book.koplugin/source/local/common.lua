







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




local function isBookFile(name)
    return bookExt(name) ~= nil
end

local MOBI_EXT = { mobi = true, azw = true, azw3 = true }





local function isDrmMobi(name, path)
    local ext = name:match("%.([^.]+)$")
    return ext ~= nil and MOBI_EXT[ext:lower()] == true and require("utils.mobi").encrypted(path)
end




local function rootPath(cfg)
    return Text.rtrimSlashes(Text.rtrim(cfg and cfg.path))
end




local function localRoot(self)
    local root = rootPath(self.cfg)
    return root ~= "" and lfs.attributes(root, "mode") == "directory" and root or nil
end



local function ensureParent(path)
    Paths.ensureDir(path:match("(.+)/[^/]+$") or path)
end


local temp_seq = 0


local function uniqueTemp(temp)
    temp_seq = temp_seq + 1
    return temp .. "." .. temp_seq
end



local function remoteStableId(rel)
    return "webdav://" .. rel
end




local function safeRel(rel)
    if rel:find("\\", 1, true) or rel:find("^/") or rel:find("/$") or rel:find("//", 1, true) then
        return false
    end
    for seg in rel:gmatch("[^/]+") do
        if seg == "." or seg == ".." then return false end
    end
    return true
end



local function remoteRelativePath(stable_id)
    local rel = stable_id:match("^webdav://(.+)$")
    return rel and safeRel(rel) and rel or nil
end







local function relFor(self, stable_id)
    local rel = type(stable_id) == "string" and remoteRelativePath(stable_id)
    if rel then return rel end
    if type(stable_id) ~= "string" then return nil end
    local root = localRoot(self)
    if not root then return nil end
    local prefix = root .. "/"
    if stable_id:sub(1, #prefix) ~= prefix then return nil end
    local rest = stable_id:sub(#prefix + 1)
    return safeRel(rest) and rest or nil
end




local function sidecarKey(rel)
    return rel:match("([^/]+)$")
end



local function stem(rel)
    return (sidecarKey(rel):gsub("%.[^.]+$", ""))
end

local readFile = require("utils.fs").read




local function writeFile(path, data)
    ensureParent(path)
    local file = io.open(path, "wb")
    local written = file and file:write(data)
    local closed = file and file:close()
    if written and closed then return true end
    os.remove(path)
    return false
end



local function field(v)
    v = type(v) == "string" and Text.trim(v) or ""
    return v ~= "" and v or nil
end


local function encodeProgress(pos)
    local ts = tonumber(pos.updated_at) or os.time()
    return string.format("%d*%d@0#0:%.1f%%", ts * 1000,
        tonumber(pos.chapter_idx) or 0, (tonumber(pos.fraction) or 0) * 100)
end


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




local function coverPath(stable_id)
    return Paths.coverPath(stable_id, SOURCE_ID)
end




local function moveCover(old_id, new_id)
    local old_cover = coverPath(old_id)
    if lfs.attributes(old_cover, "mode") == "file" then
        local ok, err = os.rename(old_cover, coverPath(new_id))
        if not ok then
            require("utils.log").warn("book local cover move failed", old_cover, err)
        end
    end
end





local function moveBookArtifacts(old_path, new_path)
    moveCover(old_path, new_path)
    local ok, err = require("book.sidecar").move(old_path, new_path)
    if not ok then require("utils.log").warn("book local sdr move failed", old_path, err) end
    return ok, err
end





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



local function ensureCover(path)
    local ok, err = pcall(withDocument, path, function(doc)
        saveDocumentCover(doc, path)
    end)
    if not ok then
        require("utils.log").warn("book local cover extraction failed", path, err)
    end
end





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












local function scanFiles(root, flat)
    local files, skipped = {}, {}






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





local function moonPath(self, name)
    return self:webdavPath() .. "/.Moon+/" .. name
end



local function coverRemotePath(self, rel)
    return moonPath(self, "Cover/" .. sidecarKey(rel) .. "_2.png")
end



local function progressRemotePath(self, rel)
    return moonPath(self, "Cache/" .. sidecarKey(rel) .. ".po")
end




local function notesRemotePath(self, rel)
    return moonPath(self, "Notes/" .. sidecarKey(rel) .. ".json")
end







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
    relFor = relFor,
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
