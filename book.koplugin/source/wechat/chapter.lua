--[[--
微信读书章节正文：只走官方 App 的 /book/chapterdownload。
EPUB 是加密 zip，TXT 是 tar（bookType 与书架 format 一致）。
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
local _ = require("l10n").get("source.wechat")

local Chapter = {}

--- App 章节包：chapters 填章 uid（"0" 是整书资源：样式表、公共图片）。
--- EPUB 是加密 zip，口令在响应头 encryptKey；TXT 是未加密 tar。
---@param bookId string
---@param chapters string
---@param book_type '"epub"'|'"txt"'
---@param pick fun(files: table<string, string>): string|nil, string|nil 在子进程里从解开的 zip 取需要的那一份文本
---@param cb fun(text: string|nil, err: any)
---@return { cancel: fun() }
local function downloadPackageAsync(bookId, chapters, book_type, pick, cb)
    local job
    local call = Eink.callAsync("GET", "/book/chapterdownload", {
        raw = true,
        query = {
            bookId = bookId, chapters = chapters,
            pf = "wechat_wx-2001-android-100-weread", pfkey = "pfKey", zoneId = "1",
            bookVersion = "0", bookType = book_type, quote = "", release = "1",
            stopAutoPayWhenBNE = "1", preload = "0", preview = "0", offline = "0",
            giftPayingCard = "0", enVersion = "10.2.2", modernVersion = "10.2.2", teenmode = "0",
        },
    }, function(res, err)
        if not res then
            cb(nil, err)
            return
        end
        local body = res.body or ""
        if body:sub(258, 262) == "ustar" then
            job = Job.run(function()
                local text, terr = Package.chapterText(body, bookId, chapters)
                return { text = text, err = terr }
            end, {
                name = "weread_chapter_package",
                kind = "light",
                timeout = 60,
                on_done = function(out) cb(out.text, out.err) end,
                on_failed = function(jerr) cb(nil, tostring(jerr)) end,
                on_cancelled = function() end,
            })
            return
        end
        local key = Request.header(res, "encryptKey")
        local password = key and Package.password(Eink.credentials().vid, key)
        if not password then
            cb(nil, "chapterdownload: no encryptKey")
            return
        end
        -- 解密 + 解压是逐字节纯 Lua，放子进程；包里的图片不回传（JSON 帧装不下二进制）
        job = Job.run(function()
            local files, zerr = Package.unzip(res.body, password)
            if not files then return { err = zerr } end
            local text, perr = pick(files)
            return { text = text, err = perr }
        end, {
            name = "weread_chapter_package",
            kind = "light",
            timeout = 60,
            on_done = function(out) cb(out.text, out.err) end,
            on_failed = function(jerr) cb(nil, tostring(jerr)) end,
            on_cancelled = function() end,
        })
    end)
    return { cancel = function()
            call:cancel()
            if job then job:cancel() end
        end }
end

--- 整书样式表（章节 link 指向的 ../Styles/stylesheets.css）。
--- 包里没有就回 nil，由调用方保留原 link。
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
        return files["Styles/stylesheets.css"]
    end, function(css, err)
        if not css then logger.warn("weread stylesheet app fetch", bookId, err) end
        done(css)
    end)
end

--- 异步拉取章节正文。失败就是失败，不再改走网页阅读接口。
--- 第三个回调参数是划线 range 的坐标原文：EPUB 为包内 xhtml，TXT 为包内纯文本
--- （format 分别为 "html" / "txt"）；不能用清理或段落化后的正文，否则 range 整体偏移。
---@param bookId string
---@param chapter BookChapter
---@param cb fun(html: string|nil, err: any, range_source: string|nil, format: '"html"'|'"txt"'|nil)
---@return { cancel: fun() }
function Chapter.fetchHtmlAsync(bookId, chapter, cb)
    local uid = chapter.uid
    if type(uid) ~= "string" or uid == "" then
        cb(nil, _("章节缺少 uid"))
        return { cancel = function() end }
    end
    local book_type = chapter.format == "txt" and "txt" or "epub"
    return downloadPackageAsync(bookId, uid, book_type, function(files)
        return Package.chapterHtml(files, uid)
    end, function(text, err)
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
        cb(text, nil, text, "html")
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
    local fetch_job = Chapter.fetchHtmlAsync(bookId, chapter, function(html, err, source, format)
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
        asset_job = Assets.localizeAsync(bookId, chapter, html, reader_url, function(done)
            return fetchStyleAsync(bookId, chapter.uid, Paths.bookWorkDir(bookId, "wechat"), done)
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

return Chapter
