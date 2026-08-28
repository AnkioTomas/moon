--[[--
源侧按章阅读公共实现。

这里的代码只被具体数据源调用：目录缓存、章节正文落盘和本地进度选择
都属于源的 materialization，不属于阅读会话。

@module koplugin.book.source.chapter
--]]

local Paths = require("utils.paths")
local ProgressPosition = require("types.book_progress")
local Text = require("utils.text")
local _ = require("gettext")

local Chapter = {}

local function readFile(path)
    if type(path) ~= "string" or path == "" then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

--- 章节 HTML 是否可直接复用（存在且远程 img 已内联）。
---@param path string
---@return boolean
local function chapterReady(path)
    local html = readFile(path)
    if not html or html == "" then
        return false
    end
    return not Text.hasRemoteImageSrc(html)
end

local function loadToc(identity, ops, cb)
    return ops.loadToc(identity, function(toc, err)
        if type(toc) ~= "table" or #toc == 0 then
            cb(nil, err or _("目录为空"))
            return
        end
        cb(toc)
    end)
end

local function localPosition(identity)
    local pending = require("utils.db.progress").get(identity.source_id, identity.stable_id)
    if pending and (tonumber(pending.chapter_idx) or (tonumber(pending.fraction) or 0) > 0) then
        return pending
    end
    local book = require("utils.db.book").get(identity.source_id, identity.stable_id)
    if book and tonumber(book.last_chapter_idx) then
        return { chapter_idx = tonumber(book.last_chapter_idx) }
    end
end

--- 本地已有章节文件时返回路径，供快开；否则 nil。
---@param identity BookIdentity
---@param opts table|nil
---@return string|nil
local function existingLocalPath(identity, opts)
    opts = opts or {}
    local idx = tonumber(opts.chapter_idx)
    if idx then
        local path = Paths.chapterPath(identity.stable_id, idx, identity.source_id)
        return chapterReady(path) and path or nil
    end
    local book = identity.book
    if not book or not book.path then
        book = require("utils.db.book").get(identity.source_id, identity.stable_id)
    end
    if book and chapterReady(book.path) then
        return book.path
    end
    local pos = localPosition(identity)
    idx = pos and tonumber(pos.chapter_idx) or 1
    local path = Paths.chapterPath(identity.stable_id, idx, identity.source_id)
    return chapterReady(path) and path or nil
end

local function body(payload)
    local title, content = _("章节"), ""
    if type(payload) == "string" then
        content = payload
    elseif type(payload) == "table" then
        title = type(payload.title) == "string" and payload.title ~= "" and payload.title or title
        content = payload.html or payload.text or ""
        if payload.text and not payload.html then
            content = Text.textToBody(content)
        end
    end
    if content ~= "" and not Text.looksLikeHtml(content) then
        content = Text.textToBody(content)
    end
    return title, content
end

local function write(path, payload, cb)
    local title, content = body(payload)
    if content == "" then
        cb(nil, _("章节内容为空"))
        return
    end
    local escaped = Text.xmlEscape(title)
    local html = string.format([[<!DOCTYPE html><html lang="zh"><head><meta charset="utf-8"/><title>%s</title><style>body{margin:5%%;line-height:1.8;text-align:justify;}h1{text-align:center;}p{text-indent:2em;margin:.45em 0;}img{max-width:100%%;}</style></head><body><h1>%s</h1>%s</body></html>]], escaped, escaped, content)
    local tmp = path .. ".part"
    pcall(os.remove, tmp)
    local f, err = io.open(tmp, "wb")
    if not f then cb(nil, err or _("无法写入章节")); return end
    f:write(html)
    f:close()
    os.remove(path)
    if not os.rename(tmp, path) then
        pcall(os.remove, tmp)
        cb(nil, _("无法保存章节文件"))
        return
    end
    cb(path)
end

local function ensure(identity, toc, idx, ops, cb)
    local path = Paths.chapterPath(identity.stable_id, idx, identity.source_id)
    if chapterReady(path) then
        if ops.refreshCached then
            local item = toc[idx]
            return ops.refreshCached(identity, item, path, cb)
        end
        cb(path)
        return
    end
    local item = assert(toc[idx], "invalid chapter toc")
    return ops.fetchContent(identity, item, function(payload, err)
        if not payload then cb(nil, err or _("章节下载失败")); return end
        write(path, payload, cb)
    end)
end

--- 按章打开：拉目录 → 选章 → 落盘正文 → 登记路径；可取消。
---@param source BookSource
---@param identity BookIdentity
---@param book Book
---@param opts table|nil
---@param ops { loadToc: fun(identity: BookIdentity, cb: function), fetchContent: fun(identity: BookIdentity, chapter: BookChapter, cb: function), progress: fun(step: integer)|nil }
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }
function Chapter.openAsync(source, identity, book, opts, ops, cb)
    opts = opts or {}
    local cancelled = false
    local active
    local progress = ops.progress or function() end

    --- 启动一个阶段；同步回调和异步回调都只允许当前阶段继续流水线。
    local function run(start, done)
        local operation = {}
        active = operation
        operation.job = start(function(...)
            if cancelled or active ~= operation then
                return
            end
            active = nil
            done(...)
        end)
    end

    local function withBook(detail)
        book = detail or book
        progress(1)
        run(function(done)
            return loadToc(identity, ops, done)
        end, function(toc, err)
            if not toc then cb(nil, err); return end
            progress(2)
            local idx = tonumber(opts.chapter_idx)
            if not idx then
                local pos = localPosition(identity)
                idx = pos and tonumber(pos.chapter_idx)
                if not idx and pos then
                    idx = math.floor(ProgressPosition.clampFraction(pos.fraction) * #toc) + 1
                end
            end
            idx = math.max(1, math.min(#toc, idx or 1))
            run(function(done)
                return ensure(identity, toc, idx, ops, done)
            end, function(path, e)
                if not path then cb(nil, e); return end
                progress(3)
                run(function(done)
                    return require("book.store").touchAsync(path, identity, {
                        chapter_idx = idx,
                        toc = toc,
                        book = book,
                    }, done)
                end, function(ok, db_err)
                    if not ok then
                        cb(nil, db_err and tostring(db_err) or _("无法登记章节"))
                        return
                    end
                    progress(4)
                    cb(path)
                end)
            end)
        end)
    end
    if not opts.chapter_idx and source.getDetailAsync then
        run(function(done)
            return source:getDetailAsync(identity, done)
        end, withBook)
    else
        withBook(book)
    end
    return {
        cancel = function()
            cancelled = true
            local job = active and active.job
            active = nil
            if job and job.cancel then
                job.cancel()
            end
        end,
    }
end

--- 带进度对话框的按章打开：本地命中则快开并在后台刷新；否则联网准备。
---@param source BookSource
---@param identity BookIdentity
---@param book Book
---@param opts table|nil
---@param ops { loadToc: fun(identity: BookIdentity, cb: function), fetchContent: fun(identity: BookIdentity, chapter: BookChapter, cb: function) }
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }
function Chapter.openWithUi(source, identity, book, opts, ops, cb)
    opts = opts or {}
    local cancelled = false
    local job, dialog, background_job

    local local_path = existingLocalPath(identity, opts)
    if local_path then
        local function open(path)
            require("ui/uimanager"):nextTick(function()
                if not cancelled then cb(path) end
            end)
        end
        if ops.refreshCached then
            require("ui/network/manager"):runWhenOnline(function()
                if cancelled then return end
                local idx = tonumber(opts.chapter_idx)
                if not idx then
                    local pos = localPosition(identity)
                    idx = pos and tonumber(pos.chapter_idx) or 1
                end
                loadToc(identity, ops, function(toc)
                    if cancelled or type(toc) ~= "table" then
                        open(local_path)
                        return
                    end
                    idx = math.max(1, math.min(#toc, idx or 1))
                    local item = toc[idx]
                    if not item then
                        open(local_path)
                        return
                    end
                    ops.refreshCached(identity, item, local_path, function(path)
                        if not cancelled then open(path or local_path) end
                    end)
                end)
            end)
        else
            open(local_path)
        end
        require("ui/network/manager"):runWhenOnline(function()
            if cancelled then return end
            background_job = Chapter.openAsync(source, identity, book, opts, ops, function() end)
        end)
        return {
            cancel = function()
                cancelled = true
                if background_job and background_job.cancel then
                    background_job.cancel()
                end
            end,
        }
    end

    local function closeDialog()
        if dialog then
            dialog:close()
            dialog = nil
        end
    end
    require("ui/network/manager"):runWhenOnline(function()
        if cancelled then
            return
        end
        dialog = require("ui/widget/progressbardialog"):new{
            title = _("正在准备章节…"),
            subtitle = book.title or identity.stable_id,
            progress_max = 4,
            refresh_time_seconds = 0.05,
            dismissable = false,
        }
        dialog:show()
        ops.progress = function(step)
            if dialog then
                dialog:reportProgress(step)
            end
        end
        job = Chapter.openAsync(source, identity, book, opts, ops, function(path, err)
            closeDialog()
            require("ui/uimanager"):nextTick(function()
                if not cancelled then cb(path, err) end
            end)
        end)
    end)
    return {
        cancel = function()
            cancelled = true
            if job then
                job.cancel()
            end
            if background_job and background_job.cancel then
                background_job.cancel()
            end
            closeDialog()
        end,
    }
end

--- 后台预取后续章节：已有文件跳过，失败静默继续；联网后顺序落盘并登记。
---@param identity BookIdentity
---@param book Book|nil
---@param toc BookChapter[]
---@param from_idx integer 当前章序号（预取 from_idx+1 …）
---@param count integer 预取章数
---@param ops { fetchContent: fun(identity: BookIdentity, chapter: BookChapter, cb: function) }
---@param cb fun()|nil 全部完成或无可预取章
---@return { cancel: fun() }
function Chapter.prefetchAsync(identity, book, toc, from_idx, count, ops, cb)
    from_idx = tonumber(from_idx) or 0
    count = tonumber(count) or 0
    local cancelled = false
    local active
    local indices = {}
    if count > 0 and type(toc) == "table" and #toc > 0 then
        for i = 1, count do
            local idx = from_idx + i
            if idx <= #toc then
                indices[#indices + 1] = idx
            end
        end
    end
    if #indices == 0 then
        require("ui/uimanager"):nextTick(function()
            if not cancelled and cb then cb() end
        end)
        return { cancel = function() cancelled = true end }
    end

    local pos = 1
    local function nextIndex()
        if cancelled then return end
        local idx = indices[pos]
        pos = pos + 1
        if not idx then
            if cb then cb() end
            return
        end
        local path = Paths.chapterPath(identity.stable_id, idx, identity.source_id)
        if chapterReady(path) then
            require("ui/uimanager"):nextTick(nextIndex)
            return
        end
        local item = toc[idx]
        if not item then
            require("ui/uimanager"):nextTick(nextIndex)
            return
        end
        active = ops.fetchContent(identity, item, function(payload)
            if cancelled then return end
            active = nil
            if not payload then
                require("ui/uimanager"):nextTick(nextIndex)
                return
            end
            write(path, payload, function(wpath)
                if cancelled then return end
                if not wpath then
                    require("ui/uimanager"):nextTick(nextIndex)
                    return
                end
                require("book.store").touchAsync(wpath, identity, {
                    chapter_idx = idx,
                    toc = toc,
                    book = book,
                }, function()
                    if cancelled then return end
                    require("ui/uimanager"):nextTick(nextIndex)
                end)
            end)
        end)
    end

    require("ui/network/manager"):runWhenOnline(function()
        if cancelled then return end
        nextIndex()
    end)
    return {
        cancel = function()
            cancelled = true
            local job = active
            active = nil
            if job and job.cancel then job.cancel() end
        end,
    }
end

return Chapter
