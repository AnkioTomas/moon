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
---@field clear_shelf_cache fun(self: FanqieClient)
---@field requestAsync fun(self: FanqieClient, opts: table, cb: function): CancelHandle|nil
---@field getJsonAsync fun(self: FanqieClient, url: string, opts: table|nil, cb: function): CancelHandle|nil
---@field postJsonAsync fun(self: FanqieClient, url: string, data: table, opts: table|nil, cb: function): CancelHandle|nil
---@field fetchShelfInfoAsync fun(self: FanqieClient, cb: function): CancelHandle|nil
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
    local data = select(1, decodeJson(body))
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
    local data = select(1, decodeJson(body))
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

--- 底层请求。allow_redirects 默认 false。
---@param opts { url: string, method?: string, body?: string, headers?: table, timeout?: number, allow_redirects?: boolean }
---@param cb fun(res: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:requestAsync(opts, cb)
    return Request.request({
        url = opts.url,
        method = opts.method or (opts.body and "POST" or "GET"),
        body = opts.body,
        headers = opts.headers,
        timeout = opts.timeout or DEFAULT_TIMEOUT,
        allow_redirects = opts.allow_redirects == true,
    }, function(res, err)
        if err then
            cb(nil, tostring(err))
            return
        end
        absorbCookies(self, res)
        cb(res)
    end)
end

---@param url string
---@param opts { referer?: string, headers?: table, timeout?: number }|nil
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:getJsonAsync(url, opts, cb)
    opts = opts or {}
    local headers = sessionHeaders(self, {
        ["Accept"] = "application/json, text/plain, */*",
        ["Referer"] = opts.referer or (FanQie.BASE_URL .. "/"),
    })
    for k, v in pairs(opts.headers or {}) do
        headers[k] = v
    end
    return self:requestAsync({
        url = url,
        method = "GET",
        headers = headers,
        timeout = opts.timeout,
        allow_redirects = true,
    }, function(res, err)
        if not res then cb(nil, err); return end
        local code = tonumber(res.code)
        local body = res.body
        if not Request.ok(code) then
            cb(nil, httpError("GET", url, code, body, res))
            return
        end
        local data, decode_err = decodeJson(body)
        if not data then cb(nil, decode_err or "invalid json"); return end
        cb(data)
    end)
end

---@param url string
---@param data table
---@param opts { referer?: string, headers?: table, timeout?: number }|nil
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:postJsonAsync(url, data, opts, cb)
    opts = opts or {}
    local headers = sessionHeaders(self, {
        ["Content-Type"] = "application/json;charset=UTF-8",
        ["Origin"] = FanQie.BASE_URL,
        ["Referer"] = opts.referer or (FanQie.BASE_URL .. "/"),
    })
    for k, v in pairs(opts.headers or {}) do
        headers[k] = v
    end
    return self:requestAsync({
        url = url,
        method = "POST",
        headers = headers,
        body = JSON.encode(data),
        timeout = opts.timeout,
        allow_redirects = true,
    }, function(res, err)
        if not res then cb(nil, err); return end
        local code = tonumber(res.code)
        local body = res.body
        if not Request.ok(code) then
            cb(nil, httpError("POST", url, code, body, res))
            return
        end
        local decoded, decode_err = decodeJson(body)
        if not decoded then cb(nil, decode_err or "invalid json"); return end
        cb(decoded)
    end)
end

---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:fetchShelfInfoAsync(cb)
    return self:getJsonAsync(
        FanQie.shelf_url() .. "?" .. Text.formEncode(FanQie.make_shelf_params()),
        nil, cb)
end

---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:fetchReadProgressAsync(cb)
    return self:getJsonAsync(FanQie.progress_url(), nil, cb)
end

---@param book_id string
---@param item_id string
---@param index number
---@param progress number
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:updateReadProgressAsync(book_id, item_id, index, progress, cb)
    return self:postJsonAsync(FanQie.update_progress_url(), {
        book_id = book_id,
        item_id = item_id,
        read_progress = progress or 0,
        index = index,
        read_timestamp = tostring(math.floor(os.time())),
        genre_type = 0,
    }, nil, cb)
end

---@param book_id string
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:fetchChapterDirectoryAsync(book_id, cb)
    return self:getJsonAsync(FanQie.directory_url(book_id), nil, function(data, err)
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

    shelf_job = self:fetchShelfInfoAsync(function(shelf_info, err)
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
        if type(book_shelf_info) ~= "table" or #book_shelf_info == 0 then
            local empty = { code = 0, data = { detail_list = {} } }
            SHELF_CACHE[cache_key] = { timestamp = os.time(), data = empty }
            cb(empty)
            return
        end

        local shelf_book_ids = {}
        for _, item in ipairs(book_shelf_info) do
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
        local function finish()
            local detail_list = {}
            for _, book_id in ipairs(shelf_book_ids) do
                local row = by_id[book_id]
                if row then
                    detail_list[#detail_list + 1] = row
                end
            end
            if #detail_list == 0 then
                cb(nil, "番茄书架详情失败")
                return
            end
            local result = { code = 0, data = { detail_list = detail_list } }
            SHELF_CACHE[cache_key] = { timestamp = os.time(), data = result }
            cb(result)
        end

        for _, book_id in ipairs(shelf_book_ids) do
            detail_jobs[book_id] = self:getJsonAsync(FanQie.book_info_url(book_id), nil, function(info, info_err)
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
                elseif info_err then
                    logger.warn("fanqie book info", book_id, info_err)
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
