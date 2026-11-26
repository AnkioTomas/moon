--[[--
每本书的自定义设置，一书一份。

字体、边距、样式、自定义 CSS、划线样式、自定义封面和 custom_metadata 走这里。
进度、划线、书签和本机路径不走：那些有自己的同步，整份 .sdr 盖过去会把另一台的进度写进来。
按章阅读的全书排版在 books.reader_prefs，跟 sidecar 放在同一份里。

远端是 `.moon-koreader/sdr/<源>/<文件名>.json`，封面是旁边的 `<文件名>.cover.<ext>`。
内容没变就不传。两边都改过时，后改的文件赢；只翻页不会让 sidecar 变新就算改了设置。
这本书还没下载到本机时，只收下全书排版，不拿空设置去盖远端。

@module koplugin.book.moon_sync.sdr
--]]

local bit = require("bit")

local Sdr = {}

local SEEN = "moon_sync_sdr"

--- 阅读进度和笔记。sidecar 清阅读数据时删的就是这些，再加本机路径和文件校验。
local DENY = {
    last_xpointer = true, last_page = true, percent_finished = true, summary = true, stats = true,
    annotations = true, annotations_rolling = true, annotations_paging = true,
    annotations_externally_modified = true,
    highlight = true, highlight_rolling = true, highlight_paging = true,
    bookmarks = true, bookmarks_rolling = true, bookmarks_paging = true,
    book_note_linked = true, book_note_orphans = true, book_last_derived = true,
    doc_path = true, partial_md5_checksum = true,
}

---@param value any
---@return string
local function stable(value)
    if type(value) ~= "table" then return type(value) .. ":" .. tostring(value) end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b)
        local ta, tb = type(a), type(b)
        if ta ~= tb then return ta < tb end
        return a < b
    end)
    local parts = {}
    for i, key in ipairs(keys) do
        parts[i] = stable(key) .. "=" .. stable(value[key])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

---@param text string
---@return string
local function fnv(text)
    local hash = 2166136261
    for i = 1, #text do
        hash = bit.bxor(hash, text:byte(i))
        hash = bit.band(hash * 16777619, 0xffffffff)
    end
    return string.format("%08x", hash)
end

---@param ext string|nil
---@return boolean
function Sdr.coverExtOk(ext)
    return ext == "jpg" or ext == "png" or ext == "webp" or ext == "gif"
end

---@param path string
---@return string|nil
local function coverExtOf(path)
    local ext = path:match("%.([^.]+)$")
    if not ext then return nil end
    ext = ext:lower()
    if ext == "jpeg" then ext = "jpg" end
    if not Sdr.coverExtOk(ext) then return nil end
    return ext
end

--- 去掉进度、划线和本机路径，剩下的是用户改过的设置。
---@param data table|nil
---@return table
function Sdr.exportSettings(data)
    local out = {}
    if type(data) ~= "table" then return out end
    for key, value in pairs(data) do
        if type(key) == "string" and not DENY[key] then out[key] = value end
    end
    return out
end

--- 用远端设置覆盖本地的自定义项。进度、划线和 doc_path 保持不动。远端没有的自定义项删掉。
---@param data table
---@param settings table|nil
function Sdr.applySettings(data, settings)
    if type(data) ~= "table" then return end
    local incoming = type(settings) == "table" and settings or {}
    local keep = {}
    for key, value in pairs(incoming) do
        if type(key) == "string" and not DENY[key] then
            data[key] = value
            keep[key] = true
        end
    end
    local drop = {}
    for key in pairs(data) do
        if type(key) == "string" and not DENY[key] and not keep[key] then
            drop[#drop + 1] = key
        end
    end
    for _i, key in ipairs(drop) do data[key] = nil end
end

--- 有没有值得上传的自定义内容。只有进度的 sidecar 不算。
---@param doc table|nil
---@return boolean
function Sdr.hasContent(doc)
    if type(doc) ~= "table" then return false end
    if type(doc.reader_prefs) == "string" and doc.reader_prefs ~= "" then return true end
    if type(doc.cover_ext) == "string" and doc.cover_ext ~= "" then return true end
    if type(doc.settings) == "table" and next(doc.settings) ~= nil then return true end
    if type(doc.custom_metadata) == "table" and next(doc.custom_metadata) ~= nil then return true end
    return false
end

---@param doc table
---@return string
function Sdr.fingerprint(doc)
    return fnv(stable({
        settings = doc.settings or {},
        reader_prefs = doc.reader_prefs or "",
        custom_metadata = doc.custom_metadata or {},
        cover_ext = doc.cover_ext or "",
        cover_hash = doc.cover_hash or "",
    }))
end

--- 本机文件还没下载时只收全书排版。第一次见到空设置时不拿它去盖远端。
--- 清掉上次同步过的设置会上传。分叉时不拉。
---@param spec { seen: table|nil, remote_mtime: number|nil, hash: string, file_mtime: number|nil, can_write: boolean, has_content: boolean, trusted: boolean|nil }
---@return "push"|"pull"|"prefs"|"skip"
function Sdr.action(spec)
    local seen = spec.seen
    local remote_mtime = spec.remote_mtime
    local hash_changed = not seen or seen.hash ~= spec.hash
    local remote_changed = remote_mtime ~= nil and (not seen or seen.mtime ~= remote_mtime)
    if spec.trusted == false then
        -- 上次只收下了排版，这本书的设置还不在本机，分叉时别拿残缺的一份去盖远端。
        if seen and seen.prefs_only then return "skip" end
        if spec.can_write and (spec.has_content or seen) then return "push" end
        return "skip"
    end
    if spec.can_write and seen and seen.prefs_only and remote_mtime ~= nil then return "pull" end
    if not spec.can_write then
        if remote_mtime == nil then return "skip" end
        if hash_changed or remote_changed then return "prefs" end
        return "skip"
    end
    if remote_mtime == nil then
        if spec.has_content or (seen and hash_changed) then return "push" end
        return "skip"
    end
    if hash_changed and remote_changed then
        local local_newer = (spec.file_mtime or 0) >= remote_mtime
        if local_newer and (spec.has_content or seen) then return "push" end
        return "pull"
    end
    if remote_changed then return "pull" end
    if hash_changed and (spec.has_content or seen) then return "push" end
    return "skip"
end

---@param rows { source_id: string, stable_id: string, path: string|nil, reader_prefs: string|nil }[]|nil
---@return table<string, table<string, table>>
function Sdr.bySource(rows)
    local Reading = require("moon_sync.reading")
    local out = {}
    for _i, row in ipairs(rows or {}) do
        local source_id = row.source_id
        if type(source_id) == "string" and source_id:match("^[%w_%-]+$") and type(row.stable_id) == "string" then
            local name = Reading.fileName(row.stable_id)
            if name then
                local bucket = out[source_id]
                if not bucket then
                    bucket = {}
                    out[source_id] = bucket
                end
                bucket[name] = row
            end
        end
    end
    return out
end

---@return table
function Sdr.loadSeen()
    local raw = require("utils.fs").read(require("utils.paths").cacheDir() .. "/" .. SEEN)
    if type(raw) ~= "string" or raw == "" then return {} end
    local ok, doc = pcall(require("json").decode, raw)
    if not ok or type(doc) ~= "table" then return {} end
    return doc
end

---@param seen table
function Sdr.saveSeen(seen)
    local Paths = require("utils.paths")
    if not Paths.ensureDir(Paths.cacheDir()) then return end
    local file = io.open(Paths.cacheDir() .. "/" .. SEEN, "wb")
    if not file then return end
    file:write(require("json").encode(seen))
    file:close()
end

---@param path string
---@return string
local function hashFile(path)
    local data = require("utils.fs").read(path)
    if type(data) ~= "string" then return "" end
    return fnv(data)
end

--- 读出这本书要同步的设置。sidecar 读不出来时返回 nil，调用方跳过，不要当成空设置上传。
---@param row { path: string|nil, reader_prefs: string|nil }
---@return table|nil doc
---@return number|nil file_mtime
---@return string|nil cover_path
---@return boolean|nil can_write
function Sdr.snapshot(row)
    local doc = {
        settings = {},
        reader_prefs = type(row.reader_prefs) == "string" and row.reader_prefs or "",
        custom_metadata = {},
        cover_ext = "",
        cover_hash = "",
    }
    local file_mtime = 0
    local cover_path = nil
    local path = row.path
    if type(path) ~= "string" or path == "" then return doc, file_mtime, nil, false end
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") ~= "file" then return doc, file_mtime, nil, false end
    local DocSettings = require("docsettings")
    local sidecar = DocSettings:findSidecarFile(path)
    if sidecar then
        local read_ok, stored = pcall(dofile, sidecar)
        if not read_ok or type(stored) ~= "table" then return nil end
        doc.settings = Sdr.exportSettings(stored)
        file_mtime = math.max(file_mtime, tonumber(lfs.attributes(sidecar, "modification")) or 0)
    end
    local custom = DocSettings:findCustomMetadataFile(path)
    if custom then
        local read_ok, stored = pcall(dofile, custom)
        if not read_ok or type(stored) ~= "table" then return nil end
        doc.custom_metadata = Sdr.exportSettings(stored)
        file_mtime = math.max(file_mtime, tonumber(lfs.attributes(custom, "modification")) or 0)
    end
    local cover = DocSettings:findCustomCoverFile(path)
    local ext = cover and coverExtOf(cover)
    if cover and ext then
        doc.cover_ext = ext
        doc.cover_hash = hashFile(cover)
        cover_path = cover
        file_mtime = math.max(file_mtime, tonumber(lfs.attributes(cover, "modification")) or 0)
    end
    return doc, file_mtime, cover_path, true
end

--- 写回 sidecar 和全书排版。书还没下载就只写排版。
---@param row { source_id: string, stable_id: string, path: string|nil }
---@param doc table
function Sdr.applyDoc(row, doc)
    if type(doc) ~= "table" then return end
    if type(doc.reader_prefs) == "string" and doc.reader_prefs ~= "" then
        require("book.books_db").setReaderPrefs(row.source_id, row.stable_id, doc.reader_prefs)
    end
    local path = row.path
    if type(path) ~= "string" or path == "" then return end
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") ~= "file" then return end
    local DocSettings = require("docsettings")
    local settings = DocSettings:open(path)
    Sdr.applySettings(settings.data, doc.settings)
    settings:flush(nil, true)
    local meta = type(doc.custom_metadata) == "table" and doc.custom_metadata or {}
    local existing = DocSettings:findCustomMetadataFile(path)
    if next(Sdr.exportSettings(meta)) then
        local holder = DocSettings.openSettingsFile(existing)
        holder.data = Sdr.exportSettings(meta)
        holder:flushCustomMetadata(path)
    elseif existing then
        os.remove(existing)
    end
end

---@param path string|nil
---@param image_file string
---@return boolean|nil
function Sdr.applyCover(path, image_file)
    if type(path) ~= "string" or path == "" then return nil end
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") ~= "file" then return nil end
    local settings = require("docsettings"):open(path)
    return settings:flushCustomCover(path, image_file)
end

---@param path string|nil
function Sdr.removeCover(path)
    if type(path) ~= "string" or path == "" then return end
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") ~= "file" then return end
    local cover = require("docsettings"):findCustomCoverFile(path)
    if cover then os.remove(cover) end
end

return Sdr
