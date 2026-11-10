--[[--
微信读书章节正文：只走官方 App 的 /book/chapterdownload。
EPUB 使用加密 ZIP，TXT 可能以 TAR 或 ZIP 返回（bookType 与书架 format 一致）。
EPUB 章节交出服务端 XHTML 原文，除资源本地化（插图、脚注图标、整书样式表）和脚注接弹窗外不改一个字节；
不写盘、不打 EPUB。个人划线通过 bookmarklist 同步为 KOReader 原生注解。

@module koplugin.book.source.wechat.chapter
--]]

local JSON = require("json")
local logger = require("utils.log")
local Auth = require("source.wechat.auth")
local Protocol = require("source.wechat.protocol")
local Eink = require("source.wechat.eink")
local Job = require("workers.job")
local Package = require("source.wechat.package")
local Request = require("http.request")
local Assets = require("source.wechat.assets")
local Text = require("utils.text")
local Paths = require("utils.paths")
local Toc = require("source.wechat.toc")
local Client = require("source.wechat.client")
local Context = require("source.wechat.context")
local Mapper = require("source.wechat.mapper")
local _ = require("l10n").get("source.wechat")

local Chapter = {}

--- App 章节包：chapters 填章 uid（"0" 是整书资源：样式表、公共图片）。
--- EPUB 是加密 zip，口令在响应头 encryptKey；TXT 支持 tar 和 zip。
--- bookVersion 用书籍版本；-2063 按回包的新版本或刷新详情后最多重试一次。
--- opts.offline：缓存全书 / 批量预取用 1（对齐官方）；单章在线阅读用 0。
--- opts.batch：pick 返回整表，cb(result, err)；否则 cb(text, err, style)。
---@param bookId string
---@param chapters string
---@param book_type '"epub"'|'"txt"'
---@param pick fun(files: table<string, string>): any
---@param cb function
---@param opts { offline?: boolean, batch?: boolean }|nil
---@return { cancel: fun() }
local function downloadPackageAsync(bookId, chapters, book_type, pick, cb, opts)
    opts = opts or {}
    local offline = opts.offline and "1" or "0"
    local cancelled, call, job = false, nil, nil
    local download
    local function fail(err)
        if opts.batch then cb(nil, err) else cb(nil, err) end
    end
    local function fetchVersion(attempt)
        local fired = false
        local next_call = Client:bookInfoAsync(bookId, function(wire, err)
            fired = true
            if cancelled then return end
            if not wire then
                fail(err)
                return
            end
            local version = Mapper.bookVersion(wire)
            if not version then
                fail(_("缺少书籍版本"))
                return
            end
            Context.rememberBookVersion(bookId, version)
            download(attempt, version)
        end)
        if not fired then call = next_call end
    end
    download = function(attempt, version)
        local fired = false
        local next_call = Eink.callAsync("GET", "/book/chapterdownload", {
            raw = true,
            query = {
                bookId = bookId, chapters = chapters,
                pf = "wechat_wx-2001-android-100-weread", pfkey = "pfKey", zoneId = "1",
                bookVersion = version, bookType = book_type, quote = "", release = "1",
                stopAutoPayWhenBNE = "1", preload = "0", preview = "0", offline = offline,
                giftPayingCard = "0", enVersion = "10.2.2", modernVersion = "10.2.2", teenmode = "0",
            },
        }, function(res, err, meta)
            fired = true
            if cancelled then return end
            if not res and attempt == 1 and meta and meta.errcode == -2063 then
                local info = meta.body and meta.body.info
                local next_version = type(info) == "table" and tonumber(info.bookVersion)
                logger.warn("weread chapter book version expired", bookId, version, next_version)
                if next_version and next_version > 0 and next_version ~= version then
                    Context.rememberBookVersion(bookId, next_version)
                    download(2, next_version)
                else
                    fetchVersion(2)
                end
                return
            end
            if not res then
                fail(err)
                return
            end
            local body = res.body or ""
            if body:sub(258, 262) == "ustar" then
                job = Job.run(function()
                    -- tar 包通常一章；chapters 可能是 "12" 或批量串，取第一个数字 uid。
                    local uid = tostring(chapters):match("(%d+)") or chapters
                    local text, terr = Package.chapterText(body, bookId, uid)
                    return { text = text, err = terr }
                end, {
                    name = "weread_chapter_package",
                    kind = "light",
                    timeout = 60,
                    on_done = function(out)
                        if cancelled then return end
                        if opts.batch then cb(out, out.err) else cb(out.text, out.err) end
                    end,
                    on_failed = function(jerr) if not cancelled then fail(tostring(jerr)) end end,
                    on_cancelled = function() end,
                })
                return
            end
            local key = Request.header(res, "encryptKey")
            local password = key and Package.password(Eink.credentials().vid, key)
            if not password then
                fail("chapterdownload: no encryptKey")
                return
            end
            -- 解密 + 解压是逐字节纯 Lua，放子进程；包里的图片在 pick 里就地落盘（JSON 帧装不下二进制）。
            -- 样式表是文本，随章包顺手带回，避免整书 Styles/ 缺失时正文失去 text-indent。
            job = Job.run(function()
                local files, zerr = Package.unzip(body, password)
                if not files then return { err = zerr } end
                if opts.batch then
                    local payload = pick(files) or {}
                    if payload.err then return payload end
                    if payload.style == nil then payload.style = Package.pickStyle(files) end
                    return payload
                end
                local text, perr = pick(files)
                return { text = text, err = perr, style = Package.pickStyle(files) }
            end, {
                name = "weread_chapter_package",
                kind = "light",
                timeout = 60,
                on_done = function(out)
                    if cancelled then return end
                    if opts.batch then cb(out, out and out.err) else cb(out.text, out.err, out.style) end
                end,
                on_failed = function(jerr) if not cancelled then fail(tostring(jerr)) end end,
                on_cancelled = function() end,
            })
        end)
        -- 同步回调可能已经发出了重试或解包，不能拿旧请求覆盖当前句柄。
        if not fired then call = next_call end
    end
    local version = Context.bookVersion(bookId)
    if version then download(1, version) else fetchVersion(1) end
    return { cancel = function()
            cancelled = true
            if call then call:cancel() end
            if job then job:cancel() end
        end }
end

--- 批量包解出的章：key 为 uid 字符串。单章打开不经此表。
---@type table<string, { text: string, format: '"html"'|'"txt"', style: string|nil }>
local primed = {}

local function primedKey(bookId, uid)
    return bookId .. "\0" .. tostring(uid)
end

--- 把官方一批（最多 5 章 + 样式 0）打进 primed，供随后的 fetchHtmlAsync 直接取。
---@param bookId string
---@param chapters BookChapter[]
---@param opts { offline?: boolean }|nil
---@param cb fun(ok: boolean, err: any)
---@return { cancel: fun() }
function Chapter.primeBatchAsync(bookId, chapters, opts, cb)
    opts = opts or {}
    if type(chapters) ~= "table" or #chapters == 0 then
        cb(true)
        return { cancel = function() end }
    end
    local uids, book_type = {}, "epub"
    for _idx, ch in ipairs(chapters) do
        uids[#uids + 1] = ch.uid
        if ch.format == "txt" then book_type = "txt" end
    end
    local param = Package.formatChaptersParam(uids)
    return downloadPackageAsync(bookId, param, book_type, function(files)
        local work_dir = Paths.bookWorkDir(bookId, "wechat")
        Paths.ensureDir(work_dir .. "/images")
        for name, data in pairs(files) do
            local base = name:match("^Images/([^/]+)$")
            if base then
                local f = assert(io.open(work_dir .. "/images/" .. base, "wb"))
                f:write(data)
                f:close()
            end
        end
        local extracted, style = Package.extractChapters(files, bookId, uids, book_type)
        return { chapters = extracted, style = style }
    end, function(out, err)
        if not out or err then
            cb(false, err or _("下载失败"))
            return
        end
        local style = out.style
        for _idx, uid in ipairs(uids) do
            local row = out.chapters and out.chapters[tostring(uid)]
            if row and row.text then
                primed[primedKey(bookId, uid)] = {
                    text = row.text, format = row.format or "html", style = style,
                }
            end
        end
        cb(true)
    end, { offline = opts.offline == true, batch = true })
end

--- 整书样式表（章节 link 指向 Styles/stylesheets.css 或 stylesheet.css）。
--- 包里没有就回 nil；调用方可改用章包里顺手带回的样式，或注入兜底缩进。
---@param bookId string
---@param _uid string
---@param work_dir string 整书公共图（样式表里 ../Images/ 引用的背景等）落到它的 images/
---@param done fun(css: string|nil)
---@return { cancel: fun() }|nil
local function fetchStyleAsync(bookId, _uid, work_dir, done)
    Paths.ensureDir(work_dir .. "/images")
    return downloadPackageAsync(bookId, "0", "epub", function(files)
        for name, data in pairs(files) do
            local base = name:match("^Images/([^/]+)$")
            if base then
                local f = assert(io.open(work_dir .. "/images/" .. base, "wb"))
                f:write(data)
                f:close()
            end
        end
        return Package.pickStyle(files)
    end, function(css, err)
        if not css then logger.warn("weread stylesheet app fetch", bookId, err) end
        done(css)
    end)
end

--- 异步拉取章节正文。失败就是失败，不再改走网页阅读接口。
--- 第三、四个回调参数是划线 range 的坐标原文与格式：EPUB 为包内 xhtml，TXT 为包内纯文本
--- （format 分别为 "html" / "txt"）；不能用清理或段落化后的正文，否则 range 整体偏移。
--- 第五个是章包里顺带解出的样式表（有就有，没有为 nil）。
---@param bookId string
---@param chapter BookChapter
---@param cb fun(html: string|nil, err: any, range_source: string|nil, format: '"html"'|'"txt"'|nil, style: string|nil)
---@return { cancel: fun() }
function Chapter.fetchHtmlAsync(bookId, chapter, cb)
    local uid = chapter.uid
    if type(uid) ~= "string" or uid == "" then
        cb(nil, _("章节缺少 uid"))
        return { cancel = function() end }
    end
    local hit = primed[primedKey(bookId, uid)]
    if hit then
        primed[primedKey(bookId, uid)] = nil
        local text, format, style = hit.text, hit.format, hit.style
        if format == "txt" then
            cb(Text.textToBody(text), nil, text, "txt", style)
        elseif not Text.stripBom(text):find("^%s*<") then
            cb(nil, _("试读结束"))
        else
            cb(text, nil, text, "html", style)
        end
        return { cancel = function() end }
    end
    local book_type = chapter.format == "txt" and "txt" or "epub"
    return downloadPackageAsync(bookId, uid, book_type, function(files)
        if book_type == "txt" then
            -- 部分 TXT 章节以 ZIP 返回，正文条目可直接按书和章节定位。
            local text = Package.chapterZipText(files, bookId, uid)
            if not text then return nil, "zip: chapter " .. uid .. " not in package" end
            return text
        end
        return Package.chapterHtml(files, uid)
    end, function(text, err, style)
        if not text then
            logger.warn("weread chapter app fetch", bookId, chapter.idx, err)
            cb(nil, err)
            return
        end
        if book_type == "txt" then
            cb(Text.textToBody(text), nil, text, "txt")
            return
        end
        -- 付费章的包里不是 xhtml，是几百字试读片段。官方阅读器这时开的是购买页，标题「试读结束」。
        if not Text.stripBom(text):find("^%s*<") then
            cb(nil, _("试读结束"))
            return
        end
        cb(text, nil, text, "html", style)
    end)
end

--- 把脚注 aside 块放到 body 末尾（空块原样返回）。
--- 必须带 ``epub:type="footnote"``：KOReader 默认「页内 EPUB 脚注」靠它抽到当前页底部；脚注弹窗也认。
--- 不加外层样式 div：页内脚注把 aside 抽走后，空壳分割线会留在章末。
---@param html string
---@param block string
---@return string
local function appendBlock(html, block)
    if block == "" then return html end
    block = block .. "\n"
    local last = html:match(".*()</body>")
    if not last then return html .. block end
    return html:sub(1, last - 1) .. block .. html:sub(last)
end

--- 原书脚注是 ``<img class="qqreader-footnote" alt="注文">``，注文只在 alt 里，点了没东西可弹。
--- 图标原样包进 noteref 链接，注文放进 body 末尾的 footnote aside，交给 KOReader（页底或弹窗由设置决定）。
--- 不加 ``<p>``、不动正文文字：段落序号与字偏移不变，划线 range 照旧对得上。
--- 图标尺寸写成行内 style：整书样式表拉取失败 / 缺规则时 CRE 会按 PNG 原始像素×DPI 画成两行高的大方块。
local FOOTNOTE_STYLE = "height:0.8em;width:auto;vertical-align:super;border:0"
local function iconSized(tag)
    return (tag:gsub('%sstyle="[^"]*"', ""):gsub("%s*/?>$", ' style="' .. FOOTNOTE_STYLE .. '" />'))
end
---@param html string
---@return string
local function linkFootnotes(html)
    if not html:find("qqreader-footnote", 1, true) then return html end
    local notes = {}
    html = html:gsub("<img%s[^>]*>", function(tag)
        local class = tag:match('class="([^"]*)"') or ""
        local alt = tag:match('alt="([^"]*)"') or ""
        if not class:find("qqreader-footnote", 1, true) then return nil end
        tag = iconSized(tag)
        if alt == "" then return tag end
        notes[#notes + 1] = alt
        local n = #notes
        return string.format('<a href="#wr-fn%d" id="wr-fnref%d" epub:type="noteref">%s</a>', n, n, tag)
    end)
    if #notes == 0 then return html end
    local asides = {}
    for i, alt in ipairs(notes) do
        -- alt 已是属性转义过的文本，直接当元素内容合法。
        asides[i] = string.format(
            '<aside id="wr-fn%d" epub:type="footnote">[%d] %s <a href="#wr-fnref%d">↩</a></aside>',
            i, i, alt, i)
    end
    return appendBlock(html, table.concat(asides, "\n"))
end

--- 原书链接带原文件名（``part0012.html#note_1``、``../Text/zhushi.xhtml#zhu116``），章节落盘后文件名变了，
--- KOReader 报「无效或外部链接」。锚点就在本章文档里的，改写成纯 ``#锚点``；跨章的留给 linkCrossNotes。
---@param html string
---@return string
local function localizeAnchors(html)
    return (html:gsub('href="([^"#:]+)#([^"]+)"', function(_file, frag)
        if html:find('id="' .. frag .. '"', 1, true) or html:find('name="' .. frag .. '"', 1, true) then
            return 'href="#' .. frag .. '"'
        end
        return nil
    end))
end

--- 注释章里「锚点 id → 注文」：``<p class="noteContent"><a id="zhu116">[116]</a>注文</p>``。
--- 注文保留原样转义（不解实体），直接当元素内容合法。
---@param html string
---@return table<string, string>
local function noteTexts(html)
    local map = {}
    for para in html:gmatch("<p[%s>].-</p>") do
        local id = para:match('<a[^>]-id="([^"]+)"')
        local text = id and Text.trim((para:gsub("<[^>]+>", ""):gsub("^%s*%[%d+%]", "")))
        if text and text ~= "" then map[id] = text end
    end
    return map
end

Chapter._noteTexts = noteTexts

--- 注释章按目录标题认：标题带「注」（注释 / 注解 / 脚注 / 尾注）。
---@param bookId string
---@return string[] uids
local function noteChapterUids(bookId)
    local uids = {}
    for _idx, ch in ipairs(Toc.read("wechat", bookId) or {}) do
        if tostring(ch.title or ""):find("注", 1, true) then uids[#uids + 1] = ch.uid end
    end
    return uids
end

local note_files = {}

--- 注释章注文落盘在书工作目录：重启后不必再下一次加密包（下载 + 逐字节解密很慢）。只存取到的，没取到的不落盘。
---@param bookId string
---@return string
local function notesPath(bookId)
    return Paths.bookWorkDir(bookId, "wechat") .. "/notes.json"
end

---@param bookId string
---@return table<string, table<string, string>>
local function loadNotes(bookId)
    local f = io.open(notesPath(bookId), "rb")
    if not f then return {} end
    local data = f:read("*a")
    f:close()
    local ok, map = pcall(JSON.decode, data)
    return ok and type(map) == "table" and map or {}
end

---@param bookId string
---@param base string
---@param map table<string, string>
local function saveNotes(bookId, base, map)
    local all = loadNotes(bookId)
    all[base] = map
    local f = assert(io.open(notesPath(bookId), "wb"))
    f:write(JSON.encode(all))
    f:close()
end

--- 跨章链接（本章里找不到锚点）的目标文件 → 在注释章里取注文，做成脚注弹窗；取不到的去掉链接壳只留文字。
--- 每个目标文件在内存里只取一次（书内常驻，注释章通常很小）。
---@param bookId string
---@param html string
---@param cb fun(html: string)
---@return { cancel: fun() }
local function linkCrossNotes(bookId, html, cb)
    local pending, order = {}, {}
    for file in html:gmatch('<a%s[^>]-href="([^"#:]+)#[^"]+"') do
        local base = Text.basename(file)
        if not pending[base] then
            pending[base] = true
            order[#order + 1] = base
        end
    end
    local cancelled, job = false, nil
    local uids = noteChapterUids(bookId)
    local function finish()
        local notes = {}
        html = html:gsub('<a(%s[^>]-)href="([^"#:]+)#([^"]+)"([^>]*)>(.-)</a>', function(pre, file, frag, post, inner)
            local text = (note_files[bookId .. "\0" .. Text.basename(file)] or {})[frag]
            inner = inner:gsub("<img%s[^>]*>", iconSized)
            if not text then return inner end
            notes[#notes + 1] = { text = text, label = Text.trim((inner:gsub("<[^>]+>", ""))) }
            return string.format('<a%sid="wr-ntref%d" href="#wr-nt%d" epub:type="noteref"%s>%s</a>', pre, #notes, #notes, post, inner)
        end)
        local asides = {}
        for i, note in ipairs(notes) do
            asides[i] = string.format(
                '<aside id="wr-nt%d" epub:type="footnote">%s %s <a href="#wr-ntref%d">↩</a></aside>',
                i, note.label, note.text, i)
        end
        cb(appendBlock(html, table.concat(asides, "\n")))
    end
    local function nextFile(i)
        if cancelled then return end
        local base = order[i]
        if not base then return finish() end
        local key = bookId .. "\0" .. base
        note_files[key] = note_files[key] or loadNotes(bookId)[base]
        if note_files[key] or #uids == 0 then
            note_files[key] = note_files[key] or {}
            return nextFile(i + 1)
        end
        local function try(n)
            if n > #uids then
                note_files[key] = {}
                return nextFile(i + 1)
            end
            job = downloadPackageAsync(bookId, uids[n], "epub", function(files)
                for name, body in pairs(files) do
                    if Text.basename(name) == base then return body end
                end
                return nil, "no " .. base
            end, function(body)
                if cancelled then return end
                if body then
                    note_files[key] = noteTexts(body)
                    saveNotes(bookId, base, note_files[key])
                    return nextFile(i + 1)
                end
                try(n + 1)
            end)
        end
        try(1)
    end
    nextFile(1)
    return { cancel = function()
            cancelled = true
            if job then job:cancel() end
        end }
end

--- 章节载荷：EPUB 是服务端 XHTML 原文（只把图片 / 样式表引用换成本地文件、脚注接上弹窗），TXT 是段落化正文。
---@param bookId string
---@param chapter BookChapter
---@param cb fun(payload: ChapterContentPayload|nil, err: any)
---@return { cancel: fun() }
function Chapter.fetchContentAsync(bookId, chapter, cb)
    if not Auth.hasSession() then
        cb(nil, _("请先扫码登录微信读书"))
        return { cancel = function() end }
    end
    local title = chapter.title or string.format(_("第 %d 章"), tonumber(chapter.idx) or 0)
    local cancelled, asset_job, note_job = false, nil, nil
    local reader_url = Protocol.readerUrl(bookId, chapter.uid)
    local fetch_job = Chapter.fetchHtmlAsync(bookId, chapter, function(html, err, source, format, style)
        if cancelled then return end
        if not html then
            logger.warn("weread chapter fetch", bookId, chapter.idx, err)
            cb(nil, err)
            return
        end
        -- 进度定位缓存写不进去（磁盘满）只影响下次进度换算，正文已到手，照常交出去。
        local cached, cache_err = require("source.wechat.progress").remember(bookId, chapter, source, format)
        if not cached then logger.warn("wechat chapter position cache failed", bookId, chapter.uid, cache_err) end
        if format == "txt" then
            -- TXT 正文不含章名（EPUB 原文自带标题），补一个，翻到新章才看得到章名。
            cb({ title = title, html = "<h1>" .. Text.xmlEscape(title) .. "</h1>" .. html })
            return
        end
        local work_dir = Paths.bookWorkDir(bookId, "wechat")
        asset_job = Assets.localizeAsync(bookId, chapter, html, reader_url, function(done)
            -- 章包里已有样式就不再打整书包；整书包才带公共背景图。
            if type(style) == "string" and style ~= "" then
                done(style)
                return { cancel = function() end }
            end
            return fetchStyleAsync(bookId, chapter.uid, work_dir, done)
        end, function(localized)
            if cancelled then return end
            note_job = linkCrossNotes(bookId, linkFootnotes(localizeAnchors(localized)), function(document)
                cb({ title = title, document = document })
            end)
        end)
    end)
    return { cancel = function()
            cancelled = true
            fetch_job:cancel()
            if asset_job then asset_job:cancel() end
            if note_job then note_job:cancel() end
        end }
end


local BATCH = 5

--- 阅读预取 / 缓存全书：按官方五章一批（chapters 带 0）。
---@param identity BookIdentity
---@param toc BookChapter[]
---@param from_idx integer
---@param count integer
---@param ops {
---   fetchContent: fun(identity: BookIdentity, chapter: BookChapter, cb: function): { cancel: fun() },
---   progress: fun(done: integer, total: integer)|nil,
---   offline: boolean|nil,
---   interval_seconds: number|nil,
---   persist_book: boolean|nil,
---   book: Book|nil,
---   reuse: (fun(path: string): boolean)|nil,
---   volatile: boolean|nil,
--- }
---@param cb fun(cached: integer, total: integer, failed: integer, err: any, failed_idx: integer[]|nil)|nil
---@return { cancel: fun() }
function Chapter.prefetchBatchedAsync(identity, toc, from_idx, count, ops, cb)
    from_idx = tonumber(from_idx) or 0
    count = tonumber(count) or 0
    local Shared = require("source.chapter")
    local lfs = require("libs/libkoreader-lfs")
    local cancelled, active = false, nil
    local cached_count, failed_count, last_error, failed_idx = 0, 0, nil, {}
    local total = 0
    if count > 0 and type(toc) == "table" then
        total = math.max(0, math.min(count, #toc - from_idx))
    end
    if total == 0 then
        require("ui/uimanager"):nextTick(require("ui.guard").wrap("chapter callback", function()
            if not cancelled and cb then cb(0, 0, 0) end
        end))
        return { cancel = function() cancelled = true end }
    end

    local offset = 0
    local interval = math.max(0, tonumber(ops.interval_seconds) or 0)
    local function soon(fn)
        local UIManager = require("ui/uimanager")
        if interval > 0 then
            UIManager:scheduleIn(interval, require("ui.guard").wrap("wechat batch", fn))
        else
            UIManager:nextTick(require("ui.guard").wrap("wechat batch", fn))
        end
    end

    local function chapterReady(chapter)
        local path = Paths.chapterPath(identity.stable_id, chapter.idx, identity.source_id)
        if ops.reuse then return ops.reuse(path) end
        local attr = lfs.attributes(path)
        return attr and attr.mode == "file" and (attr.size or 0) > 0
    end

    local function step()
        if cancelled then return end
        if offset >= total then
            if cb then cb(cached_count, total, failed_count, last_error, failed_idx) end
            return
        end
        local n = math.min(BATCH, total - offset)
        local need = {}
        for j = 1, n do
            local chapter = toc[from_idx + offset + j]
            if chapter and not chapterReady(chapter) then
                need[#need + 1] = chapter
            end
        end
        local function runSlice()
            if cancelled then return end
            active = Shared.prefetchAsync(identity, ops.book, toc, from_idx + offset, n, {
                fetchContent = ops.fetchContent,
                persist_book = ops.persist_book,
                volatile = ops.volatile,
                reuse = ops.reuse,
                interval_seconds = 0,
            }, function(cached, _t, failed, err, idxs)
                active = nil
                if cancelled then return end
                cached_count = cached_count + (cached or 0)
                failed_count = failed_count + (failed or 0)
                last_error = err or last_error
                if type(idxs) == "table" then
                    for _i, idx in ipairs(idxs) do failed_idx[#failed_idx + 1] = idx end
                end
                offset = offset + n
                if ops.progress then ops.progress(cached_count + failed_count, total) end
                soon(step)
            end)
        end
        if #need == 0 then
            runSlice()
            return
        end
        active = Chapter.primeBatchAsync(identity.stable_id, need, { offline = ops.offline == true }, function(ok, err)
            active = nil
            if cancelled then return end
            if not ok then logger.warn("weread batch prime failed", identity.stable_id, err) end
            runSlice()
        end)
    end

    if require("ui/network/manager"):isConnected() then
        soon(step)
    else
        require("ui/uimanager"):nextTick(require("ui.guard").wrap("chapter callback", function()
            if not cancelled and cb then
                cb(0, total, total, _("网络不可用，请先连接 Wi-Fi"))
            end
        end))
    end
    return { cancel = function()
            cancelled = true
            if active and active.cancel then active.cancel() end
        end }
end

--- 缓存全书（或 range）：offline=1，五章一批。
---@param source BookSource
---@param identity BookIdentity
---@param on_progress fun(done: integer, total: integer)|nil
---@param cb fun(ok: boolean, cached: integer, err: string|nil, total: integer, failed: integer, failed_idx: integer[]|nil)
---@param range table|nil
---@return { cancel: fun() }
function Chapter.cacheAllBatchedAsync(source, identity, on_progress, cb, range)
    local cancelled, active = false, nil
    active = source:loadTocAsync(identity, function(toc, err)
        if cancelled then return end
        if not toc then
            cb(false, 0, err or _("章节列表为空"), 0, 0)
            return
        end
        local Shared = require("source.chapter")
        local from_idx, count = Shared.cacheRange(toc, range)
        active = Chapter.prefetchBatchedAsync(identity, toc, from_idx, count, {
            fetchContent = function(r, chapter, done)
                return Chapter.fetchContentAsync(r.stable_id, chapter, done)
            end,
            progress = on_progress,
            offline = true,
            persist_book = false,
            -- 批次之间歇一下；批内已是一次请求。
            interval_seconds = 1.5,
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


return Chapter
