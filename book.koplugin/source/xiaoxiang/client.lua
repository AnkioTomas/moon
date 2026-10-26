--[[--
潇湘书院 HTTP 客户端（仅异步）。

搜索走 PC 站搜索页（HTML）；目录、榜单走手机站 SSR 页面（m.xxsy.net，匿名可读，目录内嵌 JSON）。
账号、正文、书架、进度走新站 www.xxsypro.com 的 JSON 接口（阅文通行证，与起点同一套账号体系）：请求带登录 Cookie
（ywGuid / ywKey 等）和同值的 csrfToken（Cookie 与 `_csrfToken` 查询参数），回包 code 0 为成功。
匿名也能调，但书架是访客书架、没买的 VIP 章只回 130 字预览（auth=false），所以带登录态的操作先用 /user/auth/personal 确认 isLogin=1。
书 / 章 id 是 17 位整数，超出 double 精度，解码前先加引号。目录页上千章、1MB+，解析放子进程。

@module koplugin.book.source.xiaoxiang.client
--]]

local Job = require("workers.job")
local logger = require("utils.log")
local JSON = require("json")
local Mapper = require("source.xiaoxiang.mapper")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("gettext")

local Client = {}

-- 匿名榜单 / 搜索页走 http 缓存：切榜单、回书城不再每次联网。
local LIST_TTL = 5 * 60

--- 已保存的登录 Cookie。
---@return string|nil
function Client.cookie()
    local cookie = require("utils.settings").getSource("xiaoxiang").cookie
    return type(cookie) == "string" and cookie ~= "" and cookie or nil
end

local UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) "
    .. "Version/16.0 Mobile/15E148 Safari/604.1"

---@param url string
---@param cb fun(html: string|nil, err: string|nil)
---@return HttpJob
local function page(url, cb, cache_ttl)
    return Request.get(url, {
        headers = { ["User-Agent"] = UA },
        timeout = require("http.timeout").net(1),
        cache_ttl = cache_ttl,
    }, function(raw, err)
        if not raw then cb(nil, err and tostring(err) or _("请求失败")); return end
        cb(raw)
    end)
end

local SOURCE_ID = "xiaoxiang"
local API = "https://www.xxsypro.com/api"
local MAX_SHELF_PAGES = 50

--- 请求头里的 Cookie：没有 csrfToken 就补一个，网页端要求 Cookie 与 `_csrfToken` 同值。
---@param cookie string|nil
---@return string cookie
---@return string csrf
local function withCsrf(cookie)
    local csrf = cookie and cookie:match("csrfToken=([^;%s]+)")
    if csrf then return cookie, csrf end
    csrf = "moon"
    return (cookie and cookie .. "; " or "") .. "csrfToken=" .. csrf, csrf
end

--- 回包 JSON 解码（17 位 id 先加引号）；code 非 0 取 msg 当错误。
---@param raw string|nil
---@param err any
---@param cb fun(wire: table|nil, err: string|nil)
local function decode(raw, err, cb)
    if not raw then cb(nil, err and tostring(err) or _("请求失败")); return end
    local ok, wire = pcall(JSON.decode, (raw:gsub('(":)(%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d+)', '%1"%2"')))
    if not ok or type(wire) ~= "table" then cb(nil, _("响应无效")); return end
    if wire.code ~= 0 then cb(nil, wire.msg and tostring(wire.msg) or _("响应无效")); return end
    cb(wire)
end

--- 新站 JSON 接口；body 为 nil 发 GET，否则 POST（body 是已编码的 JSON 串）。
---@param path string
---@param query string 不含 _csrfToken
---@param body string|nil
---@param cookie string|nil
---@param cb fun(wire: table|nil, err: string|nil)
---@return HttpJob
local function call(path, query, body, cookie, cb)
    local cookie_header, csrf = withCsrf(cookie)
    local url = API .. path .. "?" .. (query ~= "" and query .. "&" or "") .. "_csrfToken=" .. csrf
    local opts = {
        accept = "application/json",
        headers = { Cookie = cookie_header, Referer = "https://www.xxsypro.com/", ["User-Agent"] = UA },
        timeout = require("http.timeout").net(0.5),
    }
    if body then
        opts.content_type = "application/json"
        return Request.post(url, body, opts, function(raw, err) decode(raw, err, cb) end)
    end
    return Request.get(url, opts, function(raw, err) decode(raw, err, cb) end)
end

--- 账号信息：isLogin=1 才是真登录（失效的 Cookie 仍 code 0，只是 isLogin=0）。cookie 显式传入，登录入口先校验再保存。
---@param cookie string
---@param cb fun(info: table|nil, err: string|nil)
---@return HttpJob
function Client.userAsync(cookie, cb)
    return call("/user/auth/personal", "", nil, cookie, function(wire, err)
        local data = wire and wire.data
        if type(data) ~= "table" or tonumber(data.isLogin) ~= 1 then
            cb(nil, err or _("登录失败"))
            return
        end
        cb(data)
    end)
end

--- 带登录态的调用：先确认 isLogin=1，失效就标记登出，免得访客书架被当成真实书架。
---@param path string
---@param query string
---@param body string|nil
---@param cb fun(wire: table|nil, err: string|nil)
---@return { cancel: fun() }
local function authed(path, query, body, cb)
    local cookie = Client.cookie()
    ---@type boolean, CancelHandle|nil
    local cancelled, job = false, nil
    local Auth = require("source.auth")
    job = Client.userAsync(cookie or "", function(info, err)
        if cancelled then return end
        if not info then
            cb(nil, cookie and Auth.expire(SOURCE_ID, err or _("潇湘登录已失效")) or _("未登录潇湘"))
            return
        end
        Auth.ok(SOURCE_ID)
        job = call(path, query, body, cookie, cb)
    end)
    return { cancel = function()
        cancelled = true
        job:cancel()
    end }
end

--- 书架（只收根目录的书，resType 1），翻页收齐。
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return { cancel: fun() }
function Client.shelfAsync(cb)
    ---@type table[], boolean, CancelHandle|nil
    local rows, cancelled, job = {}, false, nil
    local function more(page)
        job = authed("/bookshelf/pc/page", "pageIndex=" .. page .. "&pageSize=20", nil, function(wire, err)
            if cancelled then return end
            local data = wire and wire.data
            if type(data) ~= "table" then cb(nil, err or _("响应无效")); return end
            for _idx, row in ipairs(data.data or {}) do
                if tonumber(row.restype) == 1 and tonumber(row.groupId) == -100 then rows[#rows + 1] = row end
            end
            if page < (tonumber(data.pageCount) or 0) and page < MAX_SHELF_PAGES then
                more(page + 1)
                return
            end
            cb(rows)
        end)
    end
    more(1)
    return { cancel = function()
        cancelled = true
        job:cancel()
    end }
end

---@param book_id string
---@return string
local function shelfBody(book_id, extra)
    return '{"groupInfo":[{"groupId":-100,"books":[{"bookId":"' .. book_id .. '","resType":1' .. extra .. "}]}]}"
end

---@param book_id string
---@param cb fun(wire: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client.shelfAddAsync(book_id, cb)
    return authed("/bookshelf/add", "", shelfBody(book_id, ',"ccid":"0","offset":0,"updatetime":' .. os.time() * 1000), cb)
end

---@param book_id string
---@param cb fun(wire: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client.shelfRemoveAsync(book_id, cb)
    return authed("/bookshelf/delete", "", shelfBody(book_id, ""), cb)
end

--- 记「读到这一章」：书架行的 ccid 就是它。
---@param book_id string
---@param chapter_id string
---@param cb fun(wire: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client.progressAsync(book_id, chapter_id, cb)
    return authed("/bookshelf/readingProcess/add", "bookId=" .. book_id, '{"books":[{"resType":1,"bookId":"' .. book_id
        .. '","updatetime":' .. os.time() * 1000 .. ',"ccid":"' .. chapter_id .. '","offset":0}]}', cb)
end

---@param keyword string
---@param cb fun(books: Book[]|nil, err: string|nil)
---@return HttpJob
function Client.searchAsync(keyword, cb)
    return page("https://www.xxsy.net/search?sort=0&s_wd=" .. Text.urlEncode(keyword), function(html, err)
        if not html then cb(nil, err); return end
        cb(Mapper.search(html))
    end, LIST_TTL)
end

--- 榜单页（一页 20 本）；name 是手机站 /rank/<name>。
---@param name string
---@param cb fun(books: Book[]|nil, err: string|nil)
---@return HttpJob
function Client.rankAsync(name, cb)
    return page("https://m.xxsy.net/rank/" .. name, function(html, err)
        if not html then cb(nil, err); return end
        cb(Mapper.rank(html))
    end, LIST_TTL)
end

--- 取页面并在子进程里按 parse 解析；parse 返回 nil 以外的值都算成功。
---@param url string
---@param name string
---@param parse fun(html: string): any, string|nil
---@param cb fun(value: any, err: string|nil, kind: string|nil)
---@return { cancel: fun() }
local function parsed(url, name, parse, cb)
    ---@type boolean, CancelHandle|nil
    local cancelled, job = false, nil
    job = page(url, function(html, err)
        if cancelled then return end
        if not html then cb(nil, err); return end
        job = Job.run(function()
            local value, kind = parse(html)
            return { value = value, kind = kind }
        end, {
            name = name,
            kind = "light",
            timeout = 60,
            on_done = function(res)
                if cancelled then return end
                cb(res.value, nil, res.kind)
            end,
            on_failed = function(reason) if not cancelled then cb(nil, tostring(reason)) end end,
            on_cancelled = function() end,
        })
    end)
    return { cancel = function()
        cancelled = true
        job:cancel()
    end }
end

---@param book_id string
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
---@return { cancel: fun() }
function Client.chaptersAsync(book_id, cb)
    return parsed("https://m.xxsy.net/books/" .. book_id .. ".html", "xiaoxiang_toc", Mapper.toc, cb)
end

--- 一章正文（纯文本，段落以换行分隔）。免费章匿名可读；没买的 VIP 章只回预览（auth=false），报 "unpaid"。
---@param book_id string
---@param chapter_id string
---@param cb fun(text: string|nil, err: string|nil, kind: "unpaid"|nil)
---@return table handle { cancel }
function Client.contentAsync(book_id, chapter_id, cb)
    local current
    -- 已购 VIP 章是 Fock 加密 + 乱序字体：fkp 是 `window.onkeyfocus("<密钥池>", <版本>)` 的 base64（只取参数不执行），用户密钥是 Cookie 的 ywGuid
    local function decrypt(chapter)
        local keypool, version = Text.base64Decode(tostring(chapter.fkp or ""))
            :match('onkeyfocus%("([^"]+)",%s*(%d+)%)')
        local uid = (Client.cookie() or ""):match("ywGuid=(%d+)")
        local font = type(chapter.fontResponse) == "table" and chapter.fontResponse or {}
        if not (keypool and version and uid and type(chapter.chapterContent) == "string") then
            logger.warn("xiaoxiang decrypt inputs missing: keypool", keypool ~= nil, "version", version ~= nil,
                "uid", uid ~= nil, "content", type(chapter.chapterContent))
            cb(nil, _("潇湘章节解密失败")); return
        end
        local function run(fixed_font)
            current = require("source.xiaoxiang.fock").chapterAsync(chapter, fixed_font, chapter_id, keypool, version,
                uid, function(text, derr)
                    current = nil
                    if not text then
                        logger.warn("xiaoxiang fock decrypt failed:", derr)
                        cb(nil, _("潇湘章节解密失败")); return
                    end
                    cb(text)
                end)
        end
        if chapter.font ~= true then run(nil); return end
        if type(font.fixedFontTtf) ~= "string" then
            logger.warn("xiaoxiang decrypt: fixedFontTtf missing")
            cb(nil, _("潇湘章节解密失败")); return
        end
        current = Request.get(font.fixedFontTtf, { timeout = require("http.timeout").net(1) }, function(ttf, ferr)
            if not ttf then cb(nil, ferr and tostring(ferr) or _("请求失败")); return end
            run(ttf)
        end)
    end
    current = call("/book/auth/download/v2/chapters", "",
        '{"cbid":"' .. book_id .. '","ccids":["' .. chapter_id .. '"]}', Client.cookie(), function(wire, err)
            if not wire then cb(nil, err); return end
            local text, kind, chapter = Mapper.content(wire)
            if text then cb(text); return end
            if kind == "encrypted" then decrypt(chapter); return end
            cb(nil, (not kind) and _("潇湘章节内容为空") or nil, kind --[[@as "unpaid"|nil]])
        end)
    return { cancel = function() if current then current:cancel() end end }
end

return Client
