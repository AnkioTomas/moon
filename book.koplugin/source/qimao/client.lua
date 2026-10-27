--[[--
七猫 App 接口 HTTP 客户端（匿名，无账号；仅异步）。

账号 / 书架走 PC 网页接口（`Authorization: <token>` + 表单，无签名）；搜索、目录、正文走匿名 App 接口。
接口回包形如 `{ data = … }`，出错为 `{ errors = { code, title } }`（HTTP 状态仍是 200）。

@module koplugin.book.source.qimao.client
--]]

local JSON = require("json")
local Protocol = require("source.qimao.protocol")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("gettext")

local Client = {}

--- 解回包：data 在才算成功；errors.title 是服务端给的人话。
---@param raw string|nil
---@param err any
---@return table|nil, string|nil
function Client.decode(raw, err)
    if not raw then return nil, err and tostring(err) or _("请求失败") end
    local ok, wire = pcall(JSON.decode, raw)
    if not ok or type(wire) ~= "table" then return nil, _("响应无效") end
    if type(wire.data) ~= "table" then
        return nil, wire.errors and wire.errors.title or _("请求失败")
    end
    return wire
end

local SOURCE_ID = "qimao"
local USER = "https://xiaoshuo.wtzw.com"
local SHELF = "https://api-bs.wtzw.com"
local SHELF_PAGE_SIZE = 50
-- 服务端拒绝登录态的错误码（见网页拦截器）与文案。
local AUTH_CODES = { ["40001002"] = true, ["40003002"] = true }

---@return string|nil
function Client.token()
    local token = require("utils.settings").getSource(SOURCE_ID).token
    return type(token) == "string" and token ~= "" and token or nil
end

--- 账号接口回包：无 errors.code 即成功（同步类接口 data 可能为空串）。
---@param token_checked string 本次请求用的 token（校验新 token 时不能污染已有登录态）
---@param raw string|nil
---@param err any
---@return table|nil, string|nil
local function decodeAccount(raw, err, token_checked)
    if not raw then return nil, err and tostring(err) or _("请求失败") end
    local ok, wire = pcall(JSON.decode, raw)
    if not ok or type(wire) ~= "table" then return nil, _("响应无效") end
    local errors = wire.errors
    if type(errors) == "table" and errors.code then
        local title = errors.title or _("请求失败")
        if token_checked == Client.token()
            and (AUTH_CODES[tostring(errors.code)] or tostring(title):find("登录", 1, true)) then
            return nil, require("source.auth").expire(SOURCE_ID, _("七猫登录已失效，请重新登录"))
        end
        return nil, title
    end
    if token_checked == Client.token() then require("source.auth").ok(SOURCE_ID) end
    return wire
end

---@param url string
---@param form table<string, any>
---@param token string
---@param cb fun(wire: table|nil, err: string|nil)
---@return HttpJob
local function post(url, form, token, cb)
    return Request.post(url, Text.formEncode(form), {
        accept = "application/json",
        headers = { Authorization = token },
        content_type = "application/x-www-form-urlencoded",
        timeout = require("http.timeout").net(0.5),
    }, function(raw, err) cb(decodeAccount(raw, err, token)) end)
end

--- 校验 token 并取账号信息（登录入口用，token 由调用方显式给）。
---@param token string
---@param cb fun(user: table|nil, err: string|nil)
---@return HttpJob
function Client.userInfoAsync(token, cb)
    return post(USER .. "/api/pc/v1/user/get-user-info", {}, token, function(wire, err)
        if not wire then cb(nil, err); return end
        if type(wire.data) ~= "table" then cb(nil, _("七猫账号信息为空")); return end
        cb(wire.data)
    end)
end

--- 拉完整个人书架（分页），回调书行数组。
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return { cancel: fun() }
function Client.shelfSyncAsync(cb)
    local token = Client.token()
    if not token then return require("source.base").defer(cb, nil, _("未登录七猫")) end
    local cancelled, job, rows = false, nil, {}
    local function page(n)
        job = post(SHELF .. "/pcapi/v1/user/local", { page = n, size = SHELF_PAGE_SIZE }, token, function(wire, err)
            if cancelled then return end
            if not wire then cb(nil, err); return end
            local data = type(wire.data) == "table" and wire.data or {}
            for _idx, row in ipairs(type(data.books) == "table" and data.books or {}) do rows[#rows + 1] = row end
            local total = type(data.meta) == "table" and tonumber(data.meta.total_pages) or 0
            if n < total then page(n + 1) else cb(rows) end
        end)
    end
    page(1)
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
end

--- 书架增删上行；items 是网页同款条目（push_type 1 = 加 / 改，2 = 删）。
---@param items table[]
---@param cb fun(wire: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client.shelfPushAsync(items, cb)
    local token = Client.token()
    if not token then return require("source.base").defer(cb, nil, _("未登录七猫")) end
    return post(SHELF .. "/pcapi/v2/user/sync", { items = JSON.encode(items) }, token, cb)
end

---@param base string
---@param path string
---@param params table<string, any>
---@param book_id string|nil 请求头版本号按它挑
---@param cb fun(wire: table|nil, err: string|nil)
---@return HttpJob
local function get(base, path, params, book_id, cb, cache_ttl)
    return Request.get(Protocol.url(base, path, params), {
        accept = "application/json",
        headers = Protocol.headers(book_id),
        allow_redirects = true,
        timeout = require("http.timeout").net(0.5),
        cache_ttl = cache_ttl,
    }, function(raw, err) cb(Client.decode(raw, err)) end)
end

---@param keyword string
---@param page integer
---@param cb fun(wire: table|nil, err: string|nil)
---@return HttpJob
function Client.searchAsync(keyword, page, cb)
    return get(Protocol.BC, "/search/v1/words", {
        extend = "", tab = "0", gender = "0", refresh_state = "8",
        page = page, wd = keyword, is_short_story_user = "0",
    }, nil, cb)
end

local WWW = "https://www.qimao.com"

---@param path string
---@param params table<string, any>|nil
---@param cb fun(wire: table|nil, err: string|nil)
---@return HttpJob
local function wwwGet(path, params, cb)
    local url = WWW .. path
    if params then url = url .. "?" .. Text.formEncode(params) end
    return Request.get(url, {
        accept = "application/json",
        headers = { Referer = WWW .. "/shuku/a-a-a-a-a-a-a-click-1/" },
        timeout = require("http.timeout").net(0.5),
    }, function(raw, err) cb(Client.decode(raw, err)) end)
end

--- 书库筛选项：频道、排序、分类树（匿名网页接口）。
---@param cb fun(wire: table|nil, err: string|nil)
---@return HttpJob
function Client.classifyOptionsAsync(cb)
    return wwwGet("/api/classify/select-option", nil, cb)
end

--- 书库列表一页（15 本）。query: channel / category1 / category2 / order / page。
---@param query table<string, any>
---@param cb fun(wire: table|nil, err: string|nil)
---@return HttpJob
function Client.classifyAsync(query, cb)
    return wwwGet("/api/classify/book-list", {
        channel = query.channel, category1 = query.category1, category2 = query.category2,
        order = query.order, page = query.page, words = "a", update_time = "a", is_vip = "a", is_over = "a",
    }, cb)
end

---@param book_id string
---@param cb fun(wire: table|nil, err: string|nil)
---@return HttpJob
function Client.detailAsync(book_id, cb)
    return get(Protocol.BC, "/api/v4/book/detail", { id = book_id, imei_ip = "2937357107", teeny_mode = "0" }, book_id, cb)
end

---@param book_id string
---@param cb fun(wire: table|nil, err: string|nil)
---@return HttpJob
function Client.chaptersAsync(book_id, cb)
    return get(Protocol.KS, "/api/v1/chapter/chapter-list", { chapter_ver = "0", id = book_id }, book_id, cb)
end

--- 一章正文，已解密的纯文本（段落以换行分隔）。
---@param book_id string
---@param chapter_id string
---@param cb fun(text: string|nil, err: string|nil)
---@return HttpJob
function Client.contentAsync(book_id, chapter_id, cb)
    return get(Protocol.KS, "/api/v1/chapter/content", { id = book_id, chapterId = chapter_id }, book_id, function(wire, err)
        local content = wire and wire.data.content
        if type(content) ~= "string" or content == "" then
            cb(nil, err or _("七猫章节内容为空"))
            return
        end
        local text, decrypt_err = Protocol.decrypt(content)
        if not text then
            require("utils.log").warn("qimao decrypt failed", book_id, chapter_id, decrypt_err)
            cb(nil, decrypt_err); return
        end
        cb(text)
    end)
end

return Client
