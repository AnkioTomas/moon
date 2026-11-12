--[[--
把一章的页图打成 CBZ（zip，store 模式）。漫画源共用，打包成功后删掉散页图。
打包时经 source.cbz_fit 按屏宽缩小并把过高的图切成独立页。已缓存的过大 CBZ
在打开前也会按同样规则重打包，避免阅读器一次性解码整条长图。

重切后页数可能变多：若边车有 last_page，按旧页数比例映射到新页；高亮/书签的绝对页码无法可靠对齐。

@module koplugin.book.source.cbz
--]]

local Fit = require("source.cbz_fit")
local Image = require("utils.image")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

local Cbz = {}

Cbz.Fit = Fit

--- 文件存在且非空。
---@param path string
---@return boolean
function Cbz.ready(path)
    local attr = lfs.attributes(path)
    return attr ~= nil and attr.mode == "file" and (tonumber(attr.size) or 0) > 0
end

--- 路径是否为漫画压缩包。
---@param path string|nil
---@return boolean
function Cbz.isArchive(path)
    if type(path) ~= "string" then return false end
    return path:lower():find("%.cbz$") ~= nil or path:lower():find("%.cbt$") ~= nil
end

---@param name string
---@return boolean
local function isImageEntry(name)
    if type(name) ~= "string" or name == "" then return false end
    local base = name:match("([^/\\]+)$") or name
    if base:sub(1, 1) == "." then return false end
    return Image.suffix(base) ~= nil
end

--- 按文件名列出压缩包里的页图（与阅读器按名排序一致）。
---@param archive_path string
---@return { path: string, size: integer }[]|nil entries
---@return string|nil err
function Cbz.listImages(archive_path)
    local ok, Reader = pcall(function()
        return require("ffi/archiver").Reader
    end)
    if not ok or not Reader then return nil, _("无法读取漫画图片") end
    local reader = Reader:new()
    if not reader:open(archive_path) then
        return nil, reader.err or _("无法读取漫画图片")
    end
    ---@type { path: string, size: integer }[]
    local entries = {}
    for entry in reader:iterate() do
        if entry and entry.mode == "file" and isImageEntry(entry.path) then
            entries[#entries + 1] = { path = entry.path, size = tonumber(entry.size) or 0 }
        end
    end
    reader:close()
    table.sort(entries, function(a, b) return a.path < b.path end)
    return entries
end

--- 检查已有 CBZ 是否含有超过当前屏幕安全尺寸的页。
---@param archive_path string
---@param screen_w integer|nil
---@param screen_h integer|nil
---@return boolean needed
---@return integer page_count
function Cbz.needsFit(archive_path, screen_w, screen_h)
    screen_w, screen_h = screen_w or select(1, Fit.screen()), screen_h or select(2, Fit.screen())
    local entries = Cbz.listImages(archive_path)
    if not entries or #entries == 0 then return false, entries and #entries or 0 end
    local ok, Reader = pcall(function()
        return require("ffi/archiver").Reader
    end)
    if not ok or not Reader then return false, #entries end
    local reader = Reader:new()
    if not reader:open(archive_path) then return false, #entries end
    local needed = false
    for _idx, entry in ipairs(entries) do
        local data = reader:extractToMemory(entry.path)
        if data then
            local w, h = Fit.dimensions(nil, data)
            data = nil
            if w and h and Fit.needed(w, h, screen_w, screen_h) then
                needed = true
                break
            end
        end
    end
    reader:close()
    collectgarbage("collect")
    return needed, #entries
end

---@param settings table
---@param old_pages integer
---@param new_pages integer
local function remapSidecar(archive_path, old_pages, new_pages)
    if old_pages < 1 or new_pages < 1 or old_pages == new_pages then return end
    local ok, DocSettings = pcall(require, "docsettings")
    if not ok or not DocSettings or not DocSettings.hasSidecarFile or not DocSettings:hasSidecarFile(archive_path) then
        return
    end
    local settings = DocSettings:open(archive_path)
    if not settings or not settings.readSetting then return end
    local last = tonumber(settings:readSetting("last_page"))
    if last then
        -- 按章内比例映射；切分不均匀时只能近似，优先保证落在合法页码。
        local mapped = math.floor((last - 1) / old_pages * new_pages + 0.5) + 1
        if mapped < 1 then mapped = 1 end
        if mapped > new_pages then mapped = new_pages end
        settings:saveSetting("last_page", mapped)
    end
    if settings:readSetting("doc_pages") then
        settings:saveSetting("doc_pages", new_pages)
    end
    if settings.flush then settings:flush() end
end

---@param writer ArchiverWriter
---@param path string
---@param name string
---@return boolean
---@return string|nil
local function addFile(writer, path, name)
    local file, err = io.open(path, "rb")
    if not file then return false, err or _("无法读取漫画图片") end
    local data = file:read("*a")
    file:close()
    if not writer:addFileFromMemory(name, data) then
        return false, writer.err or _("无法写入漫画文件")
    end
    return true
end

--- 把页图打成 CBZ；每张源图先按 cbz_fit 缩小/切片，切片按序成为独立页。
---@param paths string[]
---@param archive_path string
---@param state table
---@param cb fun(path: string|nil, err: string|nil)
function Cbz.build(paths, archive_path, state, cb)
    local tmp = archive_path .. ".part"
    os.remove(tmp)
    local writer = require("ffi/archiver").Writer:new()
    local screen_w, screen_h = Fit.screen()
    local dest_dir = archive_path:gsub("%.cb[zt]$", "") .. ".fit"
    ---@type string[]
    local temps = {}
    local function clearTemps()
        for _idx, path in ipairs(temps) do os.remove(path) end
        temps = {}
        pcall(function() require("libs/libkoreader-lfs").rmdir(dest_dir) end)
    end
    --- 打包中途失败：关 writer、删半截文件后回调错误。
    local function fail(err)
        writer:close()
        state.writer = nil
        os.remove(tmp)
        clearTemps()
        cb(nil, err)
    end
    if not writer:open(tmp, "zip") or not writer:setZipCompression("store") then
        fail(writer.err or _("无法创建漫画文件"))
        return
    end
    state.writer = writer
    local src_index, page_index = 1, 1
    ---@type CbzFitPage[]
    local queue = {}
    local queue_at = 1
    local function nextFile()
        if state.cancelled then
            clearTemps()
            return
        end
        if queue_at > #queue then
            local src = paths[src_index]
            if not src then
                writer:close()
                state.writer = nil
                local ok, err = os.rename(tmp, archive_path)
                if not ok then
                    os.remove(tmp)
                    clearTemps()
                    cb(nil, err or _("无法保存漫画文件"))
                    return
                end
                for _idx, image_path in ipairs(paths) do os.remove(image_path) end
                clearTemps()
                cb(archive_path)
                return
            end
            src_index = src_index + 1
            local pages, err = Fit.materialize(src, dest_dir, page_index, screen_w, screen_h)
            if not pages then
                fail(err or _("无法读取漫画图片"))
                return
            end
            queue, queue_at = pages, 1
            page_index = page_index + #pages
            for _idx, page in ipairs(pages) do
                if page.temp then temps[#temps + 1] = page.path end
            end
            require("ui/uimanager"):nextTick(require("ui.guard").wrap("cbz write", nextFile))
            return
        end
        local page = queue[queue_at]
        queue_at = queue_at + 1
        local ok, err = addFile(writer, page.path, page.name)
        if not ok then
            fail(err)
            return
        end
        if page.temp then
            os.remove(page.path)
        end
        require("ui/uimanager"):nextTick(require("ui.guard").wrap("cbz write", nextFile))
    end
    require("ui/uimanager"):nextTick(require("ui.guard").wrap("cbz write", nextFile))
end

--- 把已有 CBZ 按当前屏幕重新缩小/切片，成功后原地替换。
---@param archive_path string
---@param state table
---@param cb fun(path: string|nil, err: string|nil, meta: { old_pages: integer, new_pages: integer }|nil)
---@param screen_w integer|nil
---@param screen_h integer|nil
function Cbz.rebuild(archive_path, state, cb, screen_w, screen_h)
    screen_w = screen_w or select(1, Fit.screen())
    screen_h = screen_h or select(2, Fit.screen())
    local entries, list_err = Cbz.listImages(archive_path)
    if not entries or #entries == 0 then
        cb(nil, list_err or _("无法读取漫画图片"))
        return
    end
    local old_pages = #entries
    local extract_dir = archive_path .. ".src"
    local fit_dir = archive_path .. ".fit"
    local tmp = archive_path .. ".part"
    os.remove(tmp)
    local writer = require("ffi/archiver").Writer:new()
    ---@type string[]
    local temps = {}
    local function clearWork()
        for _idx, path in ipairs(temps) do os.remove(path) end
        pcall(function()
            for name in lfs.dir(extract_dir) do
                if name ~= "." and name ~= ".." then os.remove(extract_dir .. "/" .. name) end
            end
            lfs.rmdir(extract_dir)
        end)
        pcall(function()
            for name in lfs.dir(fit_dir) do
                if name ~= "." and name ~= ".." then os.remove(fit_dir .. "/" .. name) end
            end
            lfs.rmdir(fit_dir)
        end)
    end
    local function fail(err)
        if state.writer then
            writer:close()
            state.writer = nil
        end
        os.remove(tmp)
        clearWork()
        cb(nil, err)
    end
    if not writer:open(tmp, "zip") or not writer:setZipCompression("store") then
        fail(writer.err or _("无法创建漫画文件"))
        return
    end
    state.writer = writer
    local ok_dir, dir_err = require("utils.paths").ensureDir(extract_dir)
    if not ok_dir then
        fail(dir_err)
        return
    end
    local reader_ok, Reader = pcall(function()
        return require("ffi/archiver").Reader
    end)
    if not reader_ok or not Reader then
        fail(_("无法读取漫画图片"))
        return
    end
    local reader = Reader:new()
    if not reader:open(archive_path) then
        fail(reader.err or _("无法读取漫画图片"))
        return
    end
    local entry_index, page_index = 1, 1
    local new_pages = 0
    ---@type CbzFitPage[]
    local queue = {}
    local queue_at = 1
    local function nextFile()
        if state.cancelled then
            reader:close()
            clearWork()
            return
        end
        if queue_at > #queue then
            local entry = entries[entry_index]
            if not entry then
                reader:close()
                writer:close()
                state.writer = nil
                local bak = archive_path .. ".old"
                os.remove(bak)
                if not os.rename(archive_path, bak) then
                    os.remove(tmp)
                    clearWork()
                    cb(nil, _("无法保存漫画文件"))
                    return
                end
                local ok, err = os.rename(tmp, archive_path)
                if not ok then
                    os.rename(bak, archive_path)
                    os.remove(tmp)
                    clearWork()
                    cb(nil, err or _("无法保存漫画文件"))
                    return
                end
                os.remove(bak)
                remapSidecar(archive_path, old_pages, new_pages)
                clearWork()
                cb(archive_path, nil, { old_pages = old_pages, new_pages = new_pages })
                return
            end
            entry_index = entry_index + 1
            local src = extract_dir .. "/" .. (entry.path:match("([^/\\]+)$") or ("page" .. entry_index))
            os.remove(src)
            if not reader:extractToPath(entry.path, src) then
                fail(reader.err or _("无法读取漫画图片"))
                return
            end
            temps[#temps + 1] = src
            local pages, err = Fit.materialize(src, fit_dir, page_index, screen_w, screen_h)
            if not pages then
                fail(err or _("无法读取漫画图片"))
                return
            end
            queue, queue_at = pages, 1
            page_index = page_index + #pages
            new_pages = new_pages + #pages
            for _idx, page in ipairs(pages) do
                if page.temp then temps[#temps + 1] = page.path end
            end
            require("ui/uimanager"):nextTick(require("ui.guard").wrap("cbz rebuild", nextFile))
            return
        end
        local page = queue[queue_at]
        queue_at = queue_at + 1
        local ok, err = addFile(writer, page.path, page.name)
        if not ok then
            fail(err)
            return
        end
        if page.temp then os.remove(page.path) end
        require("ui/uimanager"):nextTick(require("ui.guard").wrap("cbz rebuild", nextFile))
    end
    require("ui/uimanager"):nextTick(require("ui.guard").wrap("cbz rebuild", nextFile))
end

--- 打开前确保 CBZ 页图不超过当前屏幕的安全尺寸；不需要时同步回调原路径。
---@param path string
---@param cb fun(path: string|nil, err: string|nil)
---@param opts { on_rebuild: fun()|nil, state: table|nil }|nil
---@return { cancel: fun() }
function Cbz.ensureAsync(path, cb, opts)
    opts = opts or {}
    local state = opts.state or { cancelled = false }
    if not Cbz.isArchive(path) or not Cbz.ready(path) then
        cb(path)
        return { cancel = function() state.cancelled = true end }
    end
    local ok, needed = pcall(function()
        return Cbz.needsFit(path)
    end)
    if not ok or not needed then
        if not ok then
            require("utils.log").warn("book.cbz inspect failed", path, needed)
        end
        cb(path)
        return { cancel = function() state.cancelled = true end }
    end
    if opts.on_rebuild then opts.on_rebuild() end
    Cbz.rebuild(path, state, function(fitted, err)
        if state.cancelled then return end
        if fitted then cb(fitted) else cb(nil, err) end
    end)
    return {
        cancel = function()
            state.cancelled = true
            if state.writer then state.writer:close() end
            os.remove(path .. ".part")
        end,
    }
end

return Cbz
