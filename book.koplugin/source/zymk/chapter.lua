--[[--
知音漫客章节图片下载与 CBZ 打包。

页图地址不带后缀。接口要求 JPEG，落盘后再按文件头改后缀。

@module source.zymk.chapter
--]]

local Cbz = require("source.cbz")
local Client = require("source.zymk.client")
local Image = require("utils.image")
local Paths = require("utils.paths")
local _ = require("l10n").get("source.zymk")

local Chapter = {}

---@param identity BookIdentity
---@param chapter BookChapter
---@return string
function Chapter.archivePath(identity, chapter)
    return Paths.bookWorkDir(identity.stable_id, identity.source_id) .. "/" .. chapter.uid:gsub("/", "_") .. ".cbz"
end

---@param identity BookIdentity
---@param chapter BookChapter
---@return string|nil
function Chapter.existing(identity, chapter)
    local path = Chapter.archivePath(identity, chapter)
    return Cbz.ready(path) and path or nil
end

---@param path string
---@return string
local function withRealSuffix(path)
    local ext = Image.file(path)
    if not ext or path:sub(-#ext) == ext then return path end
    local renamed = path:gsub("%.%w+$", "") .. ext
    if renamed ~= path and os.rename(path, renamed) then return renamed end
    return path
end

---@param identity BookIdentity
---@param chapter BookChapter
---@param on_progress fun(done: integer, total: integer)|nil
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }
function Chapter.materializeAsync(identity, chapter, on_progress, cb)
    Paths.ensureBookWork(identity.stable_id, identity.source_id)
    local archive_path = Chapter.archivePath(identity, chapter)
    ---@type { cancelled: boolean, active: CancelHandle|nil, writer: ArchiverWriter|nil }
    local state = { cancelled = false, active = nil, writer = nil }
    if Cbz.ready(archive_path) then
        require("ui/uimanager"):nextTick(require("ui.guard").wrap("zymk callback", function()
            if not state.cancelled then cb(archive_path) end
        end))
        return { cancel = function() state.cancelled = true end }
    end
    if chapter.vip then
        require("ui/uimanager"):nextTick(require("ui.guard").wrap("zymk callback", function()
            if not state.cancelled then cb(nil, _("本章未购买")) end
        end))
        return { cancel = function() state.cancelled = true end }
    end

    local fetched = false
    local image_job = Client.imagesAsync(chapter.uid, function(urls, err)
        fetched = true
        state.active = nil
        if state.cancelled then return end
        if not urls then cb(nil, err); return end
        local image_dir = archive_path:gsub("%.cbz$", "")
        Paths.ensureDir(image_dir)
        local paths, current = {}, 1
        for index, url in ipairs(urls) do
            paths[index] = image_dir .. "/" .. string.format("%04d%s", index, Image.suffix(url) or ".jpg")
        end

        local function nextImage()
            if state.cancelled then return end
            local url = urls[current]
            if not url then
                Cbz.build(paths, archive_path, state, cb)
                return
            end
            local path = paths[current]
            if Image.ok(path) then
                paths[current] = withRealSuffix(path)
                if on_progress then on_progress(current, #urls) end
                current = current + 1
                require("ui/uimanager"):nextTick(require("ui.guard").wrap("zymk image", nextImage))
                return
            end
            local downloaded = false
            local handle = require("http.request").download({
                url = url,
                timeout = require("http.timeout").net(3),
                max_bytes = 32 * 1024 * 1024,
            }, path, function(ok, download_err)
                downloaded = true
                state.active = nil
                if state.cancelled then return end
                if not ok or not Image.ok(path) then
                    os.remove(path)
                    cb(nil, download_err and tostring(download_err) or _("章节图片解析失败"))
                    return
                end
                paths[current] = withRealSuffix(path)
                if on_progress then on_progress(current, #urls) end
                current = current + 1
                require("ui/uimanager"):nextTick(require("ui.guard").wrap("zymk image", nextImage))
            end)
            if not downloaded then state.active = handle end
        end
        nextImage()
    end)
    if not fetched then state.active = image_job end

    return { cancel = function()
        if state.cancelled then return end
        state.cancelled = true
        if state.active then state.active.cancel() end
        if state.writer then state.writer:close() end
        os.remove(archive_path .. ".part")
    end }
end

---@param identity BookIdentity
---@param toc BookChapter[]
---@param from_idx integer
---@param count integer
---@param ops { progress: fun(done: integer, total: integer)|nil, interval_seconds: number|nil }|nil
---@param cb fun(cached: integer, total: integer, failed: integer, err: any)|nil
---@return { cancel: fun() }
function Chapter.prefetchAsync(identity, toc, from_idx, count, ops, cb)
    ops = ops or {}
    local cancelled, active = false, nil
    local cached_count, failed_count, last_error = 0, 0, nil
    local chapters = {}
    for idx = from_idx + 1, math.min(#toc, from_idx + count) do
        chapters[#chapters + 1] = toc[idx]
    end
    local pos = 1
    local interval = ops.interval_seconds or 0
    local UIManager = require("ui/uimanager")
    local function step()
        if cancelled then return end
        local chapter = chapters[pos]
        local chapter_idx = from_idx + pos
        pos = pos + 1
        if not chapter then
            if cb then cb(cached_count, #chapters, failed_count, last_error) end
            return
        end
        active = Chapter.materializeAsync(identity, chapter, nil, function(path, err)
            active = nil
            if cancelled then return end
            if path and not require("book.chapters_db").upsert({
                path = path, source_id = identity.source_id,
                stable_id = identity.stable_id, chapter_idx = chapter_idx,
            }) then
                path, err = nil, _("书籍信息保存失败")
            end
            if path then cached_count = cached_count + 1
            else
                failed_count = failed_count + 1
                last_error = err or last_error
            end
            if ops.progress then ops.progress(cached_count + failed_count, #chapters) end
            if interval > 0 then
                UIManager:scheduleIn(interval, require("ui.guard").wrap("zymk step", step))
            else
                UIManager:nextTick(require("ui.guard").wrap("zymk step", step))
            end
        end)
    end
    UIManager:nextTick(require("ui.guard").wrap("zymk step", step))
    return { cancel = function()
        cancelled = true
        if active then active.cancel() end
    end }
end

return Chapter
