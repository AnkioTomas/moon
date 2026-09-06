--[[--
拷贝漫画章节图片下载与 CBZ 打包。

@module koplugin.book.source.copymanga.chapter
--]]

local Archiver = require("ffi/archiver")
local Client = require("source.copymanga.client")
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

---@param url string
---@return string
local function imageExtension(url)
    local path = url:lower():match("^[^%?#]+") or ""
    return path:match("%.webp$") and ".webp"
        or path:match("%.png$") and ".png"
        or path:match("%.gif$") and ".gif"
        or path:match("%.jpe?g$") and ".jpg"
        or ".jpg"
end

---@param path string
---@return boolean
local function imageReady(path)
    if not fileReady(path) then return false end
    local file = io.open(path, "rb")
    if not file then return false end
    local magic = file:read(12) or ""
    file:close()
    return magic:sub(1, 3) == "\255\216\255"
        or magic:sub(1, 8) == "\137PNG\r\n\026\n"
        or magic:sub(1, 6) == "GIF87a"
        or magic:sub(1, 6) == "GIF89a"
        or (magic:sub(1, 4) == "RIFF" and magic:sub(9, 12) == "WEBP")
end

---@param dir string
local function ensureDir(dir)
    if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
end

---@param paths string[]
---@param archive_path string
---@param state table
---@param cb fun(path: string|nil, err: string|nil)
local function buildArchive(paths, archive_path, state, cb)
    local tmp = archive_path .. ".part"
    pcall(os.remove, tmp)
    local writer = Archiver.Writer:new()
    if not writer:open(tmp, "zip") or not writer:setZipCompression("store") then
        writer:close()
        pcall(os.remove, tmp)
        cb(nil, writer.err or _("无法创建漫画文件"))
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
                pcall(os.remove, tmp)
                cb(nil, err or _("无法保存漫画文件"))
                return
            end
            for _, image_path in ipairs(paths) do pcall(os.remove, image_path) end
            cb(archive_path)
            return
        end
        local file, err = io.open(path, "rb")
        if not file then
            writer:close()
            state.writer = nil
            pcall(os.remove, tmp)
            cb(nil, err or _("无法读取漫画图片"))
            return
        end
        local data = file:read("*a")
        file:close()
        local name = path:match("([^/\\]+)$") or tostring(index)
        if not writer:addFileFromMemory(name, data) then
            local write_err = writer.err
            writer:close()
            state.writer = nil
            pcall(os.remove, tmp)
            cb(nil, write_err or _("无法写入漫画文件"))
            return
        end
        index = index + 1
        require("ui/uimanager"):nextTick(nextFile)
    end
    require("ui/uimanager"):nextTick(nextFile)
end

--- 下载并打包一个漫画章节；已有 CBZ 直接复用。
---@param client CopymangaClient
---@param identity BookIdentity
---@param chapter BookChapter
---@param chapter_idx integer
---@param on_progress fun(done: integer, total: integer)|nil
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }
function Chapter.materializeAsync(client, identity, chapter, chapter_idx, on_progress, cb)
    Paths.ensureBookWork(identity.stable_id, identity.source_id)
    local work_dir = Paths.bookWorkDir(identity.stable_id, identity.source_id)
    local archive_path = work_dir .. "/" .. chapter_idx .. ".cbz"
    local state = { cancelled = false, active = nil, writer = nil }
    if fileReady(archive_path) then
        require("ui/uimanager"):nextTick(function()
            if not state.cancelled then cb(archive_path) end
        end)
        return {
            cancel = function() state.cancelled = true end,
        }
    end

    state.active = client:chapterAsync(identity.stable_id, tostring(chapter.uid), function(wire, err)
        state.active = nil
        if state.cancelled then return end
        if not wire then cb(nil, err or _("章节下载失败")); return end
        local urls, decode_err = Protocol.chapterImages(wire)
        if not urls then cb(nil, decode_err or _("章节图片解析失败")); return end

        local image_dir = work_dir .. "/chapter-" .. chapter_idx
        ensureDir(image_dir)
        local paths, current = {}, 1
        for i, url in ipairs(urls) do
            paths[i] = image_dir .. "/" .. string.format("%04d%s", i, imageExtension(url))
        end

        local function nextImage()
            if state.cancelled then return end
            local url = urls[current]
            if not url then
                buildArchive(paths, archive_path, state, cb)
                return
            end
            local path = paths[current]
            if imageReady(path) then
                if on_progress then on_progress(current, #urls) end
                current = current + 1
                require("ui/uimanager"):nextTick(nextImage)
                return
            end
            state.active = require("http.request").download({
                url = url,
                headers = Client.headers(client.token),
                timeout = 90,
                connect_timeout = 15,
                max_bytes = 32 * 1024 * 1024,
            }, path, function(ok, download_err)
                state.active = nil
                if state.cancelled then return end
                if not ok or not imageReady(path) then
                    pcall(os.remove, path)
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

    return {
        cancel = function()
            if state.cancelled then return end
            state.cancelled = true
            if state.active and state.active.cancel then state.active.cancel() end
            if state.writer then state.writer:close() end
            pcall(os.remove, archive_path .. ".part")
        end,
    }
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
    from_idx = tonumber(from_idx) or 0
    count = tonumber(count) or 0
    ops = ops or {}
    local cancelled, active = false, nil
    local cached_count, failed_count, last_error = 0, 0, nil
    local indices = {}
    if type(toc) == "table" then
        for i = 1, count do
            local idx = from_idx + i
            if toc[idx] then indices[#indices + 1] = idx end
        end
    end

    local pos = 1
    local interval = math.max(0, tonumber(ops.interval_seconds) or 0)
    local step
    local function report()
        if ops.progress then
            ops.progress(cached_count + failed_count, #indices)
        end
    end
    local function continueNext()
        local UIManager = require("ui/uimanager")
        if interval > 0 then
            UIManager:scheduleIn(interval, step)
        else
            UIManager:nextTick(step)
        end
    end

    step = function()
        if cancelled then return end
        local idx = indices[pos]
        pos = pos + 1
        if not idx then
            if cb then cb(cached_count, #indices, failed_count, last_error) end
            return
        end
        active = Chapter.materializeAsync(client, identity, toc[idx], idx, nil, function(path, err)
            active = nil
            if cancelled then return end
            if path then
                cached_count = cached_count + 1
            else
                failed_count = failed_count + 1
                last_error = err or last_error
            end
            report()
            continueNext()
        end)
    end

    require("ui/uimanager"):nextTick(step)
    return {
        cancel = function()
            cancelled = true
            if active and active.cancel then active.cancel() end
        end,
    }
end

return Chapter
