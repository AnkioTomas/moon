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
local lfs = require("libs/libkoreader-lfs")
local ready_cache = {}

--- 章节 HTML 是否可直接复用（存在且远程 img 已内联）。
---@param path string|nil
---@return boolean
local function chapterReady(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" then
        ready_cache[path] = nil
        return false
    end
    local signature = tostring(attr.size or "") .. ":" .. tostring(attr.modification or "")
    local cached = ready_cache[path]
    if cached and cached.signature == signature then
        return cached.ready
    end
    local has_remote = Text.hasRemoteImageSrcInFile(path)
    if has_remote == nil then
        ready_cache[path] = { signature = signature, ready = false }
        return false
    end
    local ready = not has_remote
    ready_cache[path] = { signature = signature, ready = ready }
    return ready
end

--- 取目录并把空目录归一成错误，免得各调用点重复判空。
---@param identity BookIdentity
---@param ops table 至少含 loadToc
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function loadToc(identity, ops, cb)
    return ops.loadToc(identity, function(toc, err)
        if type(toc) ~= "table" or #toc == 0 then
            cb(nil, err or _("目录为空"))
            return
        end
        cb(toc)
    end)
end

--- 取本地记录的阅读位置：只读 pending_progress。
--- 待推送进度只有在带章节号或百分比大于 0 时才算数，避免刚建的空记录覆盖历史。
---@param identity BookIdentity
---@return PendingProgress|{ chapter_idx: number }|nil
local function localPosition(identity)
    local pending = require("db.progress").get(identity.source_id, identity.stable_id)
    if pending and (tonumber(pending.chapter_idx) or (tonumber(pending.fraction) or 0) > 0) then
        return pending
    end
end

--- 本地已有章节文件时返回路径，供快开；否则 nil。
---@param identity BookIdentity
---@param opts table|nil
---@return string|nil
---@return number|nil
local function existingLocalPath(identity, opts)
    opts = opts or {}
    local idx = tonumber(opts.chapter_idx)
    if idx then
        local path = Paths.chapterPath(identity.stable_id, idx, identity.source_id)
        if chapterReady(path) then return path, idx end
        return nil
    end
    local book = identity.book
    if not book or not book.path then
        book = require("db.book").get(identity.source_id, identity.stable_id)
    end
    if book and chapterReady(book.path) then
        idx = tonumber(book.path:match("[/\\](%d+)%.html$"))
        if idx then return book.path, idx end
    end
    local pos = localPosition(identity)
    idx = pos and tonumber(pos.chapter_idx) or 1
    local path = Paths.chapterPath(identity.stable_id, idx, identity.source_id)
    if chapterReady(path) then return path, idx end
    return nil
end

--- 把源交来的正文载荷归一成标题与 HTML 片段。
--- 纯字符串按正文处理；表优先取 html，只有 text 或内容不像 HTML 时才转成段落。
---@param payload ChapterContentPayload|string|nil
---@return string title 章节标题，缺省为「章节」
---@return string content HTML 片段，无内容为空串
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

--- 把章节正文包成完整 HTML 落盘，先写 .part 再 rename，避免读到半截文件。
---@param path string 目标章节文件路径
---@param payload ChapterContentPayload|string|nil 源交来的正文
---@param cb fun(path: string|nil, err: string|nil) 成功回传落盘路径
---@return { cancel: fun() }|nil
local function write(path, payload, cb, opts)
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
    local completed = false
    local function finish(ok, reason)
        if completed then return end
        completed = true
        local closed, close_err = f:close()
        if not closed then ok, reason = false, reason or close_err end
        if not ok then
            pcall(os.remove, tmp)
            cb(nil, reason or _("无法写入章节"))
            return
        end
        -- Same-directory rename replaces the old cache atomically on supported targets.
        -- Deleting path first turns a transient write/rename failure into data loss.
        if not os.rename(tmp, path) then
            pcall(os.remove, tmp)
            cb(nil, _("无法保存章节文件"))
            return
        end
        local attr = lfs.attributes(path)
        if attr then
            ready_cache[path] = {
                signature = tostring(attr.size or "") .. ":" .. tostring(attr.modification or ""),
                ready = true,
            }
        end
        cb(path)
    end

    if not (opts and opts.yield_write) then
        local wrote, write_err = f:write(html)
        finish(wrote ~= nil, write_err)
        return
    end

    -- 全本缓存让出事件循环，避免一次把整章 HTML 写完后才处理返回/翻页。
    local UIManager = require("ui/uimanager")
    local offset = 1
    local chunk_size = 64 * 1024
    local function writeNext()
        if completed then return end
        if offset > #html then
            finish(true)
            return
        end
        local chunk = html:sub(offset, offset + chunk_size - 1)
        local wrote, write_err = f:write(chunk)
        if not wrote then
            finish(false, write_err)
            return
        end
        offset = offset + #chunk
        UIManager:nextTick(writeNext)
    end
    UIManager:nextTick(writeNext)
    return {
        cancel = function()
            if completed then return end
            completed = true
            pcall(function() f:close() end)
            pcall(os.remove, tmp)
        end,
    }
end

--- 确保第 idx 章正文已在本地：已就绪则直接用（源提供 refreshCached 时交它决定是否刷新），
--- 否则拉正文并落盘。
---@param identity BookIdentity
---@param toc BookChapter[] 完整目录
---@param idx number 章节序号，必须落在 toc 范围内
---@param ops table 至少含 fetchContent，可选 refreshCached/persist_toc/persist_book
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
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
    ---@param start fun(done: function): table|nil 阶段体，返回可取消 job
    ---@param done function 阶段完成回调，收到 start 内部回调的全部参数
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

    --- 拿到（可能刷新过的）书籍详情后跑完整流水线：目录 → 选章 → 落盘 → 登记路径。
    --- 未指定 opts.chapter_idx 时按本地进度选章，只有百分比没有章号就按目录长度折算。
    ---@param detail Book|nil 最新详情，nil 表示沿用传入的 book
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
                local ok, db_err = require("book.store").touch(path, identity, {
                    chapter_idx = idx,
                    toc = toc,
                    book = book,
                })
                if not ok then
                    cb(nil, db_err)
                    return
                end
                progress(4)
                cb(path)
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

--- 带进度对话框的按章打开：本地命中快开；否则联网准备。
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
    local job, dialog

    local local_path, local_idx = existingLocalPath(identity, opts)
    if local_path then
        local touched, touch_err = require("book.store").touch(local_path, identity, {
            chapter_idx = local_idx,
        })
        -- 本地命中直接交付。不要在切章时再启动后台 openAsync：它会重复读目录、
        -- 扫描/改写整份 HTML，并把这些同步工作塞回 UI 线程，抵消快开收益。
        -- 但身份登记不能省：旧缓存可能早于 chapters 表，ReaderReady 只按路径精确查库。
        require("ui/uimanager"):nextTick(function()
            if not cancelled then cb(touched and local_path or nil, touch_err) end
        end)
        return {
            cancel = function()
                cancelled = true
            end,
        }
    end

    --- 关掉进度对话框并置空句柄；重复调用无副作用。
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
            closeDialog()
        end,
    }
end

--- 后台预取章节：已有文件跳过，逐章落盘并统计成功/失败。
---@param identity BookIdentity
---@param book Book|nil
---@param toc BookChapter[]
---@param from_idx integer 当前章序号（预取 from_idx+1 …）
---@param count integer 预取章数
---@param ops { fetchContent: fun(identity: BookIdentity, chapter: BookChapter, cb: function), progress: fun(done: integer, total: integer)|nil, interval_seconds: number|nil }
---@param cb fun(cached: integer, total: integer, failed: integer, err: any)|nil 完成统计
---@return { cancel: fun() }
function Chapter.prefetchAsync(identity, book, toc, from_idx, count, ops, cb)
    from_idx = tonumber(from_idx) or 0
    count = tonumber(count) or 0
    local cancelled = false
    local active
    local cached_count, failed_count = 0, 0
    local last_error
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
            if not cancelled and cb then cb(0, 0, 0) end
        end)
        return { cancel = function() cancelled = true end }
    end

    local pos = 1
    local interval = math.max(0, tonumber(ops.interval_seconds) or 0)
    local function report()
        if ops.progress then
            ops.progress(cached_count + failed_count, #indices)
        end
    end

    local nextIndex
    local function continueNext()
        local UIManager = require("ui/uimanager")
        if interval > 0 then
            UIManager:scheduleIn(interval, nextIndex)
        else
            UIManager:nextTick(nextIndex)
        end
    end
    local function failed(err)
        failed_count = failed_count + 1
        last_error = err or last_error
        report()
        continueNext()
    end

    --- 处理下一个待预取章节；单章失败不阻断后续，但必须进入最终统计。
    --- 每章之间让出事件循环，避免预取阻塞翻页。全部处理完调用 cb。
    nextIndex = function()
        if cancelled then return end
        local idx = indices[pos]
        pos = pos + 1
        if not idx then
            if cb then cb(cached_count, #indices, failed_count, last_error) end
            return
        end
        local path = Paths.chapterPath(identity.stable_id, idx, identity.source_id)
        if chapterReady(path) then
            cached_count = cached_count + 1
            report()
            require("ui/uimanager"):nextTick(nextIndex)
            return
        end
        local item = toc[idx]
        if not item then
            failed(_("章节信息缺失") .. " #" .. tostring(idx))
            return
        end
        active = ops.fetchContent(identity, item, function(payload, err)
            if cancelled then return end
            active = nil
            if not payload then
                failed(err or (_("章节内容获取失败") .. " #" .. tostring(idx)))
                return
            end
            active = write(path, payload, function(wpath, write_err)
                active = nil
                if cancelled then return end
                if not wpath then
                    failed(write_err or (_("章节保存失败") .. " #" .. tostring(idx)))
                    return
                end
                local store_opts = { chapter_idx = idx }
                if ops.persist_toc ~= false then store_opts.toc = toc end
                if ops.persist_book ~= false then store_opts.book = book end
                local touched, touch_err = require("book.store").touch(wpath, identity, store_opts)
                if not touched then
                    failed(touch_err)
                    return
                end
                cached_count = cached_count + 1
                report()
                continueNext()
            end, { yield_write = true })
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
