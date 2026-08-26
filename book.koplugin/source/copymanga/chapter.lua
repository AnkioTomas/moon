--[[--
拷贝漫画章节正文：拉图片 URL → 落盘 → 拼 HTML。

@module koplugin.book.source.copymanga.chapter
--]]

local Paths = require("utils.paths")
local Mapper = require("source.copymanga.mapper")
local _ = require("gettext")

local Chapter = {}

--- 从 URL 猜扩展名。
---@param url string
---@return string
local function extFromUrl(url)
    local ext = url:match("%.([%w]+)[^%.%/]*$")
    ext = ext and string.lower(ext) or "webp"
    if ext == "jpeg" then ext = "jpg" end
    if ext ~= "jpg" and ext ~= "png" and ext ~= "webp" and ext ~= "gif" then
        ext = "webp"
    end
    return ext
end

--- 顺序下载图片到章节目录。
---@param urls string[]
---@param dir string
---@param cb fun(paths: string[]|nil, err: string|nil)
---@return { cancel: fun() }
local function downloadPagesAsync(urls, dir, cb)
    local cancelled = false
    local paths, index, active = {}, 1, nil
    local Request = require("http.request")

    local function fail(err)
        if not cancelled then cb(nil, err) end
    end

    local function nextPage()
        if cancelled then return end
        if index > #urls then
            cb(paths)
            return
        end
        local url = urls[index]
        local ext = extFromUrl(url)
        local dest = string.format("%s/p%04d.%s", dir, index, ext)
        paths[index] = dest
        index = index + 1
        active = Request.download({
            url = url,
            headers = { ["User-Agent"] = "COPY/3.0.0" },
            timeout = 30,
        }, dest, function(ok, err)
            if cancelled then return end
            if not ok then
                fail(err or _("图片下载失败"))
                return
            end
            nextPage()
        end)
    end

    nextPage()
    return {
        cancel = function()
            cancelled = true
            if active and active.cancel then active.cancel() end
        end,
    }
end

--- 图片路径列表 → 纵向 HTML。
---@param title string
---@param image_paths string[]
---@param base_dir string
---@return string
local function htmlFromImages(title, image_paths, base_dir)
    local parts = {}
    for _, path in ipairs(image_paths) do
        local rel = path
        if path:sub(1, #base_dir + 1) == base_dir .. "/" then
            rel = path:sub(#base_dir + 2)
        end
        parts[#parts + 1] = string.format('<p><img src="%s" alt=""/></p>', rel)
    end
    return table.concat(parts, "\n")
end

--- 异步拉取章节正文。
---@param path_word string
---@param chapter table
---@param cb fun(payload: ChapterContentPayload|nil, err: any)
---@return { cancel: fun() }
function Chapter.fetchContentAsync(path_word, chapter, cb)
    local title = (chapter and chapter.title)
        or string.format(_("第 %d 话"), tonumber(chapter and chapter.idx) or 0)
    local cancelled = false
    local job1, job2

    job1 = require("source.copymanga.client"):new():chapterAsync(path_word, chapter.uid, function(wire, err)
        if cancelled then return end
        if not wire then
            cb(nil, err)
            return
        end
        local urls = Mapper.chapterPages(wire)
        if #urls == 0 then
            cb(nil, _("章节无图片"))
            return
        end
        local idx = tonumber(chapter.idx) or 0
        Paths.ensureBookWork(path_word, "copymanga")
        local base = Paths.bookWorkDir(path_word, "copymanga")
        local dir = string.format("%s/c%d", base, idx)
        local lfs = require("libs/libkoreader-lfs")
        if lfs.attributes(dir, "mode") ~= "directory" then
            lfs.mkdir(dir)
        end
        job2 = downloadPagesAsync(urls, dir, function(paths, dl_err)
            if cancelled then return end
            if not paths then
                cb(nil, dl_err)
                return
            end
            cb({
                title = title,
                html = htmlFromImages(title, paths, base),
            })
        end)
    end)

    return {
        cancel = function()
            cancelled = true
            if job1 and job1.cancel then job1.cancel() end
            if job2 and job2.cancel then job2.cancel() end
        end,
    }
end

return Chapter
