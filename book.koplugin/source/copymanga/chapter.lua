--[[--
拷贝漫画章节图片下载与 CBZ 打包。

@module koplugin.book.source.copymanga.chapter
--]]

local Archiver = require("ffi/archiver")
local Client = require("source.copymanga.client")
local Image = require("utils.image")
local Paths = require("utils.paths")
local Protocol = require("source.copymanga.protocol")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

local Chapter = {}

---@param path string
---@return boolean
local function fileReady(path)
    local attr = lfs.attributes(path)
    return attr ~= nil and attr.mode == "file" and (tonumber(attr.size) or 0) > 0
end

---@param paths string[]
---@param archive_path string
---@param state table
---@param cb fun(path: string|nil, err: string|nil)
local function buildArchive(paths, archive_path, state, cb)
    local tmp = archive_path .. ".part"
    os.remove(tmp)
    local writer = Archiver.Writer:new()
    --- 打包中途失败：关 writer、删半截文件后回调错误。
    local function fail(err)
        writer:close()
        state.writer = nil
        os.remove(tmp)
        cb(nil, err)
    end
    if not writer:open(tmp, "zip") or not writer:setZipCompression("store") then
        fail(writer.err or _("无法创建漫画文件"))
        return
    end
    state.writer = writer
    local index = 1
    local function nextFile()
        if state.cancelled then return end
        local path = paths[index]
        if not path then
            writer:close()
            state.writer = nil
            local ok, err = os.rename(tmp, archive_path)
            if not ok then
                os.remove(tmp)
                cb(nil, err or _("无法保存漫画文件"))
                return
            end
            for _idx, image_path in ipairs(paths) do os.remove(image_path) end
            cb(archive_path)
            return
        end
        local file, err = io.open(path, "rb")
        if not file then
            fail(err or _("无法读取漫画图片"))
            return
        end
        local data = file:read("*a")
        file:close()
        local name = path:match("([^/\\]+)$") or tostring(index)
        if not writer:addFileFromMemory(name, data) then
            fail(writer.err or _("无法写入漫画文件"))
            return
        end
        index = index + 1
        require("ui/uimanager"):nextTick(require("ui.guard").wrap("copymanga write", nextFile))
    end
    require("ui/uimanager"):nextTick(require("ui.guard").wrap("copymanga write", nextFile))
end

--- 章节 CBZ 路径。按章节 uuid 命名：多分组漫画更新后连续章序号会整体后移，按序号命名会串章。
---@param identity BookIdentity
---@param chapter BookChapter
---@return string
function Chapter.archivePath(identity, chapter)
    return Paths.bookWorkDir(identity.stable_id, identity.source_id) .. "/" .. chapter.uid .. ".cbz"
end

--- 已下载好的章节 CBZ；没有则 nil。
---@param identity BookIdentity
---@param chapter BookChapter
---@return string|nil
function Chapter.existing(identity, chapter)
    local path = Chapter.archivePath(identity, chapter)
    return fileReady(path) and path or nil
end

--- 下载并打包一个漫画章节；已有 CBZ 直接复用。
---@param client CopymangaClient
---@param identity BookIdentity
---@param chapter BookChapter
---@param on_progress fun(done: integer, total: integer)|nil
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }
function Chapter.materializeAsync(client, identity, chapter, on_progress, cb)
    Paths.ensureBookWork(identity.stable_id, identity.source_id)
    local archive_path = Chapter.archivePath(identity, chapter)
    ---@type { cancelled: boolean, active: CancelHandle|nil, writer: ArchiverWriter|nil }
    local state = { cancelled = false, active = nil, writer = nil }
    if fileReady(archive_path) then
        require("ui/uimanager"):nextTick(require("ui.guard").wrap("copymanga callback", function()
            if not state.cancelled then cb(archive_path) end
        end))
        return { cancel = function() state.cancelled = true end }
    end

    state.active = client:chapterAsync(identity.stable_id, chapter.uid, function(wire, err)
        state.active = nil
        if state.cancelled then return end
        if not wire then cb(nil, err); return end
        local urls, decode_err = Protocol.chapterImages(wire)
        if not urls then cb(nil, decode_err); return end

        local image_dir = archive_path:gsub("%.cbz$", "")
        Paths.ensureDir(image_dir)
        local paths, current = {}, 1
        for i, url in ipairs(urls) do
            paths[i] = image_dir .. "/" .. string.format("%04d%s", i, Image.suffix(url) or ".jpg")
        end

        local function nextImage()
            if state.cancelled then return end
            local url = urls[current]
            if not url then
                buildArchive(paths, archive_path, state, cb)
                return
            end
            local path = paths[current]
            if Image.ok(path) then
                if on_progress then on_progress(current, #urls) end
                current = current + 1
                require("ui/uimanager"):nextTick(require("ui.guard").wrap("copymanga image", nextImage))
                return
            end
            state.active = require("http.request").download({
                url = url,
                headers = Client.headers(client.token),
                timeout = 90,
                max_bytes = 32 * 1024 * 1024,
            }, path, function(ok, download_err)
                state.active = nil
                if state.cancelled then return end
                if not ok or not Image.ok(path) then
                    os.remove(path)
                    cb(nil, download_err or _("漫画图片下载失败"))
                    return
                end
                if on_progress then on_progress(current, #urls) end
                current = current + 1
                nextImage()
            end)
        end
        nextImage()
    end)

    return { cancel = function()
            if state.cancelled then return end
            state.cancelled = true
            if state.active then state.active.cancel() end
            if state.writer then state.writer:close() end
            os.remove(archive_path .. ".part")
        end }
end

--- 后台预取章节 CBZ；已有文件由 materializeAsync 直接复用。
--- 单章失败不阻断后续。不 touch 书架路径，避免阅读中改掉当前章登记。
---@param client CopymangaClient
---@param identity BookIdentity
---@param toc BookChapter[]
---@param from_idx integer 当前章序号（预取 from_idx+1 …）；0 表示从第一章开始
---@param count integer
---@param ops { progress: fun(done: integer, total: integer)|nil, interval_seconds: number|nil }|nil
---@param cb fun(cached: integer, total: integer, failed: integer, err: any)|nil
---@return { cancel: fun() }
function Chapter.prefetchAsync(client, identity, toc, from_idx, count, ops, cb)
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
        pos = pos + 1
        if not chapter then
            if cb then cb(cached_count, #chapters, failed_count, last_error) end
            return
        end
        active = Chapter.materializeAsync(client, identity, chapter, nil, function(path, err)
            active = nil
            if cancelled then return end
            if path then
                cached_count = cached_count + 1
            else
                failed_count = failed_count + 1
                last_error = err or last_error
            end
            if ops.progress then
                ops.progress(cached_count + failed_count, #chapters)
            end
            if interval > 0 then
                UIManager:scheduleIn(interval, require("ui.guard").wrap("copymanga step", step))
            else
                UIManager:nextTick(require("ui.guard").wrap("copymanga step", step))
            end
        end)
    end

    UIManager:nextTick(require("ui.guard").wrap("copymanga step", step))
    return { cancel = function()
            cancelled = true
            if active then active.cancel() end
        end }
end

return Chapter
