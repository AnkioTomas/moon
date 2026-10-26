--[[--
微信读书章节正文：先走 App 通道（官方客户端同款 /book/chapterdownload 加密 zip），失败再退回网页通道
（本地生成 psvts → 拉 e_0/e_1/e_3（或 t_0/t_1）→ 解码）。EPUB 章节交出服务端 XHTML 原文，除资源本地化（插图、脚注图标、
整书样式表）和脚注接弹窗外不改一个字节；
不写盘、不打 EPUB。个人划线通过 bookmarklist 同步为 KOReader 原生注解。

@module koplugin.book.source.wechat.chapter
--]]

local JSON = require("json")
local logger = require("utils.log")
local Auth = require("source.wechat.auth")
local Protocol = require("source.wechat.protocol")
local Context = require("source.wechat.context")
local Eink = require("source.wechat.eink")
local Job = require("workers.job")
local Package = require("source.wechat.package")
local Request = require("http.request")
local Assets = require("source.wechat.assets")
local Text = require("utils.text")
local Paths = require("utils.paths")
local Toc = require("source.wechat.toc")
local _ = require("gettext")

local Chapter = {}

--- e_0 回 "{}" 的重试：服务端对正常可读的章节也会偶发回空对象（同一章几秒后再拉就有正文），
--- 按指数退避重拉（0.5s 起翻倍、单次封顶 8s、加少量抖动），最多 EMPTY_RETRIES 次；仍为空才算失败。
local EMPTY_RETRIES = 10
local EMPTY_RETRY_BASE = 0.5
local EMPTY_RETRY_CAP = 8
local EMPTY_RETRY_JITTER = 0.2

--- 第 n 次重试（从 0 计）前的等待秒数。
---@param n integer
---@return number
function Chapter._retryDelay(n)
    return math.min(EMPTY_RETRY_CAP, EMPTY_RETRY_BASE * 2 ^ n) + math.random() * EMPTY_RETRY_JITTER
end

--- 延时执行；测试可替换。
---@param sec number
---@param fn fun()
function Chapter._schedule(sec, fn)
    require("ui/uimanager"):scheduleIn(sec, fn)
end

--- 请求一个正文分片端点；空对象回包（"{}"）按失败处理，交由调用方换端点重试。
--- st=0 回正文；st=1 回整书样式表（e_0/e_1/e_3 拼起来、或单独 e_2 都是同一份），实测。
---@param bookId string
---@param uid string
---@param psvts string
---@param endpoint string 正文接口路径
---@param style boolean
---@param done fun(raw: string|nil, err: any) 原始 JSON 串
---@return { cancel: fun() }|nil
local function requestShard(bookId, uid, psvts, endpoint, style, done)
    local params = Protocol.contentParams(bookId, uid, psvts, { sc = 1, style = style })
    return Auth.webPostAsync(
        "https://weread.qq.com" .. endpoint,
        JSON.encode(params),
        {
            accept = "application/json, text/plain, */*",
            content_type = "application/json;charset=UTF-8",
            headers = {
                ["Origin"] = "https://weread.qq.com",
                ["Referer"] = Protocol.readerUrl(bookId, uid),
            },
            timeout = require("http.timeout").net(3),
        },
        function(raw, err)
            if not raw then
                done(nil, err or (endpoint .. " failed"))
            elseif raw == "{}" then
                done(nil, endpoint .. " empty")
            else
                done(raw)
            end
        end
    )
end

--- App 章节包：chapters 填章 uid（"0" 是整书资源：样式表、公共图片）；包内文件经口令解开。
---@param bookId string
---@param chapters string
---@param pick fun(files: table<string, string>): string|nil, string|nil 在子进程里从解开的包取需要的那一份文本
---@param cb fun(text: string|nil, err: any)
---@return { cancel: fun() }
local function downloadPackageAsync(bookId, chapters, pick, cb)
    local job
    local call = Eink.callAsync("GET", "/book/chapterdownload", {
        raw = true,
        query = {
            bookId = bookId, chapters = chapters,
            pf = "wechat_wx-2001-android-100-weread", pfkey = "pfKey", zoneId = "1",
            bookVersion = "0", bookType = "epub", quote = "", release = "1",
            stopAutoPayWhenBNE = "1", preload = "0", preview = "0", offline = "0",
            giftPayingCard = "0", enVersion = "10.2.2", modernVersion = "10.2.2", teenmode = "0",
        },
    }, function(res, err)
        if not res then
            cb(nil, err)
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

--- 网页通道的整书样式表。
---@param bookId string
---@param uid string
---@param done fun(css: string|nil)
---@return { cancel: fun() }|nil
local function fetchWebStyleAsync(bookId, uid, done)
    return requestShard(bookId, uid, Context.reader(bookId, uid).psvts, "/web/book/chapter/e_2", true,
        function(raw, err)
            local css = raw and Protocol.decodeShards(raw)
            if not css or css:find("^%s*<") then
                logger.warn("weread stylesheet fetch", bookId, uid, err)
                done(nil)
                return
            end
            done(css)
        end)
end

--- 整书样式表（章节 link 指向的 ../Styles/stylesheets.css）：App 包优先，失败退回网页通道；
--- 都失败回 nil，由调用方保留原 link。
---@param bookId string
---@param uid string
---@param work_dir string 整书公共图（样式表里 ../Images/ 引用的背景等）落到它的 images/
---@param done fun(css: string|nil)
---@return { cancel: fun() }|nil
local function fetchStyleAsync(bookId, uid, work_dir, done)
    local web
    Paths.ensureDir(work_dir .. "/images")
    local app = downloadPackageAsync(bookId, "0", function(files)
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
        if css then
            done(css)
            return
        end
        logger.warn("weread stylesheet app fetch", bookId, err)
        web = fetchWebStyleAsync(bookId, uid, done)
    end)
    return { cancel = function()
            app:cancel()
            if web then web:cancel() end
        end }
end

--- 异步拉取章节 HTML 正文。
--- 第三个回调参数是划线 range 的坐标原文：EPUB 为解码后的完整 xhtml，TXT 为解码后的纯文本
--- （format 分别为 "html" / "txt"）；不能用清理或段落化后的正文，否则 range 整体偏移。
---@param bookId string
---@param chapter BookChapter
---@param cb fun(html: string|nil, err: any, range_source: string|nil, format: '"html"'|'"txt"'|nil)
---@return { cancel: fun() }
local function fetchWebHtmlAsync(bookId, chapter, cb)
    local uid = chapter.uid
    local cancelled = false
    local active_job
    local psvts = Context.reader(bookId, uid).psvts
    --- 中止取正文：置位取消标记并终止在途请求。
    local function cancel()
        cancelled = true
        if active_job then active_job:cancel() end
    end
    --- 以错误收尾；已取消则丢弃。
    ---@param err any 失败原因
    local function fail(err)
        if not cancelled then cb(nil, err) end
    end
    --- 取一个正文分片（st=0）；已取消则丢弃回包。
    local seq = 0
    ---@param endpoint string 正文接口路径
    ---@param done fun(raw: string|nil, err: any) 原始 JSON 串
    local function shard(endpoint, done)
        seq = seq + 1
        local mine = seq
        local handle = requestShard(bookId, uid, psvts, endpoint, false, function(raw, err)
            if not cancelled then done(raw, err) end
        end)
        -- 回调同步触发时已发出下一个请求，不能用旧句柄覆盖它（同 http/mirror）。
        if seq == mine then active_job = handle end
    end
    local function onE0(e0, e0err, tries)
        if not e0 then
            if tries < EMPTY_RETRIES and e0err == "/web/book/chapter/e_0 empty" then
                logger.dbg("weread chapter e_0 empty, retry", bookId, tries + 1)
                Chapter._schedule(Chapter._retryDelay(tries), function()
                    if cancelled then return end
                    shard("/web/book/chapter/e_0", function(raw, err) onE0(raw, err, tries + 1) end)
                end)
                return
            end
            fail(e0err)
            return
        end
        if e0:sub(1, 1) == "{" and e0:find('"bookId"', 1, true) then
            shard("/web/book/chapter/t_0", function(t0, t0err)
                if not t0 then
                    fail(t0err)
                    return
                end
                shard("/web/book/chapter/t_1", function(t1)
                    local plain, decode_err = Protocol.decodeShards(t0, t1 or "")
                    if not plain then
                        fail(decode_err or _("txt 章节解码失败"))
                    else
                        cb(Text.textToBody(plain), nil, plain, "txt")
                    end
                end)
            end)
            return
        end
        shard("/web/book/chapter/e_1", function(e1, e1err)
            if not e1 then
                fail(e1err)
                return
            end
            shard("/web/book/chapter/e_3", function(e3, e3err)
                if not e3 then
                    fail(e3err)
                    return
                end
                local xhtml, decode_err = Protocol.decodeShards(e0, e1, e3)
                if not xhtml then
                    fail(decode_err or _("章节解码失败"))
                elseif not Text.stripBom(xhtml):find("^%s*<") then
                    -- 无权阅读的付费章：服务端照样 200，回几百字纯文本试读片段（以「...」结尾）。
                    fail(_("该章需购买或付费会员卡，微信读书只返回了试读片段"))
                else
                    cb(xhtml, nil, xhtml, "html")
                end
            end)
        end)
    end
    shard("/web/book/chapter/e_0", function(e0, e0err) onE0(e0, e0err, 0) end)
    return { cancel = cancel }
end

--- 异步拉取章节 HTML 正文：App 通道优先；包解不开、付费章、TXT 书等任何失败都退回网页通道。
--- 回调约定同 fetchWebHtmlAsync。
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
    local cancelled, web = false, nil
    local app = downloadPackageAsync(bookId, uid, function(files)
        return Package.chapterHtml(files, uid)
    end, function(xhtml, err)
        if cancelled then return end
        if xhtml and Text.stripBom(xhtml):find("^%s*<") then
            cb(xhtml, nil, xhtml, "html")
            return
        end
        logger.warn("weread chapter app fetch", bookId, chapter.idx, err)
        web = fetchWebHtmlAsync(bookId, chapter, cb)
    end)
    return { cancel = function()
            cancelled = true
            app:cancel()
            if web then web:cancel() end
        end }
end

--- 把脚注 aside 块放到 body 末尾（空块原样返回），外包一层分割线 + 小号灰字。
--- 样式放外层 div 而不是 aside：脚注弹窗取的是 aside 自己的 HTML，样式写在 aside 上会连弹窗一起变小变灰。
---@param html string
---@param block string
---@return string
local function appendBlock(html, block)
    if block == "" then return html end
    block = '<div style="margin-top:2em;padding-top:0.5em;border-top:1px solid #888;font-size:0.8em;color:#555">\n'
        .. block .. "\n</div>\n"
    local last = html:match(".*()</body>")
    if not last then return html .. block end
    return html:sub(1, last - 1) .. block .. html:sub(last)
end

--- 原书脚注是 ``<img class="qqreader-footnote" alt="注文">``，注文只在 alt 里，点了没东西可弹。
--- 图标原样包进 noteref 链接，注文放进 body 末尾的 footnote aside，交给 KOReader 脚注弹窗。
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
        asides[i] = string.format('<aside id="wr-fn%d">[%d] %s <a href="#wr-fnref%d">↩</a></aside>', i, i, alt, i)
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
            asides[i] = string.format('<aside id="wr-nt%d">%s %s <a href="#wr-ntref%d">↩</a></aside>', i, note.label, note.text, i)
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
            job = downloadPackageAsync(bookId, uids[n], function(files)
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
    local fetch_job = Chapter.fetchHtmlAsync(bookId, chapter, function(html, err, _source, format)
        if cancelled then return end
        if not html then
            logger.warn("weread chapter fetch", bookId, chapter.idx, err)
            cb(nil, err)
            return
        end
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
