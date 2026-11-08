--[[--
潇湘书院 HTTP 客户端（仅异步）。

搜索、分类走新站 JSON；详情走电脑官网 SSR，目录、旧榜单走移动官网（m.xxsy.net，匿名可读）。
账号、正文、书架、进度走新站 www.xxsypro.com 的 JSON 接口（阅文通行证，与起点同一套账号体系）：请求带登录 Cookie
（ywGuid / ywKey 等）和同值的 csrfToken（Cookie 与 `_csrfToken` 查询参数），回包 code 0 为成功。
匿名也能调，但书架是访客书架、没买的 VIP 章只回 130 字预览（auth=false），所以带登录态的操作先用 /user/auth/personal 确认 isLogin=1。
书 / 章 id 是 17 位整数，超出 double 精度，解码前先加引号。目录页上千章、1MB+，解析放子进程。

@module koplugin.book.source.xiaoxiang.client
--]]

local Job = require("workers.job")
local logger = require("utils.log")
local Mapper = require("source.xiaoxiang.mapper")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("l10n").get("source.xiaoxiang")

local Client = {}

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
local function page(url, cb)
    return Request.get(url, {
        headers = { ["User-Agent"] = UA },
        timeout = require("http.timeout").net(1),
    }, function(raw, err)
        if not raw then cb(nil, err and tostring(err) or _("请求失败")); return end
        cb(raw)
    end)
end

local SOURCE_ID = "xiaoxiang"
local API = "https://www.xxsypro.com/api"

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
    local wire, reason = Mapper.decode(raw)
    if not wire then cb(nil, reason); return end
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
    local url = API .. path .. "?" .. (query ~= "" and query .. "&" or "") .. "_csrfToken=" .. Text.urlEncode(csrf)
    local opts = {
        accept = "application/json",
        headers = { Cookie = cookie_header, Referer = "https://www.xxsypro.com/", ["User-Agent"] = UA },
        timeout = require("http.timeout").net(0.5),
        cache_ttl = 0,
    }
    if body then
        opts.content_type = "application/json"
        return Request.post(url, body, opts, function(raw, err) decode(raw, err, cb) end)
    end
    return Request.get(url, opts, function(raw, err) decode(raw, err, cb) end)
end

--- 账号信息：isLogin=1 才是真登录（失效的 Cookie 仍 code 0，只是 isLogin=0）。cookie 显式传入，登录入口先校验再保存。
---@param cookie string
---@param cb fun(info: table|nil, err: string|nil, kind: "auth"|nil)
---@return HttpJob
function Client.userAsync(cookie, cb)
    local cancelled = false
    local job = call("/user/auth/personal", "", nil, cookie, function(wire, err)
        if cancelled then return end
        local data = wire and wire.data
        if not wire then cb(nil, err); return end
        if type(data) ~= "table" then cb(nil, _("响应无效")); return end
        if tonumber(data.isLogin) == 0 then cb(nil, _("未登录潇湘"), "auth"); return end
        if tonumber(data.isLogin) ~= 1 then cb(nil, _("响应无效")); return end
        local guid = type(data.user) == "table" and data.user.guid
        local id = type(guid) == "number" and guid % 1 == 0 and string.format("%.0f", guid) or guid
        if type(id) ~= "string" or not id:match("^%d+$") or id:match("^0+$") then
            cb(nil, _("潇湘账号标识缺失")); return
        end
        cb({ isLogin = 1, id = id })
    end)
    return { cancel = function()
        cancelled = true
        if job then job:cancel() end
    end }
end

--- 同一 Cookie 校验通过后多久内不再问个人接口：每章翻页都报进度，次次先打一遍个人接口是双倍请求。
Client.AUTH_TTL = 10 * 60
---@type { cookie: string|nil, at: integer } 最近一次通过校验的 Cookie 与时刻
local verified = { cookie = nil, at = 0 }

--- 带登录态的调用：先确认 isLogin=1（AUTH_TTL 内同一 Cookie 只确认一次），失效就标记登出，免得访客书架被当成真实书架。
---@param path string
---@param query string
---@param body string|nil
---@param cb fun(wire: table|nil, err: string|nil)
---@return { cancel: fun() }
local function authed(path, query, body, cb)
    local cookie = Client.cookie()
    if not cookie then return require("source.base").defer(cb, nil, _("未登录潇湘")) end
    local cancelled, job = false, nil
    local function done(wire, err)
        if cancelled then return end
        if Client.cookie() ~= cookie then cb(nil, _("账号已变化，请重新登录")); return end
        cb(wire, err)
    end
    if cookie and cookie == verified.cookie and os.time() - verified.at < Client.AUTH_TTL then
        job = call(path, query, body, cookie, done)
    else
        local pending = true
        local check = Client.userAsync(cookie, function(info, err, kind)
            pending = false
            if cancelled then return end
            if Client.cookie() ~= cookie then done(nil); return end
            if not info then
                if kind == "auth" then
                    verified.cookie = nil
                    err = require("source.auth").expire(SOURCE_ID,
                        _("潇湘登录已失效，请点「重新登录」，用 QQ阅读或起点 App 扫码。也可在账号设置里粘贴 Cookie。"))
                end
                done(nil, err)
                return
            end
            verified.cookie, verified.at = cookie, os.time()
            require("source.auth").ok(SOURCE_ID)
            job = call(path, query, body, cookie, done)
        end)
        if pending then job = check end
    end
    return { cancel = function()
        cancelled = true
        if job then job:cancel() end
    end }
end

--- 书架（只收根目录的书，resType 1），翻页收齐。
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return { cancel: fun() }
function Client.shelfAsync(cb)
    ---@type table[], boolean, CancelHandle|nil
    local rows, cancelled, job = {}, false, nil
    local cookie = Client.cookie()
    local function more(page)
        local pending = true
        local request = authed("/bookshelf/pc/page", "pageIndex=" .. page .. "&pageSize=20", nil, function(wire, err)
            pending = false
            if cancelled then return end
            if Client.cookie() ~= cookie then cb(nil, _("账号已变化，请重新登录")); return end
            local data = wire and wire.data
            if type(data) ~= "table" or type(data.data) ~= "table" or not tonumber(data.pageCount) then
                cb(nil, err or _("响应无效")); return
            end
            for _idx, row in ipairs(data.data) do
                if type(row) ~= "table" then cb(nil, _("响应无效")); return end
                if tonumber(row.restype) == 1 and tonumber(row.groupId) == -100 then
                    if type(row.bookid) ~= "string" or not row.bookid:match("^%d+$") then
                        cb(nil, _("响应无效")); return
                    end
                    rows[#rows + 1] = row
                end
            end
            if page < (tonumber(data.pageCount) or 0) then
                more(page + 1)
                return
            end
            cb(rows)
        end)
        if pending then job = request end
    end
    more(1)
    return { cancel = function()
        cancelled = true
        if job then job:cancel() end
    end }
end

---@param book_id string
---@return string
local function shelfBody(book_id, extra)
    return '{"groupInfo":[{"groupId":-100,"books":[{"bookId":"' .. book_id .. '","resType":1' .. extra .. "}]}]}"
end

--- 成功码不够：回读根书架，确认成员或章节确实收敛后才让调用方清脏行。
local function confirmShelf(path, query, body, book_id, expected, cb)
    local cancelled, job, pending = false, nil, true
    local initial = authed(path, query, body, function(wire, err)
        pending = false
        if cancelled then return end
        if not wire then cb(nil, err); return end
        job = Client.shelfAsync(function(rows, reason)
            if cancelled then return end
            if not rows then cb(nil, reason); return end
            local matched
            for _idx, row in ipairs(rows) do if tostring(row.bookid) == book_id then matched = row end end
            local confirmed = expected == false and not matched
                or expected == true and matched ~= nil
                or type(expected) == "string" and matched and tostring(matched.ccid) == expected
            if not confirmed then cb(nil, _("潇湘远端状态未更新，请稍后重试")); return end
            cb(wire)
        end)
    end)
    if pending then job = initial end
    return { cancel = function()
        cancelled = true
        if job then job:cancel() end
    end }
end

---@param book_id string
---@param cb fun(wire: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client.shelfAddAsync(book_id, cb)
    return confirmShelf("/bookshelf/add", "",
        shelfBody(book_id, ',"ccid":"0","offset":0,"updatetime":' .. os.time() * 1000), book_id, true, cb)
end

---@param book_id string
---@param cb fun(wire: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client.shelfRemoveAsync(book_id, cb)
    return confirmShelf("/bookshelf/delete", "", shelfBody(book_id, ""), book_id, false, cb)
end

--- 记「读到这一章」：书架行的 ccid 就是它。
---@param book_id string
---@param chapter_id string
---@param cb fun(wire: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client.progressAsync(book_id, chapter_id, cb)
    return confirmShelf("/bookshelf/readingProcess/add", "bookId=" .. book_id, '{"books":[{"resType":1,"bookId":"' .. book_id
        .. '","updatetime":' .. os.time() * 1000 .. ',"ccid":"' .. chapter_id .. '","offset":0}]}', book_id, chapter_id, cb)
end

---@param keyword string
---@param cb fun(books: Book[]|nil, err: string|nil)
---@return { cancel: fun() }
function Client.searchAsync(keyword, cb)
    return require("source.browse").pages(function(index, done)
        return call("/xxsy/bookstore/web/search", "key=" .. Text.urlEncode(keyword)
            .. "&start=" .. (index - 1) * 20 .. "&n=20", nil, nil, function(wire, err)
            local data = wire and type(wire.data) == "table" and wire.data.searchData
            if type(data) ~= "table" or not tonumber(data.total) then done(nil, err or _("响应无效")); return end
            local books, reason = Mapper.books(data.cardList)
            done(books, reason, index * 20 < tonumber(data.total))
        end)
    end, 60, {}, function(result, err)
        cb(result and result.data, err)
    end)
end

function Client.libraryAsync(params, index, cb)
    local tag = params.tag
    local filters = { tag, params.state, params.charge, params.update, params.words, params.order }
    return call("/xxsy/bookstore/library/v1/web/search",
        "action=" .. (tag == -1 and "category" or "tag") .. "&categoryid=" .. params.category
        .. "&actionTag=" .. Text.urlEncode(table.concat(filters, ","))
        .. "&start=" .. (index - 1) * 20 .. "&n=20", nil, nil, cb)
end

function Client.detailAsync(book_id, cb)
    return page("https://www.xxsypro.com/book/" .. book_id, function(html, err)
        if not html then cb(nil, err); return end
        local book, reason = Mapper.detail(html)
        if book and book.stable_id ~= book_id then cb(nil, _("响应无效")); return end
        cb(book, reason)
    end)
end

--- 榜单页（一页 20 本）；name 是手机站 /rank/<name>。
---@param name string
---@param cb fun(books: Book[]|nil, err: string|nil)
---@param title string|nil SSR 栏目名，旧调用不传时仍解析 HTML
---@return HttpJob
function Client.rankAsync(name, cb, title)
    return page("https://m.xxsy.net/rank/" .. name, function(html, err)
        if not html then cb(nil, err); return end
        cb(Mapper.rank(html, title))
    end)
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
    local pending = true
    local request = page(url, function(html, err)
        pending = false
        if cancelled then return end
        if not html then cb(nil, err); return end
        job = Job.run(function()
            local value, reason = parse(html)
            return { value = value, err = reason }
        end, {
            name = name,
            kind = "light",
            timeout = 60,
            on_done = function(res)
                if cancelled then return end
                cb(res.value, res.err)
            end,
            on_failed = function(reason) if not cancelled then cb(nil, tostring(reason)) end end,
            on_cancelled = function() end,
        })
    end)
    if pending then job = request end
    return { cancel = function()
        cancelled = true
        if job then job:cancel() end
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
    local current, cancelled = nil, false
    local cookie = Client.cookie()
    local function done(text, err, kind)
        if cancelled then return end
        if Client.cookie() ~= cookie then cb(nil, _("账号已变化，请重新登录")); return end
        cb(text, err, kind)
    end
    -- 已购 VIP 章是 Fock 加密 + 乱序字体：fkp 是 `window.onkeyfocus("<密钥池>", <版本>)` 的 base64（只取参数不执行），用户密钥是 Cookie 的 ywGuid
    local function decrypt(chapter)
        local keypool, version = Text.base64Decode(tostring(chapter.fkp or ""))
            :match('onkeyfocus%("([^"]+)",%s*(%d+)%)')
        local uid = (cookie or ""):lower():match("ywguid=(%d+)")
        local font = type(chapter.fontResponse) == "table" and chapter.fontResponse or {}
        if not (keypool and version and uid and type(chapter.chapterContent) == "string") then
            logger.warn("xiaoxiang decrypt inputs missing: keypool", keypool ~= nil, "version", version ~= nil,
                "uid", uid ~= nil, "content", type(chapter.chapterContent))
            done(nil, _("潇湘章节解密失败")); return
        end
        local function run(fixed_font)
            local pending = true
            local job = require("source.xiaoxiang.fock").chapterAsync(chapter, fixed_font, chapter_id, keypool, version,
                uid, function(text, derr)
                    pending = false
                    if cancelled then return end
                    current = nil
                    if not text then
                        logger.warn("xiaoxiang fock decrypt failed:", derr)
                        done(nil, _("潇湘章节解密失败")); return
                    end
                    done(text)
                end)
            if pending then current = job end
        end
        if chapter.font ~= true then run(nil); return end
        if type(font.fixedFontTtf) ~= "string" then
            logger.warn("xiaoxiang decrypt: fixedFontTtf missing")
            done(nil, _("潇湘章节解密失败")); return
        end
        local pending = true
        local request = Request.get(font.fixedFontTtf, { timeout = require("http.timeout").net(1) }, function(ttf, ferr)
            pending = false
            if cancelled then return end
            if Client.cookie() ~= cookie then done(nil); return end
            if not ttf then done(nil, ferr and tostring(ferr) or _("请求失败")); return end
            if not require("source.yuewen_fonts").looksLikeFont(ttf) then
                logger.warn("xiaoxiang font download invalid:", #ttf, tostring(ttf:sub(1, 16)))
                done(nil, _("潇湘章节解密失败")); return
            end
            run(ttf)
        end)
        if pending then current = request end
    end
    local pending = true
    local request = call("/book/auth/download/v2/chapters", "",
        '{"cbid":"' .. book_id .. '","ccids":["' .. chapter_id .. '"]}', cookie, function(wire, err)
            pending = false
            if cancelled then return end
            if Client.cookie() ~= cookie then done(nil); return end
            if not wire then done(nil, err); return end
            local contents = type(wire.data) == "table" and wire.data.chapterContents
            local chapter = type(contents) == "table" and contents[1]
            if type(chapter) ~= "table" or tostring(chapter.ccid) ~= chapter_id then
                done(nil, _("响应无效")); return
            end
            local text, kind, chapter = Mapper.content(wire)
            if text then done(text); return end
            if kind == "encrypted" then decrypt(chapter); return end
            done(nil, (not kind) and _("潇湘章节内容为空") or nil, kind --[[@as "unpaid"|nil]])
        end)
    if pending then current = request end
    return { cancel = function()
        cancelled = true
        if current then current:cancel() end
    end }
end

return Client
