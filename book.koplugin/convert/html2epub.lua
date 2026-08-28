--[[--
HTML → EPUB（多章节、内嵌图片、元数据）。

设计要点：
  - 章节内容经 `get_chapter(index, chapter, cb)` 按需回调拉取，避免一次性塞入巨量 HTML。
  - 网络图片支持统一 `image_headers`，或按 URL 的 `image_headers_for(url)`。
  - 打包走子进程（utils.task），不堵 UI。
  - 逐章 / 逐图之间用 nextTick 让出事件循环。

  local Html2Epub = require("convert.html2epub")
  local job = Html2Epub.build({
      dest = "/path/book.epub",
      title = "书名",
      author = "作者",
      chapters = { { title = "第一章" }, { title = "第二章" } },
      get_chapter = function(i, ch, cb) cb(html_or_nil, err) end,
      image_headers = { Cookie = "..." },
  }, function(ok, err) end)
  job.cancel()

@module koplugin.book.convert.html2epub
--]]

local UIManager = require("ui/uimanager")
local logger = require("logger")
local Header = require("http.header")
local Text = require("utils.text")
local _ = require("gettext")

local Html2Epub = {}

------------------------------------------------------------------------
-- 小工具
------------------------------------------------------------------------

--- 粗判是否像 HTML；否则包成段落。
---@param s string|nil
---@return string
local function ensureHtmlBody(s)
    s = tostring(s or "")
    if Text.looksLikeHtml(s) then
        return s
    end
    return Text.textToBody(s)
end

--- 从 HTML body 抽出完整文档外壳。
---@param title string
---@param body string
---@return string
local function wrapXhtml(title, body)
    return string.format([[
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh">
<head>
<title>%s</title>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8"/>
<style type="text/css">
body{margin:5%%;line-height:1.8;text-align:justify;}
h1{font-size:1.5em;text-align:center;margin:2em 0 1.5em;page-break-after:avoid;}
p{text-indent:2em;margin:0.45em 0;orphans:2;widows:2;}
img{max-width:100%%;}
</style>
</head>
<body>
%s
</body>
</html>
]], Text.xmlEscape(title), body)
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

---@param data string
---@return string|nil
local function b64decode(data)
    data = tostring(data or ""):gsub("[^" .. B64 .. "=]", "")
    if data == "" then
        return nil
    end
    local ok, mime = pcall(require, "mime")
    if ok and mime and type(mime.unb64) == "function" then
        local out = mime.unb64(data)
        if type(out) == "string" and out ~= "" then
            return out
        end
    end
    local bits = data:gsub(".", function(x)
        if x == "=" then
            return ""
        end
        local f = B64:find(x, 1, true)
        if not f then
            return ""
        end
        f = f - 1
        local r = ""
        for i = 6, 1, -1 do
            r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and "1" or "0")
        end
        return r
    end)
    return bits:gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
        if #x ~= 8 then
            return ""
        end
        local c = 0
        for i = 1, 8 do
            if x:sub(i, i) == "1" then
                c = c + 2 ^ (8 - i)
            end
        end
        return string.char(c)
    end)
end

---@param bytes string
---@return string|nil ext, string|nil mime
local function sniffImage(bytes)
    if type(bytes) ~= "string" or #bytes < 3 then
        return nil
    end
    if bytes:sub(1, 3) == "\255\216\255" then
        return ".jpg", "image/jpeg"
    end
    if bytes:sub(1, 8) == "\137PNG\r\n\26\n" then
        return ".png", "image/png"
    end
    if bytes:sub(1, 6) == "GIF87a" or bytes:sub(1, 6) == "GIF89a" then
        return ".gif", "image/gif"
    end
    if bytes:sub(1, 4) == "RIFF" and bytes:sub(9, 12) == "WEBP" then
        return ".webp", "image/webp"
    end
    local lower = bytes:sub(1, 256):lower()
    if lower:find("<svg", 1, true) or lower:find("<?xml", 1, true) then
        return ".svg", "image/svg+xml"
    end
    return nil
end

---@param url string
---@return string|nil
local function extFromUrl(url)
    local path = (url or ""):match("^[^%?#]+") or url or ""
    local ext = path:match("%.([%w]+)$")
    if not ext then
        return nil
    end
    ext = "." .. ext:lower()
    local ok = {
        [".jpg"] = true,
        [".jpeg"] = true,
        [".png"] = true,
        [".gif"] = true,
        [".webp"] = true,
        [".svg"] = true,
    }
    if not ok[ext] then
        return nil
    end
    if ext == ".jpeg" then
        return ".jpg"
    end
    return ext
end

---@param ext string|nil
---@return string
local function mimeForExt(ext)
    local map = {
        [".jpg"] = "image/jpeg",
        [".jpeg"] = "image/jpeg",
        [".png"] = "image/png",
        [".gif"] = "image/gif",
        [".webp"] = "image/webp",
        [".svg"] = "image/svg+xml",
    }
    return map[ext or ""] or "application/octet-stream"
end

--- 收集 HTML 中的 img src（去重、保序）。
---@param html string
---@return string[]
local function collectImageSrcs(html)
    local list = {}
    local seen = {}
    --- 按首次出现顺序收录一个 src，空值与重复项跳过。
    ---@param src string
    local function add(src)
        src = Text.trim(src)
        if src == "" or seen[src] then
            return
        end
        seen[src] = true
        list[#list + 1] = src
    end
    for _, src in html:gmatch([[<img%s+[^>]-src%s*=%s*(["'])(.-)%1]]) do
        add(src)
    end
    -- 空白类必须写 %s：Lua 模式没有 \s，写成 \s 是「排除反斜杠和字母 s」，
    -- 于是 <img src=a.png width=10> 会被取成 "a.png width=10"，且带 s 的文件名被截断。
    for src in html:gmatch([[<img%s+[^>]-src%s*=%s*([^%s"'=<>`]+)]]) do
        add(src)
    end
    return list
end

--- 把 src 映射表应用到 HTML。
---@param html string
---@param map table<string, string>
---@return string
local function rewriteImageSrcs(html, map)
    --- 查表替换单个 src；不在映射表里的原样保留。
    ---@param src string
    ---@return string
    local function repl(src)
        return map[src] or src
    end
    html = html:gsub([[(<img%s+[^>]-src%s*=%s*)(["'])(.-)%2]], function(pre, q, src)
        return pre .. q .. repl(src) .. q
    end)
    html = html:gsub([[(<img%s+[^>]-src%s*=%s*)([^%s"'=<>`]+)]], function(pre, src)
        return pre .. repl(src)
    end)
    return html
end

------------------------------------------------------------------------
-- 打包
------------------------------------------------------------------------

---@param opts {
---   title: string,
---   author: string|nil,
---   language: string|nil,
---   identifier: string|nil,
---   chapters: { title: string, href: string, xhtml: string }[],
---   images: { href: string, mime: string, bytes: string }[],
--- }
---@param dest string
---@return boolean|nil, string|nil
local function writeEpubPackage(opts, dest)
    local Archiver = require("ffi/archiver")
    local title = opts.title or _("未命名")
    local author = opts.author or ""
    local language = opts.language or "zh"
    local identifier = opts.identifier or ("moon-html2epub-" .. tostring(os.time()))
    local chapters = opts.chapters or {}
    local images = opts.images or {}

    if #chapters == 0 then
        return nil, _("无章节内容")
    end

    local tmp = dest .. ".part"
    pcall(os.remove, tmp)
    local epub = Archiver.Writer:new{}
    if not epub:open(tmp, "epub") then
        return nil, epub.err or _("无法创建 epub")
    end

    local mtime = os.time()
    epub:setZipCompression("store")
    if not epub:addFileFromMemory("mimetype", "application/epub+zip", mtime) then
        epub:close()
        pcall(os.remove, tmp)
        return nil, epub.err or _("写入 mimetype 失败")
    end
    epub:setZipCompression("deflate")

    local container = [[
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
]]
    epub:addFileFromMemory("META-INF/container.xml", container, mtime)

    local manifest = {
        '    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
    }
    local spine = {}
    local nav = {}
    for i, ch in ipairs(chapters) do
        local id = string.format("ch%d", i)
        manifest[#manifest + 1] = string.format(
            '    <item id="%s" href="%s" media-type="application/xhtml+xml"/>',
            id, ch.href
        )
        spine[#spine + 1] = string.format('    <itemref idref="%s"/>', id)
        if ch.toc ~= false then
            nav[#nav + 1] = string.format([[
    <navPoint id="n%d" playOrder="%d">
      <navLabel><text>%s</text></navLabel>
      <content src="%s"/>
    </navPoint>]], #nav + 1, #nav + 1, Text.xmlEscape(ch.title or id), ch.href)
        end
    end
    for i, img in ipairs(images) do
        local id = string.format("img%d", i)
        manifest[#manifest + 1] = string.format(
            '    <item id="%s" href="%s" media-type="%s"/>',
            id, img.href, img.mime
        )
    end

    local creator = ""
    if author ~= "" then
        creator = string.format("\n    <dc:creator>%s</dc:creator>", Text.xmlEscape(author))
    end

    local opf = string.format([[
<?xml version="1.0" encoding="UTF-8"?>
<package version="2.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>%s</dc:title>%s
    <dc:language>%s</dc:language>
    <dc:identifier id="bookid">%s</dc:identifier>
  </metadata>
  <manifest>
%s
  </manifest>
  <spine toc="ncx">
%s
  </spine>
</package>
]], Text.xmlEscape(title), creator, Text.xmlEscape(language), Text.xmlEscape(identifier),
        table.concat(manifest, "\n"), table.concat(spine, "\n"))
    epub:addFileFromMemory("OEBPS/content.opf", opf, mtime)

    local ncx = string.format([[
<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="%s"/></head>
  <docTitle><text>%s</text></docTitle>
  <navMap>
%s
  </navMap>
</ncx>
]], Text.xmlEscape(identifier), Text.xmlEscape(title), table.concat(nav, "\n"))
    epub:addFileFromMemory("OEBPS/toc.ncx", ncx, mtime)

    for _i, ch in ipairs(chapters) do
        if not epub:addFileFromMemory("OEBPS/" .. ch.href, ch.xhtml, mtime) then
            epub:close()
            pcall(os.remove, tmp)
            return nil, epub.err or _("写入章节失败")
        end
    end
    for _i, img in ipairs(images) do
        if not epub:addFileFromMemory("OEBPS/" .. img.href, img.bytes, mtime) then
            epub:close()
            pcall(os.remove, tmp)
            return nil, epub.err or _("写入图片失败")
        end
    end

    epub:close()
    pcall(os.remove, dest)
    if not os.rename(tmp, dest) then
        pcall(os.remove, tmp)
        return nil, _("写入 epub 失败")
    end
    return true
end

------------------------------------------------------------------------
-- 公开 API
------------------------------------------------------------------------

--- 异步构建 EPUB。
---
--- opts.chapters 只放轻量元数据（至少 title）。正文用 get_chapter 按需取。
--- 若某章自带 chapter.html，则跳过对该章的 get_chapter。
---
---@param opts {
---   dest: string,
---   title: string,
---   author: string|nil,
---   language: string|nil,
---   identifier: string|nil,
---   chapters: { title: string, html: string|nil, toc: boolean|nil }[],
---   get_chapter: (fun(index: number, chapter: table, cb: fun(html: string|nil, err: any)))|nil,
---   image_headers: table|nil,
---   image_headers_for: (fun(url: string): table|nil)|nil,
---   image_timeout: number|nil,
---   on_progress: (fun(ev: table))|nil,
--- }
---@param cb fun(ok: boolean|nil, err: any)
---@return { cancel: fun() }
function Html2Epub.build(opts, cb)
    opts = opts or {}
    if type(cb) ~= "function" then
        error("html2epub.build: cb must be function", 2)
    end

    local dest = opts.dest
    local chapters_meta = opts.chapters
    if type(dest) ~= "string" or dest == "" then
        UIManager:nextTick(function() cb(nil, _("无效路径")) end)
        return { cancel = function() end }
    end
    if type(chapters_meta) ~= "table" or #chapters_meta == 0 then
        UIManager:nextTick(function() cb(nil, _("无章节")) end)
        return { cancel = function() end }
    end

    local cancelled = false
    local active_job
    local pack_task
    local book_title = opts.title or _("未命名")
    local total = #chapters_meta
    local out_chapters = {}
    ---@type table<string, { href: string, mime: string, bytes: string }>
    local image_by_key = {}
    local image_order = {}
    local img_seq = 0

    --- 上报进度事件；已取消或调用方没给 on_progress 时静默丢弃。
    ---@param ev table 形如 { phase = "chapter"|"image"|"pack", index, total, title, url }
    local function emit(ev)
        if cancelled or type(opts.on_progress) ~= "function" then
            return
        end
        opts.on_progress(ev)
    end

    --- 终止构建并以错误回调；置位 cancelled 保证 cb 只触发一次。
    ---@param err any 失败原因
    local function fail(err)
        if cancelled then
            return
        end
        cancelled = true
        cb(nil, err)
    end

    --- 计算某张图片的下载请求头：按 URL 定制的头覆盖全局 image_headers。
    ---@param url string 图片地址
    ---@return table<string, string>
    local function headersFor(url)
        local extra = opts.image_headers
        if type(opts.image_headers_for) == "function" then
            local per = opts.image_headers_for(url)
            if type(per) == "table" then
                extra = Header.merge(per, extra)
            end
        end
        return Header.forDownload(extra)
    end

    --- 把图片字节登记进 epub 资源表并分配 images/img_NNN.ext 路径。
    --- 扩展名优先按字节魔数嗅探，嗅不出才用 prefer_ext 或 URL 后缀，都没有则落到 .bin。
    ---@param key string 去重键（原始 src）
    ---@param bytes string 图片字节
    ---@param prefer_ext string|nil 备选扩展名（含点）
    ---@return string href 章节 XHTML 中应引用的相对路径
    local function rememberImage(key, bytes, prefer_ext)
        local existing = image_by_key[key]
        if existing then
            return existing.href
        end
        local ext, mime = sniffImage(bytes)
        if not ext then
            ext = prefer_ext or extFromUrl(key)
            mime = mimeForExt(ext)
        end
        if not ext then
            ext = ".bin"
            mime = "application/octet-stream"
        end
        img_seq = img_seq + 1
        local href = string.format("images/img_%03d%s", img_seq, ext)
        local item = { href = href, mime = mime, bytes = bytes }
        image_by_key[key] = item
        image_order[#image_order + 1] = item
        return href
    end

    --- 取回单张图片并登记：data: URI 就地解码，本地路径直接读文件，http(s) 走异步下载。
    --- 取不到不算致命错误——done(nil) 表示保留原 src 不重写。已取消时不回调。
    ---@param src string 原始 img src
    ---@param done fun(href: string|nil) 成功给 epub 内相对路径，失败给 nil
    local function loadOneImage(src, done)
        if cancelled then
            return
        end
        if image_by_key[src] then
            done(image_by_key[src].href)
            return
        end

        if src:sub(1, 5) == "data:" then
            local mime, b64 = src:match("^data:([^;,]+);base64,(.+)$")
            if not b64 then
                done(nil)
                return
            end
            local bytes = b64decode(b64)
            if not bytes then
                done(nil)
                return
            end
            local prefer
            if mime == "image/jpeg" then prefer = ".jpg"
            elseif mime == "image/png" then prefer = ".png"
            elseif mime == "image/gif" then prefer = ".gif"
            elseif mime == "image/webp" then prefer = ".webp"
            elseif mime == "image/svg+xml" then prefer = ".svg"
            end
            done(rememberImage(src, bytes, prefer))
            return
        end

        if src:sub(1, 7) ~= "http://" and src:sub(1, 8) ~= "https://" then
            local f = io.open(src, "rb")
            if not f then
                logger.warn("html2epub local image miss", src)
                done(nil)
                return
            end
            local bytes = f:read("*a")
            f:close()
            if type(bytes) ~= "string" or bytes == "" then
                done(nil)
                return
            end
            done(rememberImage(src, bytes, extFromUrl(src)))
            return
        end

        emit({ phase = "image", url = src, index = #image_order + 1 })
        local Request = require("http.request")
        active_job = Request.get(src, {
            headers = headersFor(src),
            timeout = opts.image_timeout or 60,
            accept = "image/*,*/*",
        }, function(body, err)
            active_job = nil
            if cancelled then
                return
            end
            if not body or body == "" then
                logger.warn("html2epub image fail", src, err)
                done(nil)
                return
            end
            done(rememberImage(src, body, extFromUrl(src)))
        end)
    end

    --- 逐张取回章节内图片（串行，每张之间让出一次事件循环），再重写 src 为 epub 内路径。
    ---@param html string 章节 HTML
    ---@param done fun(html: string) 重写后的 HTML；取不到的图片保持原 src
    local function embedImages(html, done)
        local srcs = collectImageSrcs(html)
        if #srcs == 0 then
            done(html)
            return
        end
        local map = {}
        local i = 0
        --- 处理下一张图片，全部处理完则交付重写后的 HTML。
        local function nextImg()
            if cancelled then
                return
            end
            i = i + 1
            if i > #srcs then
                done(rewriteImageSrcs(html, map))
                return
            end
            local src = srcs[i]
            loadOneImage(src, function(href)
                if href then
                    map[src] = href
                end
                UIManager:nextTick(nextImg)
            end)
        end
        nextImg()
    end

    --- 全部章节就绪后打包 epub：zip 写入放进 Task 子进程，避免阻塞 UI。
    --- 子进程通过管道回传 "ok" 或 "err:<原因>"，据此调用外层 cb。
    local function packAndFinish()
        if cancelled then
            return
        end
        emit({ phase = "pack", index = total, total = total })
        local images = image_order
        local chapters = out_chapters
        local pack_opts = {
            title = book_title,
            author = opts.author,
            language = opts.language,
            identifier = opts.identifier,
            chapters = chapters,
            images = images,
        }
        local Task = require("utils.task")
        pack_task = Task.run(function(pid, write_fd, read_fd)
            local ok, err = writeEpubPackage(pack_opts, dest)
            local payload = ok and "ok" or ("err:" .. tostring(err or "pack failed"))
            local ffiUtil = require("ffi/util")
            if type(write_fd) == "function" then
                write_fd(payload)
            else
                ffiUtil.writeToFD(write_fd, payload, true)
            end
            if read_fd and type(read_fd) ~= "function" then
                ffiUtil.closeFD(read_fd)
            end
        end, {
            pipe = true,
            on_done = function(raw)
                pack_task = nil
                if cancelled then
                    return
                end
                if raw == "ok" then
                    cb(true)
                    return
                end
                local msg = type(raw) == "string" and raw:match("^err:(.*)$") or nil
                cb(nil, msg or raw or _("写入 epub 失败"))
            end,
            on_failed = function(err)
                pack_task = nil
                if not cancelled then
                    cb(nil, err or _("写入 epub 失败"))
                end
            end,
        })
    end

    --- 处理第 index 章（取正文 → 内嵌图片 → 生成 XHTML），越界则转入打包。
    ---@param index number 章节序号，从 1 起
    local function processChapter(index)
        if cancelled then
            return
        end
        if index > total then
            packAndFinish()
            return
        end

        local meta = chapters_meta[index] or {}
        local title = meta.title or string.format(_("第 %d 章"), index)
        emit({ phase = "chapter", index = index, total = total, title = title })

        --- 收到本章正文后补全 html 骨架、内嵌图片并追加到章节表；无正文视为致命错误。
        ---@param html string|nil 章节 HTML
        ---@param err any 取正文失败的原因
        local function onHtml(html, err)
            if cancelled then
                return
            end
            if not html then
                fail(err or string.format(_("章节 %d 无内容"), index))
                return
            end
            html = ensureHtmlBody(html)
            embedImages(html, function(body)
                if cancelled then
                    return
                end
                local href = string.format("chapter_%03d.xhtml", index)
                out_chapters[#out_chapters + 1] = {
                    title = title,
                    toc = meta.toc,
                    href = href,
                    xhtml = wrapXhtml(title, body),
                }
                UIManager:nextTick(function()
                    processChapter(index + 1)
                end)
            end)
        end

        if type(meta.html) == "string" then
            UIManager:nextTick(function()
                onHtml(meta.html)
            end)
            return
        end

        if type(opts.get_chapter) ~= "function" then
            fail(_("缺少 get_chapter"))
            return
        end

        local settled = false
        opts.get_chapter(index, meta, function(html, err)
            if settled or cancelled then
                return
            end
            settled = true
            -- 调用方可能同步回调：下一拍再继续，避免栈爆 / 卡死
            UIManager:nextTick(function()
                onHtml(html, err)
            end)
        end)
    end

    UIManager:nextTick(function()
        processChapter(1)
    end)

    return {
        cancel = function()
            if cancelled then
                return
            end
            cancelled = true
            if active_job and active_job.cancel then
                active_job.cancel()
            end
            if pack_task then
                pack_task:abort()
            end
        end,
    }
end

-- 测试可见的纯函数
Html2Epub._collectImageSrcs = collectImageSrcs
Html2Epub._rewriteImageSrcs = rewriteImageSrcs
Html2Epub._ensureHtmlBody = ensureHtmlBody
Html2Epub._writeEpubPackage = writeEpubPackage
Html2Epub._sniffImage = sniffImage

return Html2Epub
