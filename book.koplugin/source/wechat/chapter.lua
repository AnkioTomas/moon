--[[--
微信读书章节正文：读 reader 页拿 psvts → 拉 e_0/e_1/e_3（或 t_0/t_1）→ 解码。

对齐 weread 网页端通道。只返回标准正文，不写盘、不打 EPUB。

@module koplugin.book.source.wechat.chapter
--]]

local JSON = require("json")
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

--- 异步拉取章节 HTML 正文。
---@param bookId string
---@param chapter BookChapter
---@param cb fun(html: string|nil, err: any)
---@return { cancel: fun() }
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

--- 标准章节内容：{ title, html }。
---@param bookId string
---@param chapter BookChapter
---@param cb fun(payload: ChapterContentPayload|nil, err: any)
---@return { cancel: fun() }
function Chapter.fetchContentAsync(bookId, chapter, cb)
    if not Auth.hasSession() then
        cb(nil, _("请先扫码登录微信读书"))
        return { cancel = function() end }
    end
    local title = (chapter and chapter.title)
        or string.format(_("第 %d 章"), tonumber(chapter and chapter.idx) or 0)
    return Chapter.fetchHtmlAsync(bookId, chapter or {}, function(html, err)
        if not html then
            logger.warn("weread chapter fetch", bookId, chapter and chapter.idx, err)
            cb(nil, err)
            return
        end
        cb({ title = title, html = html })
    end)
end

return Chapter
