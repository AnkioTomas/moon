--[[--
把一章的页图打成 CBZ（zip，store 模式）。漫画源共用，打包成功后删掉散页图。
打包时经 source.cbz_fit 按屏宽缩小并把过高的图切成独立页。已缓存的过大 CBZ
在打开前也会按同样规则重打包，避免阅读器一次性解码整条长图。

抽取、切片、打包在 workers.job（heavy）子进程里同步跑，不共用父进程 writer。
边车页码映射、开书和进度窗留在主进程：子进程只把 .part 写完，父进程再替换并 remap。
取消会杀掉子进程，由父进程清理临时文件。fork 之后仍走 workers.slim.afterFork。

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

---@param reader table
---@return { path: string, size: integer }[]
local function imageEntries(reader)
    ---@type { path: string, size: integer }[]
    local entries = {}
    for entry in reader:iterate() do
        if entry and entry.mode == "file" and isImageEntry(entry.path) then
            entries[#entries + 1] = { path = entry.path, size = tonumber(entry.size) or 0 }
        end
    end
    table.sort(entries, function(a, b) return a.path < b.path end)
    return entries
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
    local entries = imageEntries(reader)
    reader:close()
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
    local ok, Reader = pcall(function()
        return require("ffi/archiver").Reader
    end)
    if not ok or not Reader then return false, 0 end
    local reader = Reader:new()
    if not reader:open(archive_path) then return false, 0 end
    local entries = imageEntries(reader)
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

---@param archive_path string
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

---@param dir string
local function removeDir(dir)
    pcall(function()
        for name in lfs.dir(dir) do
            if name ~= "." and name ~= ".." then os.remove(dir .. "/" .. name) end
        end
        lfs.rmdir(dir)
    end)
end

--- 清掉打包/重建留下的半截文件与工作目录。可重复调用。
---@param archive_path string|nil
function Cbz.clearWork(archive_path)
    if type(archive_path) ~= "string" or archive_path == "" then return end
    os.remove(archive_path .. ".part")
    removeDir(archive_path .. ".src")
    removeDir(archive_path .. ".fit")
    removeDir(archive_path:gsub("%.cb[zt]$", "") .. ".fit")
end

--- 取消进行中的打包/重建：杀掉 Job 子进程，并在父进程清理临时文件。
---@param state table|nil
---@param archive_path string
function Cbz.abort(state, archive_path)
    if type(state) == "table" then
        if state._aborted then
            Cbz.clearWork(archive_path)
            return
        end
        state._aborted = true
        state.cancelled = true
        local job = state.job
        state.job = nil
        state.writer = nil
        if job and job.cancel then job:cancel() end
    end
    Cbz.clearWork(archive_path)
end

---@param state table
---@param archive_path string
---@param job table
local function attachJob(state, archive_path, job)
    state.job = job
    -- 给旧的 cancel 路径用：它们会 close writer，这里改成杀掉子进程。
    -- 不要把父进程的 archiver Writer 传进子进程，也不要从子进程回传 writer。
    state.writer = {
        close = function()
            Cbz.abort(state, archive_path)
        end,
    }
end

---@param progress fun(value: any)|nil
---@param done integer
---@param total integer
---@param last integer|nil
---@return integer|nil
local function report(progress, done, total, last)
    if not progress or total < 1 then return last end
    local percent = math.floor(done * 100 / total)
    if percent == last then return last end
    progress({ done = done, total = total })
    return percent
end

--- 同步把页图打到 `.part`。只在 Job 子进程（或测试）里跑：不改最终路径、不删源图、不写边车。
---@param paths string[]
---@param archive_path string
---@param screen_w integer
---@param screen_h integer
---@param progress fun(value: any)|nil
---@return { ok: boolean, pages: integer, error: string|nil }
function Cbz.packBuild(paths, archive_path, screen_w, screen_h, progress)
    local tmp = archive_path .. ".part"
    os.remove(tmp)
    local writer = require("ffi/archiver").Writer:new()
    local dest_dir = archive_path:gsub("%.cb[zt]$", "") .. ".fit"
    ---@type string[]
    local temps = {}
    local function fail(err)
        writer:close()
        os.remove(tmp)
        for _idx, path in ipairs(temps) do os.remove(path) end
        removeDir(dest_dir)
        return { ok = false, pages = 0, error = err }
    end
    if not writer:open(tmp, "zip") or not writer:setZipCompression("store") then
        return fail(writer.err or _("无法创建漫画文件"))
    end
    local page_index, last_percent = 1, nil
    for src_index, src in ipairs(paths) do
        local pages, err = Fit.materialize(src, dest_dir, page_index, screen_w, screen_h)
        if not pages then
            return fail(err or _("无法读取漫画图片"))
        end
        page_index = page_index + #pages
        for _idx, page in ipairs(pages) do
            if page.temp then temps[#temps + 1] = page.path end
            local ok, add_err = addFile(writer, page.path, page.name)
            if not ok then return fail(add_err) end
            if page.temp then
                os.remove(page.path)
            end
        end
        last_percent = report(progress, src_index, #paths, last_percent)
        collectgarbage("collect")
    end
    writer:close()
    removeDir(dest_dir)
    return { ok = true, pages = page_index - 1 }
end

--- 同步把已有 CBZ 重切到 `.part`。只在 Job 子进程（或测试）里跑：不替换原归档、不写边车。
---@param archive_path string
---@param screen_w integer
---@param screen_h integer
---@param progress fun(value: any)|nil
---@return { ok: boolean, old_pages: integer, new_pages: integer, error: string|nil }
function Cbz.packRebuild(archive_path, screen_w, screen_h, progress)
    local reader_ok, Reader = pcall(function()
        return require("ffi/archiver").Reader
    end)
    if not reader_ok or not Reader then
        return { ok = false, old_pages = 0, new_pages = 0, error = _("无法读取漫画图片") }
    end
    local reader = Reader:new()
    if not reader:open(archive_path) then
        return { ok = false, old_pages = 0, new_pages = 0, error = reader.err or _("无法读取漫画图片") }
    end
    local entries = imageEntries(reader)
    if #entries == 0 then
        reader:close()
        return { ok = false, old_pages = 0, new_pages = 0, error = _("无法读取漫画图片") }
    end
    local old_pages = #entries
    local extract_dir = archive_path .. ".src"
    local fit_dir = archive_path .. ".fit"
    local tmp = archive_path .. ".part"
    os.remove(tmp)
    local writer = require("ffi/archiver").Writer:new()
    ---@type string[]
    local temps = {}
    local function fail(err)
        reader:close()
        writer:close()
        os.remove(tmp)
        for _idx, path in ipairs(temps) do os.remove(path) end
        removeDir(extract_dir)
        removeDir(fit_dir)
        return { ok = false, old_pages = old_pages, new_pages = 0, error = err }
    end
    if not writer:open(tmp, "zip") or not writer:setZipCompression("store") then
        return fail(writer.err or _("无法创建漫画文件"))
    end
    local ok_dir, dir_err = require("utils.paths").ensureDir(extract_dir)
    if not ok_dir then
        return fail(dir_err)
    end
    local page_index, new_pages, last_percent = 1, 0, nil
    for entry_index, entry in ipairs(entries) do
        local src = extract_dir .. "/" .. (entry.path:match("([^/\\]+)$") or ("page" .. entry_index))
        os.remove(src)
        if not reader:extractToPath(entry.path, src) then
            return fail(reader.err or _("无法读取漫画图片"))
        end
        temps[#temps + 1] = src
        local pages, err = Fit.materialize(src, fit_dir, page_index, screen_w, screen_h)
        if not pages then
            return fail(err or _("无法读取漫画图片"))
        end
        page_index = page_index + #pages
        new_pages = new_pages + #pages
        for _idx, page in ipairs(pages) do
            if page.temp then temps[#temps + 1] = page.path end
            local ok, add_err = addFile(writer, page.path, page.name)
            if not ok then return fail(add_err) end
            if page.temp then os.remove(page.path) end
        end
        os.remove(src)
        last_percent = report(progress, entry_index, #entries, last_percent)
        collectgarbage("collect")
    end
    reader:close()
    writer:close()
    removeDir(extract_dir)
    removeDir(fit_dir)
    return { ok = true, old_pages = old_pages, new_pages = new_pages }
end

---@param state table
---@param archive_path string
---@param cb fun(...: any)
---@param worker fun(progress: fun(value: any)): table
---@param name string
---@param on_success fun(result: table)
local function startJob(state, archive_path, cb, worker, name, on_success)
    local Job = require("workers.job")
    local settled = false
    local function finished()
        settled = true
        state.job = nil
        state.writer = nil
        Cbz.clearWork(archive_path)
    end
    local job = Job.run(worker, {
        name = name,
        kind = "heavy",
        on_progress = state.on_progress,
        on_done = function(result)
            settled = true
            if state.cancelled then
                finished()
                return
            end
            if type(result) ~= "table" or not result.ok then
                finished()
                cb(nil, (type(result) == "table" and result.error) or _("无法保存漫画文件"))
                return
            end
            on_success(result)
        end,
        on_failed = function(err)
            finished()
            if not state.cancelled then cb(nil, err) end
        end,
        on_cancelled = function()
            finished()
        end,
    })
    if not settled then attachJob(state, archive_path, job) end
end

--- 把页图打成 CBZ；每张源图先按 cbz_fit 缩小/切片，切片按序成为独立页。
---@param paths string[]
---@param archive_path string
---@param state table
---@param cb fun(path: string|nil, err: string|nil)
function Cbz.build(paths, archive_path, state, cb)
    state = state or { cancelled = false }
    if state.cancelled then return end
    local screen_w, screen_h = Fit.screen()
    startJob(state, archive_path, cb, function(progress)
        return Cbz.packBuild(paths, archive_path, screen_w, screen_h, progress)
    end, "cbz.build", function(_result)
        local tmp = archive_path .. ".part"
        local ok, err = os.rename(tmp, archive_path)
        if not ok then
            Cbz.clearWork(archive_path)
            state.job, state.writer = nil, nil
            cb(nil, err or _("无法保存漫画文件"))
            return
        end
        for _idx, image_path in ipairs(paths) do os.remove(image_path) end
        state.job, state.writer = nil, nil
        Cbz.clearWork(archive_path)
        cb(archive_path)
    end)
end

--- 把已有 CBZ 按当前屏幕重新缩小/切片，成功后原地替换。
---@param archive_path string
---@param state table
---@param cb fun(path: string|nil, err: string|nil, meta: { old_pages: integer, new_pages: integer }|nil)
---@param screen_w integer|nil
---@param screen_h integer|nil
function Cbz.rebuild(archive_path, state, cb, screen_w, screen_h)
    state = state or { cancelled = false }
    if state.cancelled then return end
    local bak = archive_path .. ".old"
    if lfs.attributes(bak) then
        cb(nil, string.format(_("漫画备份尚未恢复，请先恢复：%s"), bak))
        return
    end
    screen_w = screen_w or select(1, Fit.screen())
    screen_h = screen_h or select(2, Fit.screen())
    local entries, list_err = Cbz.listImages(archive_path)
    if not entries then
        cb(nil, list_err or _("无法读取漫画图片"))
        return
    end
    if #entries == 0 then
        cb(nil, _("无法读取漫画图片"))
        return
    end
    startJob(state, archive_path, cb, function(progress)
        return Cbz.packRebuild(archive_path, screen_w, screen_h, progress)
    end, "cbz.rebuild", function(result)
        local tmp = archive_path .. ".part"
        if not os.rename(archive_path, bak) then
            Cbz.clearWork(archive_path)
            state.job, state.writer = nil, nil
            cb(nil, _("无法保存漫画文件"))
            return
        end
        local ok, err = os.rename(tmp, archive_path)
        if not ok then
            local restored, restore_err = os.rename(bak, archive_path)
            if not restored then
                require("utils.log").warn("book.cbz restore failed", archive_path, bak, restore_err)
                err = (err or _("无法保存漫画文件")) .. "\n"
                    .. _("恢复失败") .. ": " .. tostring(restore_err) .. "\n" .. bak
            end
            Cbz.clearWork(archive_path)
            state.job, state.writer = nil, nil
            cb(nil, err or _("无法保存漫画文件"))
            return
        end
        os.remove(bak)
        remapSidecar(archive_path, result.old_pages, result.new_pages)
        state.job, state.writer = nil, nil
        Cbz.clearWork(archive_path)
        cb(archive_path, nil, { old_pages = result.old_pages, new_pages = result.new_pages })
    end)
end

--- 打开前确保 CBZ 页图不超过当前屏幕的安全尺寸；不需要时同步回调原路径。
---@param path string
---@param cb fun(path: string|nil, err: string|nil)
---@param opts { on_rebuild: fun()|nil, on_progress: fun(value: any)|nil, state: table|nil }|nil
---@return { cancel: fun() }
function Cbz.ensureAsync(path, cb, opts)
    opts = opts or {}
    local state = opts.state or { cancelled = false }
    if opts.on_progress then state.on_progress = opts.on_progress end
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
            Cbz.abort(state, path)
        end,
    }
end

return Cbz
