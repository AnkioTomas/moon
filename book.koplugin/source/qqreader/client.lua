--[[--
QQ阅读 HTTP 客户端（仅异步）。

接口在 https://book.qq.com/api/ ，code 0 成功，-4 是登录失效（HTTP 仍是 200）。
目录和免费章匿名可读。付费章同样 code 0，但只有预览：chapterVipFlag=1 且 authStatus 不是 1。
encrypt / fontEncrypt 为真是字体加密，直接失败。
书架分页 pageNo / pageSize / hasNext，置顶和普通列表拼在一起。
进度只到章：POST bookshelf/update/reading/process，只传 bid 和 lastReadChapterId。

@module koplugin.book.source.qqreader.client
--]]

require("l10n").apply()
local JSON = require("json")
local Mapper = require("source.qqreader.mapper")
local Request = require("http.request")
local SourceBase = require("source.base")
local Text = require("utils.text")
local _ = require("gettext")

local Client = {}

local SOURCE_ID = "qqreader"
local WEB = "https://book.qq.com"
local API = WEB .. "/api"
local UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
    .. "Chrome/120.0.0.0 Safari/537.36"
local PAGE_SIZE = 100
local MAX_PAGES = 50
local AUTH_FAIL = -4

---@return string|nil
function Client.cookie()
    local cookie = require("utils.settings").getSource(SOURCE_ID).cookie
    return type(cookie) == "string" and cookie ~= "" and cookie or nil
end

---@param cookie string|nil
---@return table
local function headers(cookie)
    return {
        Cookie = cookie,
        ["User-Agent"] = UA,
        Referer = WEB .. "/book-shelf",
        Origin = WEB,
    }
end

---@param params table|nil
---@return string
local function query(params)
    local parts = {}
    for key, value in pairs(params or {}) do
        parts[#parts + 1] = Text.urlEncode(key) .. "=" .. Text.urlEncode(value)
    end
    table.sort(parts)
    return table.concat(parts, "&")
end

--- 书号 / 章号在官方请求里是数字。不是整数就原样当字符串。
---@param id string|number
---@return string|number
local function jsonId(id)
    local text = tostring(id)
    local n = tonumber(text)
    if n and n == math.floor(n) and tostring(math.floor(n)) == text then return n end
    return text
end

--- 登录态失效只标记当前已保存的 Cookie。
---@param cookie string|nil
---@param msg string
---@return string
local function expired(cookie, msg)
    if cookie and cookie ~= "" and cookie == Client.cookie() then
        return require("source.auth").expire(SOURCE_ID, msg)
    end
    return msg
end

---@param raw string|nil
---@param err any
---@param cookie string|nil
---@return table|nil wire
---@return string|nil err
local function decode(raw, err, cookie)
    if not raw then return nil, err and tostring(err) or _("请求失败") end
    local ok, wire = pcall(JSON.decode, raw)
    if not ok or type(wire) ~= "table" then return nil, _("响应无效") end
    if tonumber(wire.code) == 0 then
        if cookie and cookie == Client.cookie() then require("source.auth").ok(SOURCE_ID) end
        return wire
    end
    local msg = type(wire.msg) == "string" and wire.msg ~= "" and wire.msg or _("请求失败")
    if tonumber(wire.code) == AUTH_FAIL then msg = expired(cookie, _("QQ阅读登录已失效")) end
    return nil, msg
end

---@param method string
---@param path string
---@param params table|nil
---@param body string|nil
---@param cookie string|nil
---@param cb fun(wire: table|nil, err: string|nil)
---@return HttpJob
local function call(method, path, params, body, cookie, cb)
    local url = API .. path
    if params then url = url .. "?" .. query(params) end
    local opts = {
        accept = "application/json",
        headers = headers(cookie),
        timeout = require("http.timeout").net(1),
    }
    local function done(raw, err)
        cb(decode(raw, err, cookie))
    end
    if method == "POST" then
        opts.content_type = "application/json"
        return Request.post(url, body, opts, done)
    end
    return Request.get(url, opts, done)
end

---@param cookie string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Client.loginCheckAsync(cookie, cb)
    if type(cookie) ~= "string" or cookie == "" then
        return SourceBase.defer(cb, nil, _("没有读到 Cookie"))
    end
    return call("GET", "/user/homepage", nil, nil, cookie, function(wire, err)
        if not wire or type(wire.data) ~= "table" then
            cb(nil, err or _("QQ阅读登录已失效"))
            return
        end
        cb(true)
    end)
end

--- 拉书架。每页把置顶和普通列表拼上，hasNext 为假或空页就停。
---@param cookie string
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return { cancel: fun() }
function Client.shelfAsync(cookie, cb)
    if type(cookie) ~= "string" or cookie == "" then
        return SourceBase.defer(cb, nil, _("未登录 QQ阅读"))
    end
    local cancelled, job, books, seen = false, nil, {}, {}
    local function add(list)
        local n = 0
        for _idx, row in ipairs(type(list) == "table" and list or {}) do
            local id = row.bid and tostring(row.bid)
            if id and not seen[id] then
                seen[id] = true
                books[#books + 1] = row
                n = n + 1
            end
        end
        return n
    end
    local function page(n)
        if cancelled then return end
        if n > MAX_PAGES then cb(books); return end
        job = call("GET", "/bookshelf/query", { pageNo = n, pageSize = PAGE_SIZE }, nil, cookie, function(wire, err)
            if cancelled then return end
            if not wire then cb(nil, err); return end
            local data = type(wire.data) == "table" and wire.data or {}
            local added = add(data.topBookList) + add(data.bookList)
            local more = data.hasNext == true or tonumber(data.hasNext) == 1
            if not more or added == 0 then cb(books) else page(n + 1) end
        end)
    end
    page(1)
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
end

---@param book_id string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Client.addAsync(book_id, cb)
    local cookie = Client.cookie()
    if not cookie then return SourceBase.defer(cb, nil, _("未登录 QQ阅读")) end
    return call("POST", "/bookshelf/add", nil, JSON.encode({ bid = jsonId(book_id) }), cookie, function(wire, err)
        cb(wire and true or nil, err)
    end)
end

---@param book_id string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Client.removeAsync(book_id, cb)
    local cookie = Client.cookie()
    if not cookie then return SourceBase.defer(cb, nil, _("未登录 QQ阅读")) end
    return call("POST", "/bookshelf/delete", nil, JSON.encode({ bids = { jsonId(book_id) } }), cookie, function(wire, err)
        cb(wire and true or nil, err)
    end)
end

--- 上报读到哪一章。不传 lastReadOffset：官方更新也不传。
---@param book_id string
---@param chapter_id string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Client.updateReadAsync(book_id, chapter_id, cb)
    local cookie = Client.cookie()
    if not cookie then return SourceBase.defer(cb, nil, _("未登录 QQ阅读")) end
    return call("POST", "/bookshelf/update/reading/process", nil, JSON.encode({
        bid = jsonId(book_id),
        lastReadChapterId = jsonId(chapter_id),
    }), cookie, function(wire, err)
        cb(wire and true or nil, err)
    end)
end

--- 搜索：官网没有 JSON 搜索接口，取服务端渲染的 /so/<关键词> 页（匿名，一页 10 条）。
---@param keyword string
---@param cb fun(books: Book[]|nil, err: string|nil)
---@return HttpJob
function Client.searchAsync(keyword, cb)
    return Request.get(WEB .. "/so/" .. Text.urlEncode(keyword), {
        headers = headers(nil),
        timeout = require("http.timeout").net(1),
    }, function(raw, err)
        if not raw then cb(nil, err and tostring(err) or _("请求失败")); return end
        cb(Mapper.searchHtml(raw))
    end)
end

---@param book_id string
---@param cb fun(info: table|nil, err: string|nil)
---@return HttpJob
function Client.detailAsync(book_id, cb)
    return call("GET", "/book/detail", { bid = book_id }, nil, Client.cookie(), function(wire, err)
        if not wire then cb(nil, err); return end
        local info = wire.data
        if type(info) ~= "table" or not info.title then cb(nil, _("QQ阅读书籍信息为空")); return end
        cb(info)
    end)
end

---@param book_id string
---@param cb fun(rows: table|nil, err: string|nil)
---@return HttpJob
function Client.catalogAsync(book_id, cb)
    return call("GET", "/book/detail/chapters", { bid = book_id }, nil, Client.cookie(), function(wire, err)
        if not wire then cb(nil, err); return end
        if type(wire.data) ~= "table" then cb(nil, _("QQ阅读目录为空")); return end
        cb(wire.data)
    end)
end

--- 一章正文。未授权的付费章只有预览，字体加密的章直接失败。
---@param book_id string
---@param chapter_id string
---@param cb fun(text: string|nil, err: string|nil)
---@return HttpJob
function Client.contentAsync(book_id, chapter_id, cb)
    return call("GET", "/book/read", { bid = book_id, cid = chapter_id }, nil, Client.cookie(), function(wire, err)
        if not wire then cb(nil, err); return end
        local info = wire.data
        if Mapper.encrypted(info) then cb(nil, _("QQ阅读章节已加密")); return end
        if Mapper.locked(info) then cb(nil, _("QQ阅读 VIP 章节未购买")); return end
        local text = type(info) == "table" and info.content
        if type(text) ~= "string" or Text.trim(text) == "" then cb(nil, _("QQ阅读章节内容为空")); return end
        cb(text)
    end)
end

return Client
