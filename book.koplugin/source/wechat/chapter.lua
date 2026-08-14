--[[--
微信读书章节正文：读 reader 页拿 psvts → 拉 e_0/e_1/e_3（或 t_0/t_1）→ 解码 → 最小 EPUB。

对齐 weread 网页端通道；禁止再猜 /chapter/e 或 i.weread chapterdownload。

网络仅异步：fetchHtmlAsync / ensureAsync。
writeEpub 为本地落盘（可在子进程调用）。

@module koplugin.book.source.wechat.chapter
--]]

local JSON = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local Auth = require("source.wechat.auth")
local Protocol = require("source.wechat.protocol")
local UIManager = require("ui/uimanager")
local Task = require("utils.task")
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

function Chapter.fetchHtmlAsync(bookId, chapter, cb)
    bookId = tostring(bookId or "")
    if not chapter or not chapter.uid then
        cb(nil, _("章节缺少 uid"))
        return { cancel = function() end }
    end
    local cancelled = false
    local active_job
    local function cancel()
        cancelled = true
        if active_job then active_job.cancel() end
    end
    local function fail(err)
        if not cancelled then cb(nil, err) end
    end
    local function requestShard(uid, psvts, endpoint, referer, style, done)
        local params = Protocol.contentParams(bookId, uid, psvts, {
            sc = 1,
            style = style == true,
        })
        active_job = Auth.webPostAsync(
            "https://weread.qq.com" .. endpoint,
            JSON.encode(params),
            {
                accept = "application/json, text/plain, */*",
                content_type = "application/json;charset=UTF-8",
                headers = {
                    ["Origin"] = "https://weread.qq.com",
                    ["Referer"] = referer,
                },
                block_timeout = 90,
            },
            function(raw, err)
                if cancelled then return end
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
    local uid = chapter.uid
    local reader_url = Protocol.readerUrl(bookId, uid)
    active_job = Auth.webGetAsync(reader_url, {
        accept = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        headers = { ["Referer"] = reader_url },
        block_timeout = 60,
    }, function(html, err)
        if cancelled then return end
        if not html then
            fail(err or _("无法打开阅读页"))
            return
        end
        local psvts = extractPsvts(html)
        if not psvts or psvts == "" then
            fail(_("阅读页缺少 psvts"))
            return
        end
        requestShard(uid, psvts, "/web/book/chapter/e_0", reader_url, false, function(e0, e0err)
            if not e0 then
                fail(e0err)
                return
            end
            if e0:sub(1, 1) == "{" and e0:find('"bookId"', 1, true) then
                requestShard(uid, psvts, "/web/book/chapter/t_0", reader_url, false, function(t0, t0err)
                    if not t0 then
                        fail(t0err)
                        return
                    end
                    requestShard(uid, psvts, "/web/book/chapter/t_1", reader_url, false, function(t1)
                        if cancelled then return end
                        local plain, decode_err = Protocol.decodeShards(t0, t1 or "")
                        if not plain then
                            fail(decode_err or _("txt 章节解码失败"))
                        else
                            cb(txtToXhtml(plain))
                        end
                    end)
                end)
                return
            end
            requestShard(uid, psvts, "/web/book/chapter/e_1", reader_url, false, function(e1, e1err)
                if not e1 then
                    fail(e1err)
                    return
                end
                requestShard(uid, psvts, "/web/book/chapter/e_3", reader_url, false, function(e3, e3err)
                    if not e3 then
                        fail(e3err)
                        return
                    end
                    local xhtml, decode_err = Protocol.decodeShards(e0, e1, e3)
                    if not xhtml then
                        fail(decode_err or _("章节解码失败"))
                    elseif looksLikeHtml(xhtml) then
                        cb(xhtml)
                    else
                        cb(txtToXhtml(xhtml))
                    end
                end)
            end)
        end)
    end)
    return { cancel = cancel }
end

function Chapter.writeEpubAsync(dest_path, title, html, cb)
    local task = Task.run(function()
        Chapter.writeEpub(dest_path, title, html)
    end, {
        timeout = 120,
        on_done = function()
            if lfs.attributes(dest_path, "mode") == "file" then
                cb(true)
            else
                cb(nil, _("写入章节失败"))
            end
        end,
        on_failed = function(err)
            cb(nil, err or _("写入章节失败"))
        end,
    })
    return {
        cancel = function()
            task:abort()
        end,
    }
end

function Chapter.ensureAsync(bookId, idx, dest_path, chapter, cb)
    if lfs.attributes(dest_path, "mode") == "file" then
        UIManager:nextTick(function() cb(true) end)
        return { cancel = function() end }
    end
    if not Auth.hasSession() then
        cb(nil, _("请先扫码登录微信读书"))
        return { cancel = function() end }
    end
    local cancelled = false
    local fetch_job
    local write_job
    fetch_job = Chapter.fetchHtmlAsync(bookId, chapter or { idx = idx }, function(html, err)
        if cancelled then return end
        if not html then
            logger.warn("weread chapter fetch", bookId, idx, err)
            cb(nil, err)
            return
        end
        local title = (chapter and chapter.title) or string.format(_("第 %d 章"), tonumber(idx) or 0)
        write_job = Chapter.writeEpubAsync(dest_path, title, html, function(ok, write_err)
            if not cancelled then
                cb(ok, write_err)
            end
        end)
    end)
    return {
        cancel = function()
            cancelled = true
            if fetch_job then fetch_job.cancel() end
            if write_job then write_job.cancel() end
        end,
    }
end

return Chapter
