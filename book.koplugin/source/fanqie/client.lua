--[[--
番茄小说 HTTP 客户端：只走 http.request。

@module koplugin.book.source.fanqie.client
--]]

local Cookie = require("source.fanqie.cookie")
local FanQie = require("source.fanqie.fanqie")
local JSON = require("json")
local Request = require("http.request")
local Text = require("utils.text")
local logger = require("utils.log")

local Client = {}
Client.__index = Client

---@class FanqieClient
---@field settings FanqieSettings
---@field fetchReadProgressAsync fun(self: FanqieClient, cb: function): CancelHandle|nil
---@field updateReadProgressAsync fun(self: FanqieClient, book_id: string, item_id: string, index: number, progress: number, cb: function): CancelHandle|nil
---@field fetchChapterDirectoryAsync fun(self: FanqieClient, book_id: string, cb: function): CancelHandle|nil
---@field fetchShelfDetailAsync fun(self: FanqieClient, force_refresh: boolean|nil, cb: function): CancelHandle|nil
---@field officialGetContentAsync fun(self: FanqieClient, book_id: string, item_id: string, cb: function): CancelHandle|nil

local DEFAULT_TIMEOUT = 15
local SHELF_CACHE_TTL = 5 * 60
local SHELF_CACHE = {}

local AUTH_ERROR_CODES = {
    [-2012] = true,
    [-2041] = true,
    [101119] = true, -- BOOKSHELF_GET_ERROR：无有效 sessionid
}

---@param data table|nil
---@param fallback string
---@return string
local function businessError(data, fallback)
    if type(data) ~= "table" then
        return fallback
    end
    local err_code = data.errCode or data.errcode or data.code
    local err_message = data.errMsg or data.errmsg or data.message or data.msg
    local parts = { fallback }
    if err_code ~= nil then
        parts[#parts + 1] = "code=" .. tostring(err_code)
    end
    if err_message ~= nil and tostring(err_message) ~= "" then
        parts[#parts + 1] = "message="
            .. tostring(err_message):gsub("[%c]+", " "):sub(1, 200)
    end
    if AUTH_ERROR_CODES[tonumber(err_code)]
        or (err_message and tostring(err_message):find("登录", 1, true))
    then
        parts[#parts + 1] = "请重新扫码登录"
    end
    return table.concat(parts, ", ")
end

---@param text string|nil
---@return table|nil, string|nil
local function decodeJson(text)
    if type(text) ~= "string" or text == "" then
        return nil, "empty json"
    end
    local ok, data = pcall(JSON.decode, text)
    if not ok or type(data) ~= "table" then
        return nil, "invalid json"
    end
    return data
end

---@param settings table
---@return FanqieClient
function Client:new(settings)
    return setmetatable({ settings = settings }, self)
end

---@param cookies table
---@return string
local function cookieHash(cookies)
    local parts = {}
    for k, v in pairs(cookies or {}) do
        parts[#parts + 1] = k .. "=" .. tostring(v)
    end
    table.sort(parts)
    return table.concat(parts, ";")
end

---@param self FanqieClient
---@param res table|nil
local function absorbCookies(self, res)
    local set_cookie = Request.header(res, "Set-Cookie")
    if not set_cookie then return end
    local cookies = self.settings:get("cookies", {})
    self.settings:set("cookies", Cookie.merge_set_cookie(cookies, set_cookie))
    self.settings:flush()
end

---@param code number|nil
---@param body string|nil
---@param res table|nil
---@return boolean
local function isAuthError(code, body, res)
    if code == 401 or code == 403 then return true end
    body = tostring(body or "")
    local content_type = tostring(Request.header(res, "Content-Type") or "")
    local looks_json = content_type:lower():find("json", 1, true)
        or body:match("^%s*{") ~= nil
    if not looks_json or #body > 65536 then return false end
    local data = decodeJson(body)
    if type(data) ~= "table" then return false end
    local err_code = data.errCode or data.errcode or data.code
    if AUTH_ERROR_CODES[tonumber(err_code)] then return true end
    local msg = tostring(data.errMsg or data.errmsg or data.message or data.msg or "")
    return msg:find("登录", 1, true) ~= nil
end

---@param method string
---@param url string
---@param code number|nil
---@param body string|nil
---@param res table|nil
---@return string
local function httpError(method, url, code, body, res)
    local parts = {
        method .. " " .. tostring(url),
        "HTTP " .. tostring(code),
    }
    if isAuthError(code, body, res) then
        parts[#parts + 1] = "auth_expired=true"
    end
    local data = decodeJson(body)
    if type(data) == "table" then
        local err_code = data.errCode or data.errcode or data.code
        local err_message = data.errMsg or data.errmsg or data.message or data.msg
        if err_code ~= nil then
            parts[#parts + 1] = "error_code=" .. tostring(err_code)
        end
        if err_message ~= nil then
            parts[#parts + 1] = "error_message="
                .. tostring(err_message):gsub("[%c]+", " "):sub(1, 200)
        end
    end
    return table.concat(parts, ", ")
end

---@param self FanqieClient
---@return table
local function sessionHeaders(self, extra)
    local cookies = self.settings:get("cookies", {})
    local headers = {
        ["User-Agent"] = FanQie.USER_AGENT,
        ["Accept"] = "application/json, text/plain, */*",
        ["Accept-Encoding"] = "identity",
        ["Referer"] = FanQie.BASE_URL .. "/",
    }
    local cookie_header = Cookie.to_header(cookies)
    if cookie_header ~= "" then
        headers["Cookie"] = cookie_header
    end
    for k, v in pairs(extra or {}) do
        headers[k] = v
    end
    return headers
end

--- 带会话 Cookie 的 JSON 请求（跟随重定向）；回包 Set-Cookie 并入会话。
--- 传输失败、非 2xx 与非 JSON 都归一成 cb(nil, err)。
---@param self FanqieClient
---@param method string
---@param url string
---@param extra_headers table|nil
---@param body string|nil
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
local function jsonAsync(self, method, url, extra_headers, body, cb)
    return Request.request({
        url = url,
        method = method,
        body = body,
        headers = sessionHeaders(self, extra_headers),
        timeout = DEFAULT_TIMEOUT,
        allow_redirects = true,
    }, function(res, err)
        if err or not res then
            cb(nil, err and tostring(err))
            return
        end
        absorbCookies(self, res)
        local code = tonumber(res.code)
        if not Request.ok(code) then
            cb(nil, httpError(method, url, code, res.body, res))
            return
        end
        cb(decodeJson(res.body))
    end)
end

---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:fetchReadProgressAsync(cb)
    return jsonAsync(self, "GET", FanQie.BASE_URL .. "/api/reader/book/progress", nil, nil, cb)
end

---@param book_id string
---@param item_id string
---@param index number
---@param progress number
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:updateReadProgressAsync(book_id, item_id, index, progress, cb)
    return jsonAsync(self, "POST", FanQie.BASE_URL .. "/api/reader/book/update_progress", {
        ["Content-Type"] = "application/json;charset=UTF-8",
        ["Origin"] = FanQie.BASE_URL,
    }, JSON.encode({
        book_id = book_id,
        item_id = item_id,
        read_progress = progress or 0,
        index = index,
        read_timestamp = tostring(math.floor(os.time())),
        genre_type = 0,
    }), cb)
end

---@param book_id string
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:fetchChapterDirectoryAsync(book_id, cb)
    local url = FanQie.BASE_URL .. "/api/reader/directory/detail?bookId=" .. Text.urlEncode(book_id)
    return jsonAsync(self, "GET", url, nil, nil, function(data, err)
        if not data then
            cb(nil, err or "官方 API 获取目录失败")
            return
        end
        if tonumber(data.code) ~= 0 or type(data.data) ~= "table" then
            cb(nil, "官方 API 获取目录失败: code="
                .. tostring(data.code) .. " message=" .. tostring(data.message or ""))
            return
        end
        cb(data)
    end)
end

---@param force_refresh boolean|nil
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:fetchShelfDetailAsync(force_refresh, cb)
    local now = os.time()
    local cookies = self.settings:get("cookies", {})
    local cache_key = next(cookies) and cookieHash(cookies) or "default"
    local cached = SHELF_CACHE[cache_key]
    if not force_refresh and cached and (now - cached.timestamp) < SHELF_CACHE_TTL then
        require("ui/uimanager"):nextTick(function() cb(cached.data) end)
        return { cancel = function() end }
    end

    local cancelled = false
    local shelf_job
    local detail_jobs = {}
    local handle = {
        cancel = function()
            cancelled = true
            if shelf_job and shelf_job.cancel then shelf_job.cancel() end
            for _, j in pairs(detail_jobs) do
                if j and j.cancel then j.cancel() end
            end
        end,
    }

    local shelf_url = FanQie.BASE_URL .. "/reading/bookapi/bookshelf/info/v:version/?" .. Text.formEncode({
        aid = 1967,
        iid = 0,
        version_code = 57700,
        update_version_code = 57700,
    })
    shelf_job = jsonAsync(self, "GET", shelf_url, nil, nil, function(shelf_info, err)
        if cancelled then return end
        if type(shelf_info) ~= "table"
            or (shelf_info.code ~= nil and tonumber(shelf_info.code) ~= 0)
            or type(shelf_info.data) ~= "table"
        then
            cb(nil, err or businessError(shelf_info, "番茄书架请求失败"))
            return
        end
        local book_shelf_info = shelf_info.data.book_shelf_info
            or shelf_info.data.bookShelfInfo
            or shelf_info.data
        local shelf_book_ids = {}
        for _, item in ipairs(type(book_shelf_info) == "table" and book_shelf_info or {}) do
            if item.book_id then
                shelf_book_ids[#shelf_book_ids + 1] = tostring(item.book_id)
            end
        end
        if #shelf_book_ids == 0 then
            local empty = { code = 0, data = { detail_list = {} } }
            SHELF_CACHE[cache_key] = { timestamp = os.time(), data = empty }
            cb(empty)
            return
        end

        -- web multidetail 无作者；手机端 multi-detail 现已空响应。
        -- 用 /api/book/info 拿书名/作者，封面走手机 CDN（thumb_uri 稳定、不签名过期）。
        local pending = #shelf_book_ids
        local by_id = {}
        -- 拿不到详情的书（下架/失效）不进列表：reconcile 软删不标脏，不会推云端删除，恢复后重新上架。
        local function finish()
            local detail_list = {}
            for _, book_id in ipairs(shelf_book_ids) do
                local row = by_id[book_id]
                if row then
                    detail_list[#detail_list + 1] = row
                end
            end
            local result = { code = 0, data = { detail_list = detail_list } }
            SHELF_CACHE[cache_key] = { timestamp = os.time(), data = result }
            cb(result)
        end

        for _, book_id in ipairs(shelf_book_ids) do
            detail_jobs[book_id] = jsonAsync(self, "GET", FanQie.book_info_url(book_id), nil, nil, function(info, info_err)
                if cancelled then return end
                if type(info) == "table" and type(info.data) == "table"
                    and (info.code == nil or tonumber(info.code) == 0)
                then
                    local d = info.data
                    by_id[book_id] = {
                        book_id = book_id,
                        book_name = d.bookName or d.book_name or d.title,
                        author_name = d.authorName or d.author_name or d.author or "",
                        abstract = d.abstract or d.description or "",
                        thumb_url = FanQie.mobileCover(d.thumbUri or d.thumb_uri or d.thumbUrl),
                    }
                else
                    logger.warn("fanqie book info", book_id, info_err or businessError(info, "invalid"))
                end
                pending = pending - 1
                if pending <= 0 then
                    finish()
                end
            end)
        end
    end)
    return handle
end

---@param book_id string
---@param item_id string
---@param cb fun(data: table|nil, err: string|nil)
---@return CancelHandle|nil
function Client:officialGetContentAsync(book_id, item_id, cb)
    return require("source.fanqie.reading").fetchAsync(self.settings, book_id, item_id, cb)
end

return Client
