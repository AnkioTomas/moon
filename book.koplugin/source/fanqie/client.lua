--[[--
番茄小说官方 HTTP 客户端。

这里只调用 fanqienovel.com 的官方接口。扫码 Cookie 由 auth.lua 管理，
本模块只负责把配置中的 Cookie 放进请求头并返回 wire 数据。

@module koplugin.book.source.fanqie.client
--]]

require("l10n").apply()
local JSON = require("json")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("gettext")

local Client = {}
Client.__index = Client

local BASE = "https://fanqienovel.com"
local BOOK_PAGE = BASE .. "/page/"
local SHELF = BASE .. "/reading/bookapi/bookshelf/info/v:version/"
local SHELF_DETAIL = BASE .. "/api/bookshelf/multidetail"
local PROGRESS = BASE .. "/api/reader/book/progress"
local UPDATE_PROGRESS = BASE .. "/api/reader/book/update_progress"
local DIRECTORY = BASE .. "/api/reader/directory/detail"
local CONTENT = BASE .. "/api/reader/chapter/content"
local USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    .. "(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0"

local AUTH_CODES = { [-2012] = true, [-2041] = true }

---@param value any
---@return string|nil
function Client.bookId(value)
    if value == nil then return nil end
    local text = Text.trim(value)
    local id = text:match("fanqienovel%.com/page/(%d+)")
        or text:match("fanqienovel%.com/reader/(%d+)")
        or text:match("fqnovel%.com/page/(%d+)")
        or text:match("fqnovel%.com/reader/(%d+)")
    return id or text:match("^%d+$")
end

---@param cfg table|nil
---@return FanqieClient
function Client:new(cfg)
    return setmetatable(cfg or {}, self)
end

---@return boolean
function Client:configured()
    local cookies = self.cookies
    return type(cookies) == "table"
        and type(cookies.sessionid) == "string"
        and cookies.sessionid ~= ""
end

---@param referer string
---@return table
function Client:headers(referer)
    local parts = {}
    for key, value in pairs(self.cookies or {}) do
        if value ~= nil and tostring(value) ~= "" then
            parts[#parts + 1] = tostring(key) .. "=" .. tostring(value)
        end
    end
    table.sort(parts)
    return {
        ["Accept"] = "application/json, text/plain, */*",
        ["Accept-Language"] = "zh-CN,zh;q=0.9",
        ["Referer"] = referer,
        ["User-Agent"] = USER_AGENT,
        ["Cookie"] = #parts > 0 and table.concat(parts, "; ") or nil,
    }
end

---@param raw string|nil
---@param err any
---@param fallback string
---@return table|nil, string|nil
local function decodeJson(raw, err, fallback)
    if not raw then return nil, tostring(err or fallback) end
    local ok, value = pcall(JSON.decode, raw)
    if not ok or type(value) ~= "table" then return nil, fallback end
    return value
end

---@param wire table
---@return string|nil
local function wireError(wire)
    if type(wire) ~= "table" then return nil end
    local code = tonumber(wire.code or wire.errCode or wire.errcode)
    local message = tostring(wire.message or wire.msg or wire.errMsg or wire.errmsg or "")
    if AUTH_CODES[code] or message:find("登录", 1, true) then
        return _("番茄登录已失效，请重新扫码")
    end
    if code and code ~= 0 and code ~= 200 then
        return message ~= "" and message or (_("番茄小说请求失败") .. " (" .. tostring(code) .. ")")
    end
end

---@param url string
---@param query table|nil
---@return string
local function withQuery(url, query)
    local encoded = Text.formEncode(query)
    return encoded == "" and url or url .. (url:find("?", 1, true) and "&" or "?") .. encoded
end

---@param path string
---@param query table|nil
---@param referer string
---@param cb fun(wire: table|nil, err: string|nil)
---@return table
function Client:getJsonAsync(path, query, referer, cb)
    return Request.get(withQuery(path, query), {
        headers = self:headers(referer),
        allow_redirects = false,
    }, function(raw, err, response)
        if not raw then
            local code = response and tonumber(response.code)
            if code == 401 or code == 403 then
                cb(nil, _("番茄登录已失效，请重新扫码"))
            else
                cb(nil, tostring(err or _("番茄小说请求失败")))
            end
            return
        end
        local wire, decode_err = decodeJson(raw, nil, _("番茄小说响应无效"))
        if not wire then cb(nil, decode_err); return end
        cb(wire, wireError(wire))
    end)
end

---@param path string
---@param body table
---@param referer string
---@param cb fun(wire: table|nil, err: string|nil)
---@return table
function Client:postJsonAsync(path, body, referer, cb)
    local ok, raw_body = pcall(JSON.encode, body)
    if not ok then
        cb(nil, _("番茄小说请求参数无效"))
        return { cancel = function() end }
    end
    return Request.post(path, raw_body, {
        headers = self:headers(referer),
        content_type = "application/json",
        allow_redirects = false,
    }, function(raw, err, response)
        if not raw then
            local code = response and tonumber(response.code)
            if code == 401 or code == 403 then
                cb(nil, _("番茄登录已失效，请重新扫码"))
            else
                cb(nil, tostring(err or _("番茄小说请求失败")))
            end
            return
        end
        local wire, decode_err = decodeJson(raw, nil, _("番茄小说响应无效"))
        if not wire then cb(nil, decode_err); return end
        cb(wire, wireError(wire))
    end)
end

---@param cb fun(wire: table|nil, err: string|nil)
---@return table
function Client:shelfSyncAsync(cb)
    local cancelled, active = false, nil
    active = self:getJsonAsync(SHELF, {
        aid = "1967", iid = "0", version_code = "57700", update_version_code = "57700",
    }, BASE .. "/", function(info, err)
        if cancelled then return end
        if not info then cb(nil, err); return end
        local data = type(info.data) == "table" and info.data or {}
        local rows = data.book_shelf_info or data.bookShelfInfo
        if type(rows) ~= "table" then rows = data end
        local books, seen = {}, {}
        for _, row in ipairs(rows) do
            local id = type(row) == "table" and (row.book_id or row.bookId) or nil
            if id and not seen[tostring(id)] then
                seen[tostring(id)] = true
                books[#books + 1] = { book_id = tostring(id), item_id = "0" }
            end
        end
        if #books == 0 then cb({ code = 0, data = { detail_list = {} } }); return end
        active = self:getJsonAsync(PROGRESS, nil, BASE .. "/", function(progress, progress_err)
            if cancelled then return end
            if not progress then cb(nil, progress_err); return end
            local progress_map = {}
            for _, row in ipairs(type(progress.data) == "table" and progress.data or {}) do
                if type(row) == "table" and row.book_id then
                    progress_map[tostring(row.book_id)] = row
                end
            end
            for _, book in ipairs(books) do
                local row = progress_map[book.book_id]
                if row and row.item_id then book.item_id = tostring(row.item_id) end
            end
            active = self:postJsonAsync(SHELF_DETAIL, { books = books }, BASE .. "/", function(detail, detail_err)
                if cancelled then return end
                if not detail then cb(nil, detail_err); return end
                local detail_list = type(detail.data) == "table"
                    and (detail.data.detail_list or detail.data.detailList or {}) or {}
                for _, row in ipairs(detail_list) do
                    local progress_row = row.book_id and progress_map[tostring(row.book_id)]
                    if progress_row then
                        row.read_progress = progress_row.read_progress
                        row.index = progress_row.index
                        row.latest_read_item_id = progress_row.item_id
                    end
                end
                cb(detail)
            end)
        end)
    end)
    return { cancel = function()
            cancelled = true
            if active and active.cancel then active.cancel() end
        end }
end

---@param book_id string
---@param cb fun(wire: table|nil, err: string|nil)
---@return table
function Client:bookInfoAsync(book_id, cb)
    book_id = Client.bookId(book_id)
    if not book_id then cb(nil, _("无效的番茄小说 ID")); return { cancel = function() end } end
    return self:postJsonAsync(SHELF_DETAIL, {
        books = {{ book_id = book_id, item_id = "0" }},
    }, BOOK_PAGE .. book_id, cb)
end

---@param book_id string
---@param cb fun(wire: table|nil, err: string|nil)
---@return table
function Client:directoryAsync(book_id, cb)
    book_id = Client.bookId(book_id)
    if not book_id then cb(nil, _("无效的番茄小说 ID")); return { cancel = function() end } end
    return self:getJsonAsync(DIRECTORY, { bookId = book_id }, BOOK_PAGE .. book_id, cb)
end

---@param book_id string
---@param chapter_id string
---@param cb fun(wire: table|nil, err: string|nil)
---@return table
function Client:contentAsync(book_id, chapter_id, cb)
    book_id = Client.bookId(book_id)
    chapter_id = Text.trim(chapter_id)
    if not book_id or chapter_id == "" then
        cb(nil, _("缺少番茄小说章节 ID"))
        return { cancel = function() end }
    end
    return self:getJsonAsync(CONTENT, {
        book_id = book_id, item_id = chapter_id,
    }, BOOK_PAGE .. book_id, cb)
end

---@param cb fun(wire: table|nil, err: string|nil)
---@return table
function Client:progressAsync(cb)
    return self:getJsonAsync(PROGRESS, nil, BASE .. "/", cb)
end

---@param book_id string
---@param item_id string
---@param index number
---@param progress number
---@param cb fun(wire: table|nil, err: string|nil)
---@return table
function Client:updateProgressAsync(book_id, item_id, index, progress, cb)
    return self:postJsonAsync(UPDATE_PROGRESS, {
        book_id = tostring(book_id),
        item_id = tostring(item_id),
        read_progress = tonumber(progress) or 0,
        index = tonumber(index) or 0,
        read_timestamp = os.time(),
        genre_type = 0,
    }, BOOK_PAGE .. tostring(book_id), cb)
end

return Client
