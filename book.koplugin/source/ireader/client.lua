--[[--
掌阅网页接口。

登录、书架、目录、进度、正文走 PC 站（api-pc.zhangyue.com，正文在 pc.ireader.com/nsr）。
设备参数 p29/p2/p3/p4/p33 来自 PC 站运行时配置，每次请求都带，和网页 axios 拦截器一致。
书城搜索与频道是手机站 m.zhangyue.com 的页面，不走这套 JSON。

登录态是扫码回包里的 usr（账号名）和 zysid（session_id）。网页没有移出书架的接口。

@module source.ireader.client
--]]

require("l10n").apply()
local JSON = require("json")
local Mapper = require("source.ireader.mapper")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("gettext")

local Client = {}

local SOURCE_ID = "ireader"
local API = "https://api-pc.zhangyue.com"
local WEB = "https://pc.ireader.com"
local STORE = "https://m.zhangyue.com"
local SUCCESS = 0
local LOGIN_EXPIRED = 600001
local HAS_IN_SHELF = 100011
local FEE_WHOLE = 10
local DEVICE = {
    p29 = "zye5b814",
    p2 = "104583",
    p3 = "101010010",
    p4 = "501603",
    p33 = "com.chaozh.iReaderFree",
}

---@type table<string, number>
local fee_unit = {}

---@return { usr: string, zysid: string, name: string|nil, avatar: string|nil }|nil
function Client.session()
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    local usr = type(cfg.usr) == "string" and cfg.usr or ""
    local zysid = type(cfg.zysid) == "string" and cfg.zysid or ""
    if usr == "" or zysid == "" then return nil end
    return { usr = usr, zysid = zysid, name = cfg.name, avatar = cfg.avatar }
end

---@param session table|nil
---@param params table|nil
---@return string
local function query(session, params)
    local form = {
        usr = session and session.usr or "",
        zysid = session and session.zysid or "",
    }
    for key, value in pairs(DEVICE) do form[key] = value end
    for key, value in pairs(params or {}) do form[key] = value end
    return Text.formEncode(form)
end

---@param path string
---@param session table|nil
---@param params table|nil
---@return string
local function url(path, session, params)
    local base = path
    if path:sub(1, 5) == "/nsr/" then
        base = WEB .. path
    elseif not path:find("^https?://") then
        base = API .. path
    end
    return base .. "?" .. query(session, params)
end

--- 解 PC 站统一封套。code 0 的 body 可能再套一层 JSON 字符串。
---@param wire table
---@param session table|nil
---@return any|nil
---@return string|nil
local function bodyOf(wire, session)
    local code = tonumber(wire.code)
    if code == SUCCESS or (code == nil and type(wire.bookContent) == "string") then
        if type(wire.bookContent) == "string" then return wire end
        local body = wire.body
        if type(body) == "string" then
            local ok, inner = pcall(JSON.decode, body)
            if ok and inner ~= nil then body = inner end
        end
        if session then require("source.auth").ok(SOURCE_ID) end
        if body == nil then return true end
        return body
    end
    if code == LOGIN_EXPIRED and session then
        return nil, require("source.auth").expire(SOURCE_ID, _("掌阅登录已失效，请点「重新登录」，用掌阅 App 扫码。"))
    end
    if code == 100001 and not session then return nil, _("未登录掌阅") end
    return nil, type(wire.msg) == "string" and wire.msg ~= "" and wire.msg or _("请求失败")
end

---@param raw string|nil
---@param err any
---@return table|nil
---@return string|nil
local function envelope(raw, err)
    if not raw then return nil, err and tostring(err) or _("请求失败") end
    local ok, wire = pcall(JSON.decode, raw)
    if not ok or type(wire) ~= "table" then return nil, _("响应无效") end
    return wire
end

---@param path string
---@param params table|nil
---@param cb fun(body: any, err: string|nil)
---@return HttpJob
function Client.get(path, params, cb)
    local session = Client.session()
    return Request.get(url(path, session, params), {
        accept = "application/json",
        timeout = require("http.timeout").net(0.5),
    }, function(raw, err)
        local wire, reason = envelope(raw, err)
        if not wire then cb(nil, reason); return end
        local body, message = bodyOf(wire, session)
        cb(body, message)
    end)
end

---@param path string
---@param params table|nil
---@param payload string
---@param content_type string
---@param cb fun(body: any, err: string|nil)
---@return HttpJob
local function post(path, params, payload, content_type, cb)
    local session = Client.session()
    return Request.post(url(path, session, params), payload, {
        accept = "application/json",
        content_type = content_type,
        timeout = require("http.timeout").net(0.5),
    }, function(raw, err)
        local wire, reason = envelope(raw, err)
        if not wire then cb(nil, reason); return end
        local body, message = bodyOf(wire, session)
        cb(body, message)
    end)
end

---@param fields { name: string, value: string }[]
---@return string body
---@return string content_type
local function multipart(fields)
    local boundary = "----moonireader"
    local parts = {}
    for _idx, field in ipairs(fields) do
        parts[#parts + 1] = "--" .. boundary
            .. '\r\nContent-Disposition: form-data; name="' .. field.name .. '"\r\n\r\n' .. field.value
    end
    parts[#parts + 1] = "--" .. boundary .. "--\r\n"
    return table.concat(parts, "\r\n"), "multipart/form-data; boundary=" .. boundary
end

---@param cb fun(code: string|nil, err: string|nil)
---@return HttpJob
function Client.qrCreateAsync(cb)
    return Client.get("/bookstore/open/user/qrcode/get", nil, function(body, err)
        local code = Mapper.qrCode(body)
        if not code then cb(nil, err or _("获取二维码失败")); return end
        cb(code)
    end)
end

--- 轮询不把「还没扫」当成失败。回包原样交给调用方。
---@param code string
---@param cb fun(wire: table|nil, err: string|nil)
---@return HttpJob
function Client.qrPollAsync(code, cb)
    return Request.get(url("/bookstore/open/user/qrcode/result", nil, { code = code }), {
        accept = "application/json",
        timeout = require("http.timeout").net(0.5),
    }, function(raw, err)
        local wire, reason = envelope(raw, err)
        cb(wire, reason)
    end)
end

---@param cb fun(body: table|nil, err: string|nil)
---@return HttpJob
function Client.shelfAsync(cb)
    return Client.get("/bookstore/open/cloud/bookshelf/list", nil, cb)
end

--- 新书插到未置顶书的最前：order 取当前最小再减一，和网页 insert 一致。
---@param rows table[]|nil
---@return integer order
---@return integer version
local function shelfCursor(rows, version)
    local order = nil
    for _idx, row in ipairs(type(rows) == "table" and rows or {}) do
        local value = tonumber(row.order)
        if row.top ~= 1 and value and (not order or value < order) then order = value end
    end
    return (order or 999999) - 1, tonumber(version) or 0
end

Client.shelfCursor = shelfCursor

---@param stable_id string
---@param title string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Client.addAsync(stable_id, title, cb)
    local session = Client.session()
    if not session then return require("source.base").defer(cb, nil, _("未登录掌阅")) end
    local handle = {}
    handle.job = Client.shelfAsync(function(shelf, err)
        if type(shelf) ~= "table" then cb(nil, err or _("请求失败")); return end
        local order, version = shelfCursor(shelf.data, shelf.current_version)
        local data = JSON.encode({ {
            dtype = 0,
            order = order,
            folder = "",
            md5 = "",
            top = 0,
            top_sort = 0,
            book_id = tostring(stable_id),
            book_name = title,
            book_type = 24,
            cover_name = "",
            is_local_book = false,
            book_file_id = "",
            book_file_size = 0,
            cover_file_id = "",
            cover_file_size = 0,
            folder_hierarchy = "[]",
        } })
        local payload, content_type = multipart({
            { name = "usr", value = session.usr },
            { name = "current_version", value = tostring(version) },
            { name = "type", value = "1" },
            { name = "data", value = data },
        })
        handle.job = Request.post(url("/bookstore/open/cloud/bookshelf/upsert", session), payload, {
            accept = "application/json",
            content_type = content_type,
            timeout = require("http.timeout").net(0.5),
        }, function(raw, post_err)
            local wire, reason = envelope(raw, post_err)
            if not wire then cb(nil, reason); return end
            local code = tonumber(wire.code)
            if code == SUCCESS or code == HAS_IN_SHELF then
                require("source.auth").ok(SOURCE_ID)
                cb(true)
                return
            end
            local _ignored, message = bodyOf(wire, session)
            cb(nil, message)
        end)
    end)
    return { cancel = function()
        if handle.job and handle.job.cancel then handle.job.cancel() end
    end }
end

---@param book_id string
---@param cb fun(body: table|nil, err: string|nil)
---@return HttpJob
function Client.detailAsync(book_id, cb)
    return Client.get("/bookstore/open/book/detail", { book_id = book_id }, function(body, err)
        if type(body) == "table" and body.fee_unit ~= nil then
            fee_unit[tostring(book_id)] = tonumber(body.fee_unit)
        end
        cb(body, err)
    end)
end

---@param book_id string
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return { cancel: fun() }
function Client.chaptersAsync(book_id, cb)
    local handle, rows = {}, {}
    local function nextPage(page)
        handle.job = Client.get("/bookstore/open/book/chapter/web/list", {
            book_id = book_id, page = page, size = 50,
        }, function(body, err)
            if type(body) ~= "table" then cb(nil, err); return end
            local list = type(body.list) == "table" and body.list or {}
            for _idx, row in ipairs(list) do rows[#rows + 1] = row end
            local total = type(body.page) == "table" and tonumber(body.page.totalPage) or page
            if page < total and #list > 0 then
                nextPage(page + 1)
                return
            end
            cb(rows)
        end)
    end
    nextPage(1)
    return { cancel = function()
        if handle.job and handle.job.cancel then handle.job.cancel() end
    end }
end

---@param book_id string
---@param chapter_id string
---@param cb fun(html: string|nil, err: string|nil, kind: "unpaid"|nil)
---@return HttpJob
function Client.contentAsync(book_id, chapter_id, cb)
    local whole = fee_unit[tostring(book_id)] == FEE_WHOLE
    return Client.get("/nsr/chapter-content", {
        book_id = book_id,
        chapter_id = chapter_id,
        is_whole_book = whole and "true" or "false",
    }, function(body, err)
        if type(body) ~= "table" then cb(nil, err); return end
        -- 免费章的 charging_info 是 JSON null，LuaJSON 解成函数，不能当成未购买。
        -- 未购买才是计费表，而且 is_buy 不为真。已购章也带这张表，正文仍在 bookContent。
        local info = body.charging_info
        local bought = type(info) == "table" and (info.is_buy == true or tonumber(info.is_buy) == 1)
        if type(info) == "table" and not bought then cb(nil, _("本章未购买"), "unpaid"); return end
        if type(body.bookContent) ~= "string" or body.bookContent == "" then
            cb(nil, _("响应无效"))
            return
        end
        cb(body.bookContent)
    end)
end

---@param book_id string
---@param cb fun(item: table|nil, err: string|nil)
---@return HttpJob
function Client.progressAsync(book_id, cb)
    return Client.get("/bookstore/open/cloud/book/getProgress", { bookIds = book_id }, function(body, err)
        if type(body) ~= "table" then cb(nil, err); return end
        local key = tostring(book_id)
        cb(body[key] or body[tonumber(key)])
    end)
end

---@param book_id string
---@param chapter_uid string
---@param total integer
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return HttpJob
function Client.putProgressAsync(book_id, chapter_uid, total, cb)
    local session = Client.session()
    if not session then return require("source.base").defer(cb, nil, _("未登录掌阅")) end
    local stored = math.max(0, (tonumber(chapter_uid) or 1) - 1)
    local now = os.time() * 1000
    local payload = JSON.encode({
        bookId = tostring(book_id),
        deviceName = "掌阅网页",
        updateTime = now,
        usr = session.usr,
        readProcess = {
            bookOverStatus = 0,
            totalCount = total,
            lastReadDate = now,
            readingSource = "web",
            chapterId = tostring(stored),
        },
    })
    return post("/bookstore/open/cloud/book/progress", nil, payload, "application/json", function(body, err)
        cb(body and true or nil, err)
    end)
end

local STORE_HEADERS = {
    ["User-Agent"] = "Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 Chrome/120.0.0.0 Mobile Safari/537.36",
}

---@param keyword string
---@param cb fun(html: string|nil, err: string|nil)
---@return HttpJob
function Client.searchAsync(keyword, cb)
    return Request.get(STORE .. "/search?" .. Text.formEncode({ keyWord = keyword }), {
        accept = "text/html",
        headers = STORE_HEADERS,
        timeout = require("http.timeout").net(0.5),
    }, function(raw, err) cb(raw, err and tostring(err) or nil) end)
end

---@param channel_id string
---@param cb fun(html: string|nil, err: string|nil)
---@return HttpJob
function Client.channelAsync(channel_id, cb)
    return Request.get(STORE .. "/channel/" .. channel_id, {
        accept = "text/html",
        headers = STORE_HEADERS,
        timeout = require("http.timeout").net(0.5),
    }, function(raw, err) cb(raw, err and tostring(err) or nil) end)
end

return Client
