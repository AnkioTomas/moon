--[[--
源侧按章阅读公共实现。

这里的代码只被具体数据源调用：目录缓存、章节正文落盘和本地进度选择
都属于源的 materialization，不属于阅读会话。

起始章：pending_progress 的 chapter_idx（或 fraction×目录折算），否则第 1 章，夹到 [1, #toc]；远端进度不参与选章，开书 pull 后收敛。
正文先写 .part 再 rename，Store.touch 成功才把 path 交给调用方；本地缓存快开也要 touch。工作目录 Paths.bookWorkDir（md5(stable_id)）。

@module koplugin.book.source.chapter
--]]

---@class BookChapterAnchor
---@field title string 章内目录标题
---@field depth integer 展示层级（1-based）
---@field id string|nil 章节正文里的 HTML id；有则目录点选跳到该元素，否则落到章首

--- online / article 源目录中的一章。
---@class BookChapter
---@field chapterId integer|string|nil Kavita 的章节身份
---@field origin string|nil 源端正文地址
---@field link string|nil 订阅文章地址
---@field updated integer|nil 起点章节更新时间（Unix 秒）
---@field idx integer 连续章序号（1-based）
---@field depth integer|nil 展示层级（1-based）
---@field anchors BookChapterAnchor[]|nil 章内目录节点
---@field toc_version integer|nil 目录缓存格式版本（仅首章携带）
---@field source_idx string|nil 源端非连续章节号
---@field uid string|nil 源侧章节身份
---@field vip boolean|nil VIP 章（付费章）
---@field paid boolean|nil VIP 章是否已购；nil = 还没问过（目录里不标注）
---@field title string 章节标题
---@field name string|nil 章节标题别名（部分源/目录）
---@field page number|nil KOReader 文档目录起始页
---@field xpointer string|nil KOReader 文档目录定位点
---@field tar string|nil 微信章节资源包 URL
---@field words integer|nil 微信章节字数（按篇幅对齐本地书用）
---@field raw string|nil iRead 章节对象原样 JSON（开章接口要整个带回）

local Paths = require("utils.paths")
local Progress = require("book.progress")
local Text = require("utils.text")
local _ = require("gettext")

---@alias ChapterLoadToc fun(identity: BookIdentity, cb: function): CancelHandle|nil
---@alias ChapterFetchContent fun(identity: BookIdentity, chapter: BookChapter, cb: function): CancelHandle|nil

local Chapter = {}

--- 章节变体（双语对照）：上层注入 fun(identity, idx, path): string|nil，返回要打开的替代文件。
---@type fun(identity: BookIdentity, idx: integer, path: string): string|nil
Chapter.variant = nil

---@param identity BookIdentity
---@param idx integer
---@param path string
---@return string
local function variant(identity, idx, path)
    return Chapter.variant and Chapter.variant(identity, idx, path) or path
end
local lfs = require("libs/libkoreader-lfs")
-- 临时文档（如未购买提示）以此打头：能打开，但不算缓存，下次仍会重新拉正文。
local TEMP_MARK = "<!--moon:temp-->"
local ready_cache = {}
local READY_CACHE_LIMIT = 512
local ready_cache_size = 0
local function cacheReady(path, value)
    if ready_cache[path] == nil then ready_cache_size = ready_cache_size + 1 end
    ready_cache[path] = value
    if ready_cache_size <= READY_CACHE_LIMIT then return end
    for cached_path in pairs(ready_cache) do
        ready_cache[cached_path] = nil
        ready_cache_size = ready_cache_size - 1
        break
    end
end

--- 章节 HTML 是否可直接复用（存在、是 HTML 且远程 img 已内联）。
---@param path string|nil
---@return boolean
local function chapterReady(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" then
        if ready_cache[path] ~= nil then
            ready_cache[path] = nil
            ready_cache_size = ready_cache_size - 1
        end
        return false
    end
    local signature = tostring(attr.size or "") .. ":" .. tostring(attr.modification or "")
    local cached = ready_cache[path]
    if cached and cached.signature == signature then
        return cached.ready
    end
    -- write() 只落 HTML；旧版本曾把微信付费章的纯文本试读片段落盘，不是 HTML 的不算缓存。
    local f = io.open(path, "rb")
    local head = f and f:read(64)
    if f then f:close() end
    -- nil 表示读文件失败，同样按未就绪处理。
    local ready = head ~= nil and Text.stripBom(head):find("^%s*<") ~= nil and not head:find(TEMP_MARK, 1, true)
        and Text.hasRemoteImageSrcInFile(path) == false
    cacheReady(path, { signature = signature, ready = ready })
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
    local pending = require("book.progress_db").get(identity.source_id, identity.stable_id)
    if pending and (tonumber(pending.chapter_idx) or (tonumber(pending.fraction) or 0) > 0) then
        return pending
    end
end

--- 本地已有章节文件时返回路径，供快开；否则 nil。
---@param identity BookIdentity
---@param opts table
---@return string|nil
---@return number|nil
local function existingLocalPath(identity, opts, ops)
    -- 章节文件只是按章号渲染的缓存（正文另有缓存）：章号会随目录变，源声明 volatile 就每次重渲，不信旧文件。
    if ops.volatile then return nil end
    local idx = tonumber(opts.chapter_idx)
    if idx then
        local path = Paths.chapterPath(identity.stable_id, idx, identity.source_id)
        if chapterReady(path) then return path, idx end
        return nil
    end
    local pos = localPosition(identity)
    if pos then
        -- 只有明确的本地阅读进度才能决定快开章节。books.path 只是最近
        -- 一次落盘章节的物理路径，不能把“下载过第 50 章”伪装成阅读进度。
        idx = tonumber(pos.chapter_idx)
        if not idx then return nil end
    else
        idx = 1
    end
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

local DEFAULT_CSS = "body{margin:5%;line-height:1.8;text-align:justify;}p{text-indent:2em;margin:.45em 0;}img{max-width:100%;}"

local BLANKS = { "\227\128\128", "\194\160", "&nbsp;", "&#160;", "&#12288;", "&#x3000;", "[ \t\r\n]" }

--- 去掉 <p> 开头的空格 / 全角空格 / &nbsp;：缩进只由外壳 CSS 的 text-indent 给，源正文自带的会叠成双倍。
---@param html string
---@return string
local function stripParagraphIndent(html)
    return (html:gsub("(<p%f[^%w][^>]*>)(.-)</p>", function(open, inner)
        local rest, n = inner, 1
        while n > 0 do
            n = 0
            for _idx, pat in ipairs(BLANKS) do
                local cut, hit = rest:gsub("^" .. pat, "")
                if hit > 0 then rest, n = cut, 1 end
            end
        end
        return open .. rest .. "</p>"
    end))
end

--- 源交来的完整文档原样返回；片段 / 纯文本套上宿主外壳。
---@param payload ChapterContentPayload|string|nil
---@param opts table|nil
---@return string html 无内容为空串
local function render(payload, opts)
    if type(payload) == "table" and payload.document then
        return payload.document
    end
    local title, content = body(payload)
    if content == "" then return "" end
    content = stripParagraphIndent(content)
    -- <title> 必须是书名：KOReader doc_props 和第三方划线插件都认这个，章名写进去会变成「夏.夏」。
    local book_title = (opts and opts.book_title)
        or (type(payload) == "table" and payload.book_title)
    if type(book_title) ~= "string" or book_title == "" then
        book_title = title
    end
    return "<!DOCTYPE html><html lang=\"zh\"><head><meta charset=\"utf-8\"/><title>"
        .. Text.xmlEscape(book_title) .. "</title><style>" .. DEFAULT_CSS
        .. "</style></head><body>" .. content .. "</body></html>"
end

--- 把章节正文落盘，先写 .part 再 rename，避免读到半截文件。
---@param path string 目标章节文件路径
---@param payload ChapterContentPayload|string|nil 源交来的正文
---@param cb fun(path: string|nil, err: string|nil) 成功回传落盘路径
---@return { cancel: fun() }|nil
local function write(path, payload, cb, opts)
    -- 源已把章节落成自己的文件（漫画 CBZ），原样登记
    if type(payload) == "table" and payload.file then
        cb(payload.file)
        return
    end
    local html = render(payload, opts)
    if html == "" then
        cb(nil, _("章节内容为空"))
        return
    end
    local dir_ok, dir_err = Paths.ensureDir(path:match("(.+)/[^/]+$"))
    if not dir_ok then cb(nil, dir_err); return end
    if type(payload) == "table" and payload.temporary then html = TEMP_MARK .. html end
    local tmp = path .. ".part"
    os.remove(tmp)
    local f, err = io.open(tmp, "wb")
    if not f then cb(nil, err or _("无法写入章节")); return end
    local completed = false
    local function finish(ok, reason)
        if completed then return end
        completed = true
        local closed, close_err = f:close()
        if not closed then ok, reason = false, reason or close_err end
        if not ok then
            os.remove(tmp)
            cb(nil, reason or _("无法写入章节"))
            return
        end
        -- Same-directory rename replaces the old cache atomically on supported targets.
        -- Deleting path first turns a transient write/rename failure into data loss.
        if not os.rename(tmp, path) then
            os.remove(tmp)
            cb(nil, _("无法保存章节文件"))
            return
        end
        local attr = lfs.attributes(path)
        if attr then
            cacheReady(path, {
                signature = tostring(attr.size or "") .. ":" .. tostring(attr.modification or ""),
                ready = not Text.hasRemoteImageSrc(html) and html:sub(1, #TEMP_MARK) ~= TEMP_MARK,
            })
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
        UIManager:nextTick(require("ui.guard").wrap("chapter write", writeNext))
    end
    UIManager:nextTick(require("ui.guard").wrap("chapter write", writeNext))
    return { cancel = function()
            if completed then return end
            completed = true
            pcall(function() f:close() end)
            os.remove(tmp)
        end }
end

--- 章节 HTML / 纯文本大致字数（去标签后的 UTF-8 字符数），给全书页码估算用。
---@param payload ChapterContentPayload|string|nil
---@return integer
local function payloadWords(payload)
    local html
    if type(payload) == "string" then
        html = payload
    elseif type(payload) == "table" then
        if payload.file then return 0 end -- 漫画等二进制不算字
        html = payload.document or payload.html or payload.text or ""
    else
        return 0
    end
    local plain = require("utils.text").stripHtml(html)
    if plain == "" then return 0 end
    -- 按 UTF-8 字符计：汉字一字符，ASCII 一字符；不追求语言学精度。
    local n, i = 0, 1
    while i <= #plain do
        local c = plain:byte(i)
        if c < 128 then i = i + 1
        elseif c < 224 then i = i + 2
        elseif c < 240 then i = i + 3
        else i = i + 4 end
        n = n + 1
    end
    return n
end

--- 确保第 idx 章正文已在本地：已就绪则直接用，否则拉正文并落盘。
---@param identity BookIdentity
---@param toc BookChapter[] 完整目录
---@param idx number 章节序号，必须落在 toc 范围内
---@param ops table 至少含 fetchContent，可选 persist_book
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function ensure(identity, toc, idx, ops, cb)
    local path = Paths.chapterPath(identity.stable_id, idx, identity.source_id)
    if not ops.volatile and chapterReady(path) then
        -- 已缓存但目录还没字数：补一次，估页码越读越准。
        local item = toc[idx]
        if item and not (tonumber(item.words) and tonumber(item.words) > 0) then
            local f = io.open(path, "rb")
            if f then
                local html = f:read("*a"); f:close()
                local words = payloadWords(html)
                if words > 0 then
                    require("source.toc").setWords(identity.source_id, identity.stable_id, idx, words)
                    item.words = words
                end
            end
        end
        cb(path)
        return
    end
    local item = assert(toc[idx], "invalid chapter toc")
    return ops.fetchContent(identity, item, function(payload, err)
        if not payload then cb(nil, err or _("章节下载失败")); return end
        write(path, payload, function(ok_path, write_err)
            if ok_path then
                local words = payloadWords(payload)
                if words > 0 then
                    require("source.toc").setWords(identity.source_id, identity.stable_id, idx, words)
                    item.words = words
                end
            end
            cb(ok_path, write_err)
        end, { book_title = ops.book_title })
    end)
end

--- 按章打开：拉目录 → 选章 → 落盘正文 → 登记路径；可取消。
---@param source BookSource
---@param identity BookIdentity
---@param book Book
---@param opts table|nil
---@param ops { loadToc: ChapterLoadToc, fetchContent: ChapterFetchContent, progress: fun(step: integer)|nil, book_title?: string }
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }
function Chapter.openAsync(source, identity, book, opts, ops, cb)
    opts = opts or {}
    ops.book_title = ops.book_title or (book and book.title)
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
                    idx = math.floor(Progress.clampFraction(pos.fraction) * #toc) + 1
                end
            end
            idx = math.max(1, math.min(#toc, idx or 1))
            run(function(done)
                return ensure(identity, toc, idx, ops, done)
            end, function(path, e)
                if not path then cb(nil, e); return end
                path = variant(identity, idx, path)
                progress(3)
                local ok, db_err = require("book.store").touch(path, identity, {
                    chapter_idx = idx,
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
    return { cancel = function()
            cancelled = true
            local job = active and active.job
            active = nil
            if job and job.cancel then
                job.cancel()
            end
        end }
end

--- 带进度对话框的按章打开：本地命中快开；否则联网准备。
---@param source BookSource
---@param identity BookIdentity
---@param book Book
---@param opts table|nil
---@param ops {
---   loadToc: ChapterLoadToc,
---   fetchContent: ChapterFetchContent,
---   progress: fun(step: number)|nil,
--- }
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }
function Chapter.openWithUi(source, identity, book, opts, ops, cb)
    opts = opts or {}
    local cancelled = false
    local job, dialog

    local local_path, local_idx = existingLocalPath(identity, opts, ops)
    if local_path then
        local_path = variant(identity, local_idx, local_path)
        local touched, touch_err = require("book.store").touch(local_path, identity, {
            chapter_idx = local_idx,
        })
        -- 本地命中直接交付。不要在切章时再启动后台 openAsync：它会重复读目录、
        -- 扫描/改写整份 HTML，并把这些同步工作塞回 UI 线程，抵消快开收益。
        -- 但身份登记不能省：旧缓存可能早于 chapters 表，ReaderReady 只按路径精确查库。
        require("ui/uimanager"):nextTick(require("ui.guard").wrap("chapter callback", function()
            if not cancelled then cb(touched and local_path or nil, touch_err) end
        end))
        return { cancel = function()
                cancelled = true
            end }
    end

    --- 关掉进度对话框并置空句柄；重复调用无副作用。
    --- 先置空句柄，close_callback 据此不把正常结束当成用户取消。
    local function closeDialog()
        if not dialog then return end
        local current = dialog
        dialog = nil
        current:close()
    end
    if not require("ui/network/manager"):isConnected() then
        require("ui/uimanager"):nextTick(require("ui.guard").wrap("chapter callback", function()
            if not cancelled then cb(nil, _("网络不可用，请先连接 Wi-Fi")) end
        end))
        return { cancel = function() cancelled = true end }
    end
    require("ui/uimanager"):nextTick(require("ui.guard").wrap("chapter open", function()
        if cancelled then
            return
        end
        local function userCancel()
            if cancelled then return end
            cancelled = true
            dialog = nil
            if job and job.cancel then job.cancel() end
            cb(nil, _("已取消"))
        end
        -- closeDialog 先置空句柄再关窗；close_callback 见到句柄仍在即用户关的（取消键 / 点外 / 返回键）。
        dialog = require("ui.themes.widgets.progress_dialog"):new{
            -- 冷启动打开时 identity.book 可能还没有，不能直接取 book.title。
            title = book and book.title or identity.stable_id,
            on_cancel = userCancel,
            close_callback = function()
                if dialog then userCancel() end
            end,
        }
        dialog:show()
        dialog:set(_("正在准备章节…"))
        ops.progress = function(step)
            if dialog then
                dialog:set(_("正在准备章节…"), step * 25)
            end
        end
        job = Chapter.openAsync(source, identity, book, opts, ops, function(path, err)
            closeDialog()
            require("ui/uimanager"):nextTick(require("ui.guard").wrap("chapter callback", function()
                if not cancelled then cb(path, err) end
            end))
        end)
    end))
    return { cancel = function()
            cancelled = true
            if job then
                job.cancel()
            end
            closeDialog()
        end }
end

--- 后台预取章节：已有文件跳过，逐章落盘并统计成功/失败。
---@param identity BookIdentity
---@param book Book|nil
---@param toc BookChapter[]
---@param from_idx integer 当前章序号（预取 from_idx+1 …）
---@param count integer 预取章数
---@param ops {
---   fetchContent: ChapterFetchContent,
---   progress: fun(done: integer, total: integer)|nil,
---   volatile: boolean|nil,
---   interval_seconds: number|nil,
---   persist_book: boolean|nil,
--- }
---@param cb fun(cached: integer, total: integer, failed: integer, err: any, failed_idx: integer[]|nil)|nil 完成统计（failed_idx：失败章节序号）
---@return { cancel: fun() }
function Chapter.prefetchAsync(identity, book, toc, from_idx, count, ops, cb)
    from_idx = tonumber(from_idx) or 0
    count = tonumber(count) or 0
    local cancelled = false
    local active
    local cached_count, failed_count = 0, 0
    local failed_idx = {}
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
        require("ui/uimanager"):nextTick(require("ui.guard").wrap("chapter callback", function()
            if not cancelled and cb then cb(0, 0, 0) end
        end))
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
            UIManager:scheduleIn(interval, require("ui.guard").wrap("chapter prefetch", nextIndex))
        else
            UIManager:nextTick(require("ui.guard").wrap("chapter prefetch", nextIndex))
        end
    end
    local function failed(err, idx)
        failed_count = failed_count + 1
        failed_idx[#failed_idx + 1] = idx
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
            if cb then cb(cached_count, #indices, failed_count, last_error, failed_idx) end
            return
        end
        local path = Paths.chapterPath(identity.stable_id, idx, identity.source_id)
        if not ops.volatile and chapterReady(path) then
            cached_count = cached_count + 1
            report()
            require("ui/uimanager"):nextTick(require("ui.guard").wrap("chapter prefetch", nextIndex))
            return
        end
        local item = toc[idx]
        if not item then
            failed(_("章节信息缺失") .. " #" .. tostring(idx), idx)
            return
        end
        active = ops.fetchContent(identity, item, function(payload, err)
            if cancelled then return end
            active = nil
            if not payload then
                failed(err or (_("章节内容获取失败") .. " #" .. tostring(idx)), idx)
                return
            end
            active = write(path, payload, function(wpath, write_err)
                active = nil
                if cancelled then return end
                if not wpath then
                    failed(write_err or (_("章节保存失败") .. " #" .. tostring(idx)), idx)
                    return
                end
                local store_opts = { chapter_idx = idx }
                if ops.persist_book ~= false then store_opts.book = book end
                local touched, touch_err = require("book.store").touch(wpath, identity, store_opts)
                if not touched then
                    failed(touch_err, idx)
                    return
                end
                cached_count = cached_count + 1
                report()
                continueNext()
            end, { yield_write = true, book_title = book and book.title })
        end)
    end

    if require("ui/network/manager"):isConnected() then
        require("ui/uimanager"):nextTick(require("ui.guard").wrap("chapter prefetch", nextIndex))
    else
        require("ui/uimanager"):nextTick(require("ui.guard").wrap("chapter callback", function()
            if not cancelled and cb then cb(0, #indices, #indices, _("网络不可用，请先连接 Wi-Fi")) end
        end))
    end
    return { cancel = function()
            cancelled = true
            local job = active
            active = nil
            if job and job.cancel then job.cancel() end
        end }
end

--- 章节缓存范围：从当前阅读章起缓存 count 章（缺省到结尾）。
--- 当前章取 chapter_idx，没有则按全书 fraction 折算，再没有就是第 1 章。
---@class ChapterCacheRange
---@field chapter_idx integer|nil
---@field fraction number|nil
---@field count integer|nil

--- 缓存范围 → prefetchAsync 的 (from_idx, count)。range 为 nil 即全本。
--- 起点在目录到手后才折算：进度可能只有比例，目录长度要等拉到才知道。
---@param toc BookChapter[]
---@param range ChapterCacheRange|nil
---@return integer from_idx 跳过的章数
---@return integer count
function Chapter.cacheRange(toc, range)
    if not range then return 0, #toc end
    local idx = tonumber(range.chapter_idx) or math.floor((tonumber(range.fraction) or 0) * #toc) + 1
    idx = math.max(1, math.min(#toc, idx))
    return idx - 1, range.count or (#toc - idx + 1)
end

--- 缓存章节正文（全本或 range 指定的一段）；目录只拉一次，正文按序下载并返回部分成功统计。
---@param source BookSource 提供 loadTocAsync
---@param identity BookIdentity
---@param fetchContent ChapterFetchContent
---@param on_progress fun(done: integer, total: integer)|nil
---@param cb fun(ok: boolean, cached: integer, err: string|nil, total: integer, failed: integer, failed_idx: integer[]|nil)
---@param interval_seconds number|nil 两次正文请求的间隔，缺省 1.5；风控严的源传更大值
---@param range ChapterCacheRange|nil 缺省全本
---@return { cancel: fun() }
function Chapter.cacheAllAsync(source, identity, fetchContent, on_progress, cb, interval_seconds, range)
    local cancelled, active = false, nil
    active = source:loadTocAsync(identity, function(toc, err)
        if cancelled then return end
        if not toc then cb(false, 0, err or _("章节列表为空"), 0, 0); return end
        local from_idx, count = Chapter.cacheRange(toc, range)
        active = Chapter.prefetchAsync(identity, nil, toc, from_idx, count, {
            fetchContent = fetchContent,
            persist_book = false,
            progress = on_progress,
            -- 全本缓存让服务端有喘息时间；阅读期预取仍保持无间隔。
            interval_seconds = interval_seconds or 1.5,
        }, function(cached, total, failed, last_err, failed_idx)
            if not cancelled then
                cb(failed == 0, cached, last_err, total, failed, failed_idx)
            end
        end)
    end)
    return { cancel = function()
            cancelled = true
            if active and active.cancel then active.cancel() end
        end }
end

--- 带 VIP 章的源取正文：成功记「已购」；open（用户点开的章）遇到没买的 VIP 章不报错，
--- 记「未购」并给一页临时提示文档（不当缓存，买了再开会重新拉）。预取 / 整本缓存传 open = false，照常失败。
---@param source BookSource
---@param content_async fun(book_id: string, chapter_id: string, cb: fun(text: string|nil, err: string|nil, kind: "unpaid"|nil)): table|nil
---@param open boolean
---@return ChapterFetchContent
function Chapter.vipFetcher(source, content_async, open)
    local Toc = require("source.toc")
    return function(identity, chapter, done)
        return content_async(identity.stable_id, chapter.uid, function(text, err, kind)
            if text then
                if chapter.vip then Toc.markPaid(source.id, identity.stable_id, chapter.uid, true) end
                done({ title = chapter.title, html = Text.chapterHtml(chapter.title, text) })
            elseif open and kind == "unpaid" then
                Toc.markPaid(source.id, identity.stable_id, chapter.uid, false)
                local notice = string.format(_("这是 VIP 章节，你还没有购买。\n请先在%s购买本章，再回来阅读。"), source.name)
                done({ title = chapter.title, html = Text.chapterHtml(chapter.title, notice), temporary = true })
            else
                done(nil, err)
            end
        end)
    end
end

return Chapter
