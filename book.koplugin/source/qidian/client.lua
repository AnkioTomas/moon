--[[--
起点中文网 HTTP 客户端（仅异步）。

详情、目录、章节走手机站 SSR 页面（m.qidian.com，页面内嵌 pageContext JSON）。
www.qidian.com 有 WAF，不用。书架是 /webcommon/bookshelf/*，要带 Cookie 里的 _csrfToken。
进度是章：拉书架行的 readCid；上传 /webcommon/chapter/updReadStatus。
chapterUpdateTime 必须是章节更新时间的 unix 秒，空字符串会把 getReadStatus 写坏，日期字符串直接 500。
免费章匿名可读（isBuy 仍是 0）。VIP 章 vipStatus=1 且 isBuy 不是 1 时只有预览；已购 VIP 的 content 是密文（cES / fEnS 非 0），由 fock.lua 解密（密钥 = Cookie 的 ywguid + 页面 fkp）。

@module koplugin.book.source.qidian.client
--]]

require("l10n").apply()
local Fock = require("source.qidian.fock")
local JSON = require("json")
local logger = require("utils.log")
local Mapper = require("source.qidian.mapper")
local Request = require("http.request")
local SourceBase = require("source.base")
local Text = require("utils.text")
local _ = require("gettext")

local Client = {}

local SOURCE_ID = "qidian"
local WEB = "https://m.qidian.com"
local UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) "
    .. "Version/16.0 Mobile/15E148 Safari/604.1"
local PAGE_SIZE = 20
-- 匿名榜单 / 搜索页走 http 缓存：切榜单、回书城不再每次联网。
local LIST_TTL = 5 * 60
local MAX_PAGES = 50

---@return string|nil
function Client.cookie()
    local cookie = require("utils.settings").getSource(SOURCE_ID).cookie
    return type(cookie) == "string" and cookie ~= "" and cookie or nil
end

--- Cookie 请求头里的 _csrfToken。没有它书架接口一律 403。
---@param cookie string
---@return string|nil
function Client.csrf(cookie)
    local token = type(cookie) == "string" and (
        cookie:match("^_csrfToken=([^;]+)") or cookie:match(";%s*_csrfToken=([^;]+)"))
    if not token or token == "" then return nil end
    return token
end

---@param cookie string|nil
---@return table
local function headers(cookie)
    return {
        Cookie = cookie,
        ["User-Agent"] = UA,
        Referer = WEB .. "/bookshelf/my/",
        Origin = WEB,
    }
end

---@param cookie string
---@param params table|nil
---@return string
local function query(cookie, params)
    local parts = {}
    for key, value in pairs(params or {}) do
        parts[#parts + 1] = Text.urlEncode(key) .. "=" .. Text.urlEncode(value)
    end
    local token = Client.csrf(cookie)
    if token then parts[#parts + 1] = "_csrfToken=" .. Text.urlEncode(token) end
    table.sort(parts)
    return table.concat(parts, "&")
end

--- 登录态失效只标记当前已保存的 Cookie，校验新 Cookie 时不污染旧登录态。
---@param cookie string
---@param msg string
---@return string
local function expired(cookie, msg)
    if cookie ~= "" and cookie == Client.cookie() then
        return require("source.auth").expire(SOURCE_ID, msg)
    end
    return msg
end

---@param path string
---@param cookie string|nil
---@param cb fun(html: string|nil, err: string|nil)
---@return HttpJob
local function webGet(path, cookie, cb, cache_ttl)
    return Request.get(WEB .. path, {
        headers = headers(cookie),
        timeout = require("http.timeout").net(1),
        cache_ttl = cache_ttl,
    }, function(raw, err, res)
        if not raw then
            local code = res and tonumber(res.code)
            if code == 302 or code == 403 then
                cb(nil, expired(cookie or "", _("起点登录已失效")))
            else
                cb(nil, err and tostring(err) or _("请求失败"))
            end
            return
        end
        cb(raw)
    end)
end

---@param wire table|nil
---@param cookie string
---@return table|nil data
---@return string|nil err
local function okData(wire, cookie)
    if tonumber(wire.code) == 0 and type(wire.data) == "table" then return wire.data end
    local msg = type(wire.msg) == "string" and wire.msg ~= "" and wire.msg or _("响应无效")
    if tonumber(wire.code) == 1403 then msg = expired(cookie, _("起点登录已失效")) end
    return nil, msg
end

---@param path string
---@param params table
---@param cookie string
---@param cb fun(data: table|nil, err: string|nil)
---@return HttpJob
local function apiGet(path, params, cookie, cb)
    return Request.get(WEB .. path .. "?" .. query(cookie, params), {
        accept = "application/json",
        headers = headers(cookie),
        timeout = require("http.timeout").net(1),
    }, function(raw, err, res)
        if not raw then
            local code = res and tonumber(res.code)
            if code == 302 or code == 403 then
                cb(nil, expired(cookie, _("起点登录已失效")))
            else
                cb(nil, err and tostring(err) or _("请求失败"))
            end
            return
        end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok or type(wire) ~= "table" then cb(nil, _("响应无效")); return end
        cb(okData(wire, cookie))
    end)
end

---@param book_id string
---@param data table|nil
---@return boolean ok
---@return string|nil err
local function bookOk(book_id, data)
    local row = type(data) == "table" and (data[book_id] or data[tostring(book_id)])
    if type(row) == "table" and tonumber(row.code) ~= 0 then
        return false, row.message or _("请求失败")
    end
    return true
end

--- 拉书架。先拉默认分组，再拉其余有书的分组，按书号去重。
---@param cookie string
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return { cancel: fun() }
function Client.shelfAsync(cookie, cb)
    if type(cookie) ~= "string" or cookie == "" then
        return SourceBase.defer(cb, nil, _("未登录起点"))
    end
    if not Client.csrf(cookie) then
        return SourceBase.defer(cb, nil, _("起点 Cookie 缺少登录凭证"))
    end
    local cancelled, job = false, nil
    local books, seen, groups = {}, {}, nil
    local fetchPage
    local function addRows(list)
        for _idx, row in ipairs(type(list) == "table" and list or {}) do
            local id = row.bid and tostring(row.bid)
            if id and not seen[id] then
                seen[id] = true
                books[#books + 1] = row
            end
        end
    end
    local function finish(err)
        if cancelled then return end
        if err then cb(nil, err) else cb(books) end
    end
    local function nextGroup()
        local gid = groups and table.remove(groups, 1)
        if not gid then finish(); return end
        fetchPage(gid, 1)
    end
    fetchPage = function(gid, page)
        if cancelled then return end
        if page > MAX_PAGES then nextGroup(); return end
        job = apiGet("/webcommon/bookshelf/mlist", {
            gid = gid, sort = 0, pageNum = page, pageSize = PAGE_SIZE, sortChange = 0,
        }, cookie, function(data, err)
            if cancelled then return end
            if not data then finish(err); return end
            addRows(data.list)
            if groups == nil then
                groups = {}
                for _idx, group in ipairs(type(data.groups) == "table" and data.groups or {}) do
                    local id = tonumber(group.groupId)
                    if id and id ~= -100 and tonumber(group.bookCount) ~= 0 then
                        groups[#groups + 1] = id
                    end
                end
            end
            local info = type(data.page) == "table" and data.page or {}
            local list = type(data.list) == "table" and data.list or {}
            if info.isLast == 1 or info.isLast == true or #list < PAGE_SIZE then
                nextGroup()
            else
                fetchPage(gid, page + 1)
            end
        end)
    end
    fetchPage(-100, 1)
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
end

--- 校验 Cookie：书架页 200 且 pageData.user.isLogin。cookie 显式传入，登录入口先校验再保存。
---@param cookie string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Client.loginCheckAsync(cookie, cb)
    if type(cookie) ~= "string" or cookie == "" then
        return SourceBase.defer(cb, nil, _("没有读到 Cookie"))
    end
    if not Client.csrf(cookie) then
        return SourceBase.defer(cb, nil, _("起点 Cookie 缺少登录凭证"))
    end
    return webGet("/bookshelf/my/", cookie, function(html, err)
        if not html then cb(nil, err); return end
        local user = (Mapper.pageData(html) or {}).user
        if not (type(user) == "table" and (user.isLogin == true or user.login == true)) then
            cb(nil, expired(cookie, _("起点登录已失效")))
            return
        end
        if cookie == Client.cookie() then require("source.auth").ok(SOURCE_ID) end
        cb(true)
    end)
end

---@param book_id string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Client.addAsync(book_id, cb)
    local cookie = Client.cookie()
    if not cookie then return SourceBase.defer(cb, nil, _("未登录起点")) end
    if not Client.csrf(cookie) then return SourceBase.defer(cb, nil, _("起点 Cookie 缺少登录凭证")) end
    return Request.post(WEB .. "/webcommon/bookshelf/addbooks?" .. query(cookie), Text.formEncode({ bookId = book_id }), {
        content_type = "application/x-www-form-urlencoded",
        headers = headers(cookie),
        timeout = require("http.timeout").net(1),
    }, function(raw, err)
        if not raw then cb(nil, err and tostring(err) or _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok or type(wire) ~= "table" then cb(nil, _("响应无效")); return end
        local data, data_err = okData(wire, cookie)
        if not data then cb(nil, data_err); return end
        local added, add_err = bookOk(book_id, data)
        cb(added and true or nil, add_err)
    end)
end

--- 上报读到哪一章。updated 是章节更新时间的 unix 秒，不是「现在」。
---@param book_id string
---@param chapter_id string
---@param chapter_name string|nil
---@param is_vip integer|boolean|nil
---@param updated integer|string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Client.updateReadAsync(book_id, chapter_id, chapter_name, is_vip, updated, cb)
    local cookie = Client.cookie()
    if not cookie then return SourceBase.defer(cb, nil, _("未登录起点")) end
    if not Client.csrf(cookie) then return SourceBase.defer(cb, nil, _("起点 Cookie 缺少登录凭证")) end
    if updated == nil or tostring(updated) == "" then
        return SourceBase.defer(cb, nil, _("起点章节时间缺失"))
    end
    return Request.post(WEB .. "/webcommon/chapter/updReadStatus?" .. query(cookie), Text.formEncode({
        bookId = book_id,
        chapterId = chapter_id,
        chapterName = chapter_name or "",
        isVip = (is_vip == true or tonumber(is_vip) == 1) and "1" or "0",
        chapterUpdateTime = tostring(updated),
    }), {
        content_type = "application/x-www-form-urlencoded",
        headers = headers(cookie),
        timeout = require("http.timeout").net(1),
    }, function(raw, err)
        if not raw then cb(nil, err and tostring(err) or _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok or type(wire) ~= "table" then cb(nil, _("响应无效")); return end
        -- 成功时 data 不是表（常为空）。不能走 okData，否则 code=0 也会被当成失败。
        if tonumber(wire.code) == 0 then cb(true); return end
        local msg = type(wire.msg) == "string" and wire.msg ~= "" and wire.msg or _("响应无效")
        if tonumber(wire.code) == 1403 then msg = expired(cookie, _("起点登录已失效")) end
        cb(nil, msg)
    end)
end

---@param book_id string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Client.removeAsync(book_id, cb)
    local cookie = Client.cookie()
    if not cookie then return SourceBase.defer(cb, nil, _("未登录起点")) end
    return apiGet("/webcommon/bookshelf/delbook", { bids = book_id, gid = -100 }, cookie, function(data, err)
        if not data then cb(nil, err); return end
        local removed, remove_err = bookOk(book_id, data)
        cb(removed and true or nil, remove_err)
    end)
end

--- 搜索：匿名取手机站 SSR 搜索页（一页 20 条）。
---@param keyword string
---@param cb fun(data: table|nil, err: string|nil)
---@return HttpJob
function Client.searchAsync(keyword, cb)
    return webGet("/soushu/" .. Text.urlEncode(keyword) .. ".html", nil, function(html, err)
        if not html then cb(nil, err); return end
        local data = Mapper.pageData(html)
        if not data then cb(nil, _("起点书籍信息为空")); return end
        cb(data)
    end, LIST_TTL)
end

--- 榜单页（手机网页 SSR，一页 20 本）。path 如 /rank/yuepiao/catid21/。
---@param path string
---@param cb fun(data: table|nil, err: string|nil)
---@return HttpJob
function Client.rankAsync(path, cb)
    return webGet(path, nil, function(html, err)
        if not html then cb(nil, err); return end
        local data = Mapper.pageData(html)
        if not data or type(data.records) ~= "table" then cb(nil, _("起点榜单为空")); return end
        cb(data)
    end, LIST_TTL)
end

---@param book_id string
---@param cb fun(info: table|nil, err: string|nil)
---@return HttpJob
function Client.detailAsync(book_id, cb)
    return webGet("/book/" .. book_id .. "/", Client.cookie(), function(html, err)
        if not html then cb(nil, err); return end
        local info = (Mapper.pageData(html) or {}).bookInfo
        if type(info) ~= "table" or not info.bookName then
            cb(nil, _("起点书籍信息为空"))
            return
        end
        cb(info)
    end)
end

---@param book_id string
---@param cb fun(data: table|nil, err: string|nil)
---@return HttpJob
function Client.catalogAsync(book_id, cb)
    return webGet("/book/" .. book_id .. "/catalog/", Client.cookie(), function(html, err)
        if not html then cb(nil, err); return end
        local data = Mapper.pageData(html)
        if not data then cb(nil, _("起点目录为空")); return end
        cb(data)
    end)
end

--- 一章正文。未购买的 VIP（vipStatus=1 且 isBuy 不是 1）只有预览，不当正文。
---@param bytes string|nil
---@return boolean
local function looksLikeFont(bytes)
    if type(bytes) ~= "string" or #bytes < 4 then return false end
    local head = bytes:sub(1, 4)
    return head == "\0\1\0\0" or head == "OTTO" or head == "true" or head == "ttcf" or head == "wOFF"
end

---@param book_id string
---@param chapter_id string
---@param cb fun(text: string|nil, err: string|nil, kind: "unpaid"|nil) kind = "unpaid"：这章没买
---@return HttpJob
function Client.contentAsync(book_id, chapter_id, cb)
    local decrypting, font_job
    local function finish_html(content)
        local text = Mapper.chapterText(content)
        if not text then cb(nil, _("起点章节内容为空")); return end
        cb(text)
    end
    local function finish_text(text)
        if type(text) ~= "string" or Text.trim(text) == "" then cb(nil, _("起点章节内容为空")); return end
        cb(text)
    end
    local function decrypt_done(text, derr)
        decrypting = nil
        if not text then
            logger.warn("qidian fock decrypt failed:", derr)
            cb(nil, _("起点 VIP 章节解密失败") .. (derr and ("：" .. tostring(derr)) or "")); return
        end
        finish_text(text)
    end
    local fetch = webGet("/chapter/" .. book_id .. "/" .. chapter_id .. "/", Client.cookie(), function(html, err)
        if not html then cb(nil, err); return end
        local info = (Mapper.pageData(html) or {}).chapterInfo
        if type(info) ~= "table" then cb(nil, _("起点章节内容为空")); return end
        if Mapper.locked(info) then cb(nil, _("起点 VIP 章节未购买"), "unpaid"); return end
        local content = info.content
        local ces = tonumber(info.cES) or 0
        if ces ~= 0 and ces ~= 2 then
            logger.warn("qidian unknown cES:", ces)
            cb(nil, _("起点 VIP 章节加密方式不受支持")); return
        end
        local fock = Mapper.fockEncrypted(info)
        local font_protected = Mapper.fontProtected(info)
        if not fock and not font_protected then finish_html(content); return end

        local keypool, version, uid
        if fock then
            local cookie = Client.cookie()
            uid = cookie and cookie:match("ywguid=(%d+)")
            -- fkp 是 base64 的 `window.onkeyfocus("<密钥池>", <版本>)`，只取参数，不执行
            keypool, version = Text.base64Decode(tostring(info.fkp or ""))
                :match('onkeyfocus%("([^"]+)",%s*(%d+)%)')
            if not (uid and keypool and version and type(content) == "string") then
                logger.warn("qidian decrypt inputs missing: uid", uid ~= nil, "keypool", keypool ~= nil,
                    "version", version ~= nil, "content", type(content))
                cb(nil, _("起点 VIP 章节解密失败：缺少登录信息，请重新登录起点")); return
            end
        end

        local function run(fixed_font)
            if font_protected then
                if fock then
                    decrypting = Fock.chapterAsync(info, fixed_font, chapter_id, keypool, version, uid, decrypt_done)
                else
                    decrypting = Fock.restoreAsync(content, info, fixed_font, decrypt_done)
                end
            else
                decrypting = Fock.decryptAsync(content, chapter_id, keypool, version, uid, function(plain, derr)
                    decrypting = nil
                    if not plain then
                        logger.warn("qidian fock decrypt failed:", derr)
                        cb(nil, _("起点 VIP 章节解密失败") .. (derr and ("：" .. tostring(derr)) or "")); return
                    end
                    finish_html(plain)
                end)
            end
        end

        if not font_protected then run(nil); return end

        local url = info.fixedFontTtf
        if type(url) ~= "string" or url == "" or type(info.randomFont) ~= "string" or type(info.css) ~= "string" then
            logger.warn("qidian font inputs missing: fixedFontTtf", type(url), "randomFont", type(info.randomFont),
                "css", type(info.css))
            cb(nil, _("起点 VIP 章节字体解密失败：缺少字体信息")); return
        end
        font_job = Request.get(url, {
            headers = { ["User-Agent"] = UA, ["Referer"] = "https://m.qidian.com/" },
            timeout = require("http.timeout").net(3),
        }, function(ttf, ferr, res)
            font_job = nil
            if not ttf or #ttf == 0 then
                logger.warn("qidian font download failed:", ferr, "code", res and res.code, "len", ttf and #ttf)
                cb(nil, _("起点 VIP 章节字体下载失败")); return
            end
            if not looksLikeFont(ttf) then
                logger.warn("qidian font download invalid:", #ttf, tostring(ttf:sub(1, 16)), "code", res and res.code)
                cb(nil, _("起点 VIP 章节字体下载失败")); return
            end
            run(ttf)
        end)
    end)
    return { cancel = function()
        fetch.cancel()
        if font_job then font_job:cancel() end
        if decrypting then decrypting:cancel() end
    end }
end

-- 段评接口匿名可读，但 Cookie 与参数里的 _csrfToken 必须一致（双提交），没登录就本地编一个。
local anon_csrf
---@return string
local function reviewCookie()
    if Client.cookie() then return Client.cookie() end
    if not anon_csrf then
        local hex = {}
        for i = 1, 32 do hex[i] = string.format("%x", math.random(0, 15)) end
        anon_csrf = "_csrfToken=" .. table.concat(hex)
    end
    return anon_csrf
end

--- 本章各段评论数；list[].paragraphId 从 1 数，-1 是章末总评；enableReview = 0 表示这本书没开段评。
---@param book_id string
---@param chapter_id string
---@param cb fun(data: table|nil, err: string|nil)
---@return HttpJob
function Client.reviewSummaryAsync(book_id, chapter_id, cb)
    return apiGet("/webcommon/chapterreview/reviewsummary4m", { bookId = book_id, chapterId = chapter_id },
        reviewCookie(), cb)
end

--- 某段的一页评论（page 从 1 起，每页 10 条左右）。
---@param book_id string
---@param chapter_id string
---@param paragraph_id integer
---@param page integer
---@param cb fun(data: table|nil, err: string|nil)
---@return HttpJob
function Client.reviewListAsync(book_id, chapter_id, paragraph_id, page, cb)
    return apiGet("/webcommon/chapterreview/reviewlist4m", {
        bookId = book_id, chapterId = chapter_id, paragraphId = paragraph_id, page = page,
    }, reviewCookie(), cb)
end

return Client
