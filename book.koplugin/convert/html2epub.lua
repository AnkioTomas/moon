--[[--
HTML 章节 → EPUB。

调用方给齐每章的 HTML body（不含外部资源），这里包成 XHTML、生成
OPF/NCX，zip 写入放进子进程（workers.job），不堵 UI。

  local Html2Epub = require("convert.html2epub")
  local job = Html2Epub.build({
      dest = "/path/book.epub",
      title = "书名",
      author = "作者",
      chapters = { { title = "第一章", html = "<p>…</p>" } },
  }, function(ok, err) end)
  job.cancel()

@module koplugin.book.convert.html2epub
--]]

local logger = require("utils.log")
local Text = require("utils.text")
local Perf = require("utils.perf")
local _ = require("gettext")

local Html2Epub = {}

--- 把章节 HTML body 包成完整 XHTML 文档。
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
</style>
</head>
<body>
%s
</body>
</html>
]], Text.xmlEscape(title), body)
end

------------------------------------------------------------------------
-- 打包
------------------------------------------------------------------------

---@param opts {
---   title: string,
---   author: string|nil,
---   language: string|nil,
---   identifier: string|nil,
---   chapters: { title: string, href: string, xhtml: string, toc?: boolean }[],
--- }
---@param dest string
---@return boolean|nil, string|nil
local function writeEpubPackage(opts, dest)
    local Archiver = require("ffi/archiver")
    local title = opts.title
    local author = opts.author or ""
    local language = opts.language or "zh"
    local identifier = opts.identifier or ("moon-html2epub-" .. tostring(os.time()))
    local chapters = opts.chapters

    local tmp = dest .. ".part"
    os.remove(tmp)
    ---@diagnostic disable-next-line: redundant-parameter
    local epub = Archiver.Writer:new{}
    if not epub:open(tmp, "epub") then
        return nil, epub.err or _("无法创建 epub")
    end

    --- 关闭并丢弃半成品；返回 nil, err 供调用方直接 return。
    ---@param msg string
    local function abort(msg)
        epub:close()
        os.remove(tmp)
        return nil, epub.err or msg
    end

    local mtime = os.time()
    epub:setZipCompression("store")
    if not epub:addFileFromMemory("mimetype", "application/epub+zip", mtime) then
        return abort(_("写入 mimetype 失败"))
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
    if not epub:addFileFromMemory("META-INF/container.xml", container, mtime) then
        return abort(_("写入 epub 失败"))
    end

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
    if not epub:addFileFromMemory("OEBPS/content.opf", opf, mtime) then
        return abort(_("写入 epub 失败"))
    end

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
    if not epub:addFileFromMemory("OEBPS/toc.ncx", ncx, mtime) then
        return abort(_("写入 epub 失败"))
    end

    for _i, ch in ipairs(chapters) do
        if not epub:addFileFromMemory("OEBPS/" .. ch.href, ch.xhtml, mtime) then
            return abort(_("写入章节失败"))
        end
    end

    epub:close()
    os.remove(dest)
    if not os.rename(tmp, dest) then
        os.remove(tmp)
        return nil, _("写入 epub 失败")
    end
    return true
end

--- 异步构建 EPUB。
---@param opts {
---   dest: string,
---   title: string,
---   author: string|nil,
---   language: string|nil,
---   identifier: string|nil,
---   chapters: { title: string, html: string, toc: boolean|nil }[],
--- }
---@param cb fun(ok: boolean|nil, err: any)
---@return { cancel: fun() }
function Html2Epub.build(opts, cb)
    local dest = opts.dest
    local started_at = Perf.now()
    local chapters = {}
    for index, chapter in ipairs(opts.chapters) do
        chapters[index] = {
            title = chapter.title,
            toc = chapter.toc,
            href = string.format("chapter_%03d.xhtml", index),
            xhtml = wrapXhtml(chapter.title, chapter.html),
        }
    end
    local pack_opts = {
        title = opts.title,
        author = opts.author,
        language = opts.language,
        identifier = opts.identifier,
        chapters = chapters,
    }

    local cancelled = false
    --- 以错误回调；已取消时静默。
    ---@param err any 失败原因
    local function fail(err)
        if cancelled then
            return
        end
        logger.warn("book.html2epub failed", dest, Perf.elapsedMs(started_at), "ms", err)
        cb(nil, err)
    end

    local pack_task = require("workers.job").run(function()
        local ok, err = writeEpubPackage(pack_opts, dest)
        return ok and "ok" or ("err:" .. tostring(err or "pack failed"))
    end, {
        name = "epub.pack",
        kind = "heavy",
        on_done = function(result)
            if cancelled then
                return
            end
            if result == "ok" then
                logger.dbg("book.html2epub done", dest, #chapters, "chapters", Perf.elapsedMs(started_at), "ms")
                cb(true)
                return
            end
            local msg = type(result) == "string" and result:match("^err:(.*)$") or nil
            fail(msg or result or _("写入 epub 失败"))
        end,
        on_failed = function(err)
            fail(err or _("写入 epub 失败"))
        end,
    })

    return { cancel = function()
            if cancelled then
                return
            end
            cancelled = true
            pack_task:cancel()
        end }
end

return Html2Epub
