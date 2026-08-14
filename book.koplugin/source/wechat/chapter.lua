--[[--
微信读书章节正文：读 reader 页拿 psvts → 拉 e_0/e_1/e_3（或 t_0/t_1）→ 解码 → 最小 EPUB。

对齐 weread 网页端通道；禁止再猜 /chapter/e 或 i.weread chapterdownload。

本模块是同步 worker。禁止在 UI 事件里直接调 fetchHtml/ensure；
必须经由 book.chapter.ensureAsync（Promise 调度）。

@module koplugin.book.source.wechat.chapter
--]]

local JSON = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local Auth = require("source.wechat.auth")
local Protocol = require("source.wechat.protocol")
local _ = require("gettext")

local Chapter = {}

--- XML/HTML 特殊字符转义。
---@param s any
---@return string
local function xmlEscape(s)
    s = tostring(s or "")
    return s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
end

--- 粗判文本是否像 HTML/XHTML。
---@param s string|nil
---@return boolean
local function looksLikeHtml(s)
    if type(s) ~= "string" then
        return false
    end
    local head = s:sub(1, 256):lower()
    return head:find("<html") or head:find("<!doctype") or head:find("<p") or head:find("<div")
end

--- 纯文本按行包成 xhtml 段落。
---@param text string|nil
---@return string
local function txtToXhtml(text)
    text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    local parts = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        line = line:match("^(.-)%s*$") or ""
        if line ~= "" then
            parts[#parts + 1] = "<p>" .. xmlEscape(line) .. "</p>"
        end
    end
    return table.concat(parts, "\n")
end

--- 从 reader HTML 抽 psvts（优先 __INITIAL_STATE__）。
---@param html string|nil
---@return string|nil
local function extractPsvts(html)
    if type(html) ~= "string" or html == "" then
        return nil
    end
    local encoded = html:match([[window%.__INITIAL_STATE__%s*=%s*(.-)%s*;%s*%(function]])
    if encoded then
        local ok, state = pcall(JSON.decode, encoded)
        if ok and type(state) == "table" and type(state.reader) == "table" then
            local p = state.reader.psvts
            if type(p) == "string" and p ~= "" then
                return p
            end
        end
    end
    return html:match([["psvts"%s*:%s*"([^"]+)"]])
end

--- 打开 reader 页并提取 psvts。
---@param bookId string
---@param chapter_uid string|number
---@return string|nil psvts, string|nil referer_or_err
local function fetchReaderPsvts(bookId, chapter_uid)
    local url = Protocol.readerUrl(bookId, chapter_uid)
    local html, err = Auth.webGet(url, {
        accept = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        headers = { ["Referer"] = url },
        timeout = 30,
        block_timeout = 60,
    })
    if not html then
        return nil, err or _("无法打开阅读页")
    end
    local psvts = extractPsvts(html)
    if not psvts or psvts == "" then
        return nil, _("阅读页缺少 psvts")
    end
    return psvts, url
end

--- 拉取单个章节分片（e_*/t_*）。
---@param bookId string
---@param chapter_uid string|number
---@param psvts string
---@param endpoint string
---@param referer string
---@param style boolean|nil
---@return string|nil, string|nil
local function fetchShard(bookId, chapter_uid, psvts, endpoint, referer, style)
    local params = Protocol.contentParams(bookId, chapter_uid, psvts, {
        sc = 1,
        style = style == true,
    })
    local raw, err = Auth.webPost(
        "https://weread.qq.com" .. endpoint,
        JSON.encode(params),
        {
            accept = "application/json, text/plain, */*",
            content_type = "application/json;charset=UTF-8",
            headers = {
                ["Origin"] = "https://weread.qq.com",
                ["Referer"] = referer,
            },
            timeout = 30,
            block_timeout = 90,
        }
    )
    if not raw then
        return nil, err or (endpoint .. " failed")
    end
    if raw == "{}" then
        return nil, endpoint .. " empty"
    end
    return raw
end

--- 经 t_0/t_1 通道拉取并解码为 xhtml。
---@param bookId string
---@param chapter_uid string|number
---@param psvts string
---@param referer string
---@return string|nil, string|nil
local function fetchTxtXhtml(bookId, chapter_uid, psvts, referer)
    local t0, err = fetchShard(bookId, chapter_uid, psvts, "/web/book/chapter/t_0", referer)
    if not t0 then
        return nil, err
    end
    local t1 = fetchShard(bookId, chapter_uid, psvts, "/web/book/chapter/t_1", referer)
    local plain, e2 = Protocol.decodeShards(t0, t1 or "")
    if not plain then
        return nil, e2 or _("txt 章节解码失败")
    end
    return txtToXhtml(plain)
end

--- 拉取章节 HTML（xhtml 片段）。
---@param bookId string
---@param chapter BookChapter|table
---@return string|nil html, string|nil err
function Chapter.fetchHtml(bookId, chapter)
    require("utils.promise").requireAsync("wechat.chapter.fetchHtml")
    bookId = tostring(bookId or "")
    if not chapter then
        return nil, _("无章节信息")
    end
    local uid = chapter.uid
    if not uid then
        return nil, _("章节缺少 uid")
    end

    local psvts, referer_or_err = fetchReaderPsvts(bookId, uid)
    if not psvts then
        return nil, referer_or_err
    end
    local referer = referer_or_err

    local e0, err0 = fetchShard(bookId, uid, psvts, "/web/book/chapter/e_0", referer)
    if not e0 then
        return nil, err0
    end

    -- e_0 若直接吐 JSON（含 bookId），走 txt 通道
    if e0:sub(1, 1) == "{" and e0:find('"bookId"', 1, true) then
        return fetchTxtXhtml(bookId, uid, psvts, referer)
    end

    local e1, err1 = fetchShard(bookId, uid, psvts, "/web/book/chapter/e_1", referer)
    if not e1 then
        return nil, err1
    end
    local e3, err3 = fetchShard(bookId, uid, psvts, "/web/book/chapter/e_3", referer)
    if not e3 then
        return nil, err3
    end

    local xhtml, derr = Protocol.decodeShards(e0, e1, e3)
    if not xhtml then
        return nil, derr or _("章节解码失败")
    end
    if not looksLikeHtml(xhtml) then
        -- 偶发纯文本
        return txtToXhtml(xhtml)
    end
    return xhtml
end

--- 写最小 EPUB 到 dest_path（原子 .part + rename）。
---@param dest_path string
---@param title string|nil
---@param html string|nil
---@return boolean|nil, string|nil
function Chapter.writeEpub(dest_path, title, html)
    if type(dest_path) ~= "string" or dest_path == "" then
        return nil, _("无效路径")
    end
    title = title or _("章节")
    html = html or ""
    if not looksLikeHtml(html) then
        html = txtToXhtml(html)
    end

    local Archiver = require("ffi/archiver")
    local tmp = dest_path .. ".part"
    pcall(os.remove, tmp)
    local epub = Archiver.Writer:new{}
    if not epub:open(tmp, "epub") then
        return nil, epub.err or _("无法创建 epub")
    end
    local mtime = os.time()
    epub:setZipCompression("store")
    epub:addFileFromMemory("mimetype", "application/epub+zip", mtime)
    epub:setZipCompression("deflate")
    epub:addFileFromMemory("META-INF/container.xml", [[
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
]], mtime)

    local opf = string.format([[
<?xml version="1.0" encoding="UTF-8"?>
<package version="2.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>%s</dc:title>
    <dc:language>zh</dc:language>
    <dc:identifier id="bookid">moon-weread-chapter</dc:identifier>
  </metadata>
  <manifest>
    <item id="ch" href="chapter.xhtml" media-type="application/xhtml+xml"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="ch"/>
  </spine>
</package>
]], xmlEscape(title))
    epub:addFileFromMemory("OEBPS/content.opf", opf, mtime)

    local ncx = string.format([[
<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="moon-weread-chapter"/></head>
  <docTitle><text>%s</text></docTitle>
  <navMap>
    <navPoint id="n1" playOrder="1">
      <navLabel><text>%s</text></navLabel>
      <content src="chapter.xhtml"/>
    </navPoint>
  </navMap>
</ncx>
]], xmlEscape(title), xmlEscape(title))
    epub:addFileFromMemory("OEBPS/toc.ncx", ncx, mtime)

    local xhtml = string.format([[
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh">
<head><title>%s</title>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8"/>
<style type="text/css">
body{margin:1em;line-height:1.6;}
p{text-indent:2em;margin:0.6em 0;}
img{max-width:100%%;}
</style>
</head>
<body>
%s
</body>
</html>
]], xmlEscape(title), html)
    epub:addFileFromMemory("OEBPS/chapter.xhtml", xhtml, mtime)
    epub:close()

    os.remove(dest_path)
    local ok = os.rename(tmp, dest_path)
    if not ok then
        pcall(os.remove, tmp)
        return nil, _("写入章节失败")
    end
    if lfs.attributes(dest_path, "mode") ~= "file" then
        return nil, _("章节文件缺失")
    end
    return true
end

--- 拉取并写入 dest_path（已存在则直接成功）。
---@param bookId string
---@param idx number|nil
---@param dest_path string
---@param chapter BookChapter|table|nil
---@return boolean|nil, string|nil
function Chapter.ensure(bookId, idx, dest_path, chapter)
    require("utils.promise").requireAsync("wechat.chapter.ensure")
    if lfs.attributes(dest_path, "mode") == "file" then
        return true
    end
    if not Auth.hasSession() then
        return nil, _("请先扫码登录微信读书")
    end
    local html, err = Chapter.fetchHtml(bookId, chapter or { idx = idx })
    if not html then
        logger.warn("weread chapter fetch", bookId, idx, err)
        return nil, err
    end
    local title = (chapter and chapter.title) or string.format(_("第 %d 章"), tonumber(idx) or 0)
    return Chapter.writeEpub(dest_path, title, html)
end

return Chapter
