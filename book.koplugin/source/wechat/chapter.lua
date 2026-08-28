--[[--
微信读书章节正文：读 reader 页拿 psvts → 拉 e_0/e_1/e_3（或 t_0/t_1）→ 解码。

对齐 weread 网页端通道。只返回标准正文，不写盘、不打 EPUB。
个人划线通过 bookmarklist 同步为 KOReader 原生注解，不在 HTML 里注入社区热度线。

@module koplugin.book.source.wechat.chapter
--]]

local JSON = require("json")
local logger = require("logger")
local Auth = require("source.wechat.auth")
local Protocol = require("source.wechat.protocol")
local Context = require("source.wechat.context")
local Annotations = require("source.wechat.annotations")
local Assets = require("source.wechat.assets")
local Text = require("utils.text")
local _ = require("gettext")

local Chapter = {}

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

--- 确保章节 psvts 已缓存（进度/时长上报依赖）。
---@param bookId string
---@param chapter_uid string|number
---@param cb fun(ok: boolean, err: any)
---@return { cancel: fun() }|nil
function Chapter.ensurePsvtsAsync(bookId, chapter_uid, cb)
    bookId = tostring(bookId or "")
    chapter_uid = chapter_uid and tostring(chapter_uid) or nil
    if bookId == "" or not chapter_uid then
        cb(nil, _("缺少章节信息"))
        return { cancel = function() end }
    end
    if Context.psvts(bookId, chapter_uid) then
        cb(true)
        return nil
    end
    local cancelled = false
    local reader_url = Protocol.readerUrl(bookId, chapter_uid)
    local job = Auth.webGetAsync(reader_url, {
        accept = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        headers = { ["Referer"] = reader_url },
        block_timeout = 60,
    }, function(html, err)
        if cancelled then return end
        if not html then
            cb(nil, err or _("无法打开阅读页"))
            return
        end
        local psvts = extractPsvts(html)
        if not psvts or psvts == "" then
            cb(nil, _("阅读页缺少 psvts"))
            return
        end
        Context.rememberPsvts(bookId, chapter_uid, psvts)
        cb(true)
    end)
    return {
        cancel = function()
            cancelled = true
            if job and job.cancel then job.cancel() end
        end,
    }
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
        Context.rememberPsvts(bookId, uid, psvts)
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
                            cb(Text.textToBody(plain))
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
                    else
                        local fragment = Text.htmlBodyFragment(xhtml)
                        if Text.looksLikeHtml(fragment) then
                            cb(Annotations.cleanChapterHtml(fragment))
                        else
                            cb(Text.textToBody(fragment))
                        end
                    end
                end)
            end)
        end)
    end)
    return { cancel = cancel }
end

--- 原地清理缓存章节 HTML；无需改写时不碰磁盘。
---@param path string
---@return boolean rewritten
local function rewriteCachedHtml(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    local f = io.open(path, "rb")
    if not f then
        return false
    end
    local html = f:read("*a")
    f:close()
    if type(html) ~= "string" or html == "" then
        return false
    end
    local cleaned = Annotations.cleanChapterHtml(html)
    if cleaned == html then
        return false
    end
    local tmp = path .. ".part"
    pcall(os.remove, tmp)
    local out = io.open(tmp, "wb")
    if not out then
        return false
    end
    out:write(cleaned)
    out:close()
    os.remove(path)
    if os.rename(tmp, path) then
        return true
    end
    pcall(os.remove, tmp)
    return false
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
    local cancelled, asset_job = false, nil
    local reader_url = Protocol.readerUrl(bookId, chapter and chapter.uid)
    local fetch_job = Chapter.fetchHtmlAsync(bookId, chapter or {}, function(html, err)
        if cancelled then return end
        if not html then
            logger.warn("weread chapter fetch", bookId, chapter and chapter.idx, err)
            cb(nil, err)
            return
        end
        asset_job = Assets.localizeAsync(bookId, chapter or {}, html, reader_url, function(localized)
            if cancelled then return end
            cb({ title = title, html = localized })
        end)
    end)
    return {
        cancel = function()
            cancelled = true
            if fetch_job and fetch_job.cancel then fetch_job:cancel() end
            if asset_job and asset_job.cancel then asset_job:cancel() end
        end,
    }
end

--- 已缓存章节：清除旧版误注入的社区热度虚线。
---
--- 纯本地文件操作，同步完成；无论清理成败都回原路径，调用方照常开章。
---@param path string
---@param cb fun(path: string|nil)
function Chapter.refreshCached(path, cb)
    local cleaned = rewriteCachedHtml(path)
    if cleaned then
        logger.dbg("weread stripped injected underlines", path)
    end
    cb(path)
end

return Chapter
