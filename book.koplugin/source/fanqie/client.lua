local ltn12 = require("ltn12")
local Cookie = require("source.fanqie.cookie")
local FanQie = require("source.fanqie.fanqie")
local H = require("source.fanqie.helper")

local ok_https, https = pcall(require, "ssl.https")
local ok_http, http = pcall(require, "socket.http")

-- High-resolution wall-clock timer for perf logging (millisecond precision).
-- Falls back to os.clock() (CPU time) if socket is unavailable.
local ok_socket_perf, socket_perf = pcall(require, "socket")
local function now_ms()
    if ok_socket_perf and socket_perf and socket_perf.gettime then
        return socket_perf.gettime() * 1000
    end
    return os.clock() * 1000
end

local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local DEFAULT_TIMEOUT_SECONDS = 15
local SHELF_CACHE_TTL = 5 * 60 -- 5 minutes for shelf cache
local unpack_args = unpack or table.unpack

-- Rate limiting is now handled per-source by source.fanqie.sources.SourceManager,
-- invoked from get_chapter_content_with_fallback (not inside each fetcher).

local Client = {}
Client.__index = Client

-- SHELF_CACHE：fetch_shelf_detail 内部短缓存，按 cookie_hash 做 key，10 分钟 TTL。
-- 仅用于避免短时间内重复网络请求，不是显示层数据源。
-- 显示层数据源由 bookshelf.lua 的 SHELF_MEM_CACHE（内存主源 + 文件后备）承担。
local SHELF_CACHE = {}

local function header_value(headers, name)
    if not headers then
        return nil
    end
    local target = name:lower()
    for key, value in pairs(headers) do
        if tostring(key):lower() == target then
            return value
        end
    end
    return nil
end

local AUTH_ERROR_CODES = {
    [-2012] = true,
    [-2041] = true,
}

local function is_auth_error(client, code, text, headers)
    if code == 401 or code == 403 then
        return true
    end
    text = tostring(text or "")
    local content_type = tostring(header_value(headers, "content-type") or "unknown")
    local looks_like_json = content_type:lower():find("json", 1, true)
        or text:match("^%s*{") ~= nil
        or text:match("^%s*%[") ~= nil
    if looks_like_json and #text <= 65536 then
        local ok, data = pcall(function()
            return client:json_decode(text)
        end)
        if ok and type(data) == "table" then
            local err_code = data.errCode or data.errcode or data.code
            if AUTH_ERROR_CODES[err_code] then
                return true
            end
            local err_message = data.errMsg or data.errmsg or data.message or data.msg or ""
            if tostring(err_message):find("登录", 1, true) or tostring(err_message):find("登录", 1, true) then
                return true
            end
        end
    end
    return false
end

local function http_error(client, code, text, headers)
    text = tostring(text or "")
    local content_type = tostring(header_value(headers, "content-type") or "unknown")
    local parts = {
        "HTTP " .. tostring(code),
        "content_type=" .. content_type,
        "body_bytes=" .. tostring(#text),
    }
    if is_auth_error(client, code, text, headers) then
        table.insert(parts, "auth_expired=true")
    end
    local looks_like_json = content_type:lower():find("json", 1, true)
        or text:match("^%s*{") ~= nil
        or text:match("^%s*%[") ~= nil
    if looks_like_json and #text <= 65536 then
        local ok, data = pcall(function()
            return client:json_decode(text)
        end)
        if ok and type(data) == "table" then
            local err_code = data.errCode or data.errcode or data.code
            local err_message = data.errMsg or data.errmsg or data.message or data.msg
            if err_code ~= nil then
                table.insert(parts, "error_code=" .. tostring(err_code))
            end
            if err_message ~= nil then
                local message = tostring(err_message):gsub("[%c]+", " "):sub(1, 200)
                table.insert(parts, "error_message=" .. message)
            end
        end
    end
    return table.concat(parts, ", ")
end

local function transport_request(transport, request, timeout)
    timeout = timeout or DEFAULT_TIMEOUT_SECONDS
    local previous_timeout = transport.TIMEOUT
    transport.TIMEOUT = timeout
    local t0 = now_ms()
    local ok, result1, result2, result3, result4 = pcall(transport.request, request)
    local elapsed = now_ms() - t0
    transport.TIMEOUT = previous_timeout

    -- Perf log: how long the raw HTTP request took (network + TLS + server).
    local ok_logger, logger_mod = pcall(require, "source.fanqie.logger")
    if ok_logger and logger_mod then
        local method = (request and request.method) or "GET"
        local url = (request and request.url) or "?"
        -- socket.http returns 1 on success (not the body); the body is
        -- collected by the ltn12 sink, so we can't get its length here.
        -- Only strings/tables support the # operator — numbers don't.
        local body_len = 0
        if type(result1) == "string" or type(result1) == "table" then
            body_len = #result1
        end
        logger_mod.debug("[FanQie][perf] transport_request:",
            "method=" .. method,
            "elapsed=" .. string.format("%.0f", elapsed) .. "ms",
            "code=" .. tostring(result2),
            "result_type=" .. type(result1),
            "url=" .. url)
    end

    if not ok then
        error("transport_request抛异常: " .. tostring(result1))
    end
    -- LuaSocket returns: body, code, headers, status 或 nil, error_message
    -- 检查是否为nil错误（连接失败、超时等）
    if result1 == nil and type(result2) == "string" then
        error("transport_request连接失败: " .. result2)
    end
    return result1, result2, result3, result4
end

function Client:new(settings)
    local obj = setmetatable({
        settings = settings,
    }, self)
    -- Source fetcher dispatch table: source_id -> function(book_id, item_id, opts).
    -- Note: qingtian_get_content takes (item_id, book_id), so we swap args.
    obj._source_fetchers = {
        official = function(bid, iid) return obj:official_get_content(bid, iid) end,
    }
    return obj
end

function Client:json_encode(data)
    if not ok_json then
        error("JSON module is not available")
    end
    if json.encode then
        return json.encode(data)
    end
    return json:encode(data)
end

function Client:json_decode(text)
    if not ok_json then
        error("JSON module is not available")
    end
    if json.decode then
        return json.decode(text)
    end
    return json:decode(text)
end

function Client:request(opts)
    local body = opts.body
    local response = {}
    local headers = opts.headers or {}
    headers["User-Agent"] = headers["User-Agent"] or FanQie.USER_AGENT
    headers["Accept"] = headers["Accept"] or "application/json, text/plain, */*"
    headers["Accept-Encoding"] = "identity"
    headers["Connection"] = "keep-alive"

    if body then
        headers["Content-Length"] = tostring(#body)
    end

    local transport = opts.url:match("^https:") and https or http
    if opts.url:match("^https:") and not ok_https then
        error("ssl.https is not available")
    elseif not transport and not ok_http then
        error("socket.http is not available")
    end

    local request_tbl = {
        url = opts.url,
        method = opts.method or (body and "POST" or "GET"),
        headers = headers,
        source = body and ltn12.source.string(body) or nil,
        sink = ltn12.sink.table(response),
    }
    -- 透传 redirect 选项（socket.http 默认 true 自动跟随，设 false 可手动处理重定向以保留中间 Set-Cookie）
    if opts.redirect ~= nil then
        request_tbl.redirect = opts.redirect
    end

    local _, code, resp_headers, status = transport_request(transport, request_tbl, opts.timeout)

    return table.concat(response), tonumber(code), resp_headers or {}, status
end

function Client:request_follow(opts, max_redirects)
    max_redirects = max_redirects or 5
    local url = opts.url
    for redirect_index = 1, max_redirects + 1 do
        opts.url = url
        local text, code, resp_headers, status = self:request(opts)
        if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
            local location = header_value(resp_headers, "location")
            if not location then
                return text, code, resp_headers, status
            end
            if location:match("^https?://") then
                url = location
            else
                local scheme, host = url:match("^(https?)://([^/]+)")
                if scheme then
                    if location:sub(1, 1) == "/" then
                        url = scheme .. "://" .. host .. location
                    else
                        local prefix = url:match("^(https?://.*/)") or (scheme .. "://" .. host .. "/")
                        url = prefix .. location
                    end
                else
                    url = location
                end
            end
            opts.method = "GET"
            opts.body = nil
            opts.headers = opts.headers or {}
            opts.headers["Content-Length"] = nil
        else
            return text, code, resp_headers, status
        end
    end
    error("Too many redirects")
end

-- ============================================================================
-- Server detection (check-servers with short-circuit optimization)
-- ============================================================================

-- Check if a single server is available by sending GET to /login
-- Returns (available:bool, response_code:number)
function Client:download_binary(url)
    local headers = {
        ["User-Agent"] = FanQie.USER_AGENT,
        ["Accept"] = "*/*",
        ["Accept-Encoding"] = "identity",
        ["Connection"] = "keep-alive",
    }
    local text, code = self:request_follow({
        url = url,
        method = "GET",
        headers = headers,
    })
    if code and code >= 200 and code < 300 then
        return text, code
    end
    return nil, code
end

function Client:post_json(url, data, opts)
    opts = opts or {}
    local cookies = self.settings:get("cookies", {})
    local headers = {
        ["Content-Type"] = "application/json;charset=UTF-8",
        ["Origin"] = FanQie.BASE_URL,
        ["Referer"] = opts.referer or (FanQie.BASE_URL .. "/"),
    }
    local cookie_header = Cookie.to_header(cookies)
    if cookie_header ~= "" then
        headers["Cookie"] = cookie_header
    end
    if opts.headers then
        for key, value in pairs(opts.headers) do
            headers[key] = value
        end
    end

    local text, code, resp_headers = self:request({
        url = url,
        method = "POST",
        headers = headers,
        body = self:json_encode(data),
    })
    local set_cookie = header_value(resp_headers, "set-cookie")
    if set_cookie then
        self.settings:set("cookies", Cookie.merge_set_cookie(cookies, set_cookie))
        self.settings:flush()
    end
    if code and code >= 200 and code < 300 then
        return self:json_decode(text), code, resp_headers
    end
    local err_detail = http_error(self, code, text, resp_headers)
    local err_msg = string.format("POST %s => %s", url, err_detail)
    if is_auth_error(self, code, text, resp_headers) then
        error({ auth_expired = true, message = err_msg })
    else
        error(err_msg)
    end
end

function Client:get_json(url, opts)
    opts = opts or {}
    local cookies = self.settings:get("cookies", {})
    local headers = {
        ["Accept"] = "application/json, text/plain, */*",
        ["Referer"] = opts.referer or (FanQie.BASE_URL .. "/"),
    }
    local cookie_header = Cookie.to_header(cookies)
    if cookie_header ~= "" then
        headers["Cookie"] = cookie_header
    end
    if opts.headers then
        for key, value in pairs(opts.headers) do
            headers[key] = value
        end
    end

    local text, code, resp_headers = self:request({
        url = url,
        method = "GET",
        headers = headers,
    })
    local set_cookie = header_value(resp_headers, "set-cookie")
    if set_cookie then
        self.settings:set("cookies", Cookie.merge_set_cookie(cookies, set_cookie))
        self.settings:flush()
    end
    if code and code >= 200 and code < 300 then
        return self:json_decode(text), code, resp_headers
    end
    local err_detail = http_error(self, code, text, resp_headers)
    local err_msg = string.format("GET %s => %s", url, err_detail)
    if is_auth_error(self, code, text, resp_headers) then
        error({ auth_expired = true, message = err_msg })
    else
        error(err_msg)
    end
end

function Client:get_text(url, opts)
    opts = opts or {}
    local cookies = self.settings:get("cookies", {})
    local headers = {
        ["Accept"] = opts.accept or "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Referer"] = opts.referer or (FanQie.BASE_URL .. "/"),
        ["Cookie"] = Cookie.to_header(cookies),
    }
    local text, code, resp_headers = self:request({
        url = url,
        method = "GET",
        headers = headers,
    })
    local set_cookie = header_value(resp_headers, "set-cookie")
    if set_cookie then
        self.settings:set("cookies", Cookie.merge_set_cookie(cookies, set_cookie))
        self.settings:flush()
    end
    if code and code >= 200 and code < 300 then
        return text
    end
    local err_msg = http_error(self, code, text, resp_headers)
    if is_auth_error(self, code, text, resp_headers) then
        error({ auth_expired = true, message = err_msg })
    else
        error(err_msg)
    end
end

function Client:get_binary(url, opts)
    opts = opts or {}
    local cookies = self.settings:get("cookies", {})
    local headers = {
        ["Accept"] = opts.accept or "*/*",
        ["Cookie"] = Cookie.to_header(cookies),
    }
    -- Referer: explicit string → use it; false → send none; nil → default base URL.
    -- Some CDNs (e.g. fqnovelpic.com) reject any Referer as anti-leech.
    if opts.referer == false then
        -- intentionally no Referer header
    elseif opts.referer then
        headers["Referer"] = opts.referer
    else
        headers["Referer"] = FanQie.BASE_URL .. "/"
    end
    if opts.headers then
        for key, value in pairs(opts.headers) do
            headers[key] = value
        end
    end
    local text, code, resp_headers = self:request_follow({
        url = url,
        method = "GET",
        headers = headers,
    })
    local set_cookie = header_value(resp_headers, "set-cookie")
    if set_cookie then
        self.settings:set("cookies", Cookie.merge_set_cookie(cookies, set_cookie))
        self.settings:flush()
    end
    if code and code >= 200 and code < 300 then
        return text, code, resp_headers
    end
    local err_msg = http_error(self, code, text, resp_headers)
    if is_auth_error(self, code, text, resp_headers) then
        error({ auth_expired = true, message = err_msg })
    else
        error(err_msg)
    end
end

function Client:fetch_shelf_info()
    local params = FanQie.make_shelf_params()
    local url = FanQie.shelf_url() .. "?"
    local parts = {}
    for key, value in pairs(params) do
        table.insert(parts, key .. "=" .. H.url_encode(value))
    end
    return self:get_json(url .. table.concat(parts, "&"))
end

function Client:clear_shelf_cache()
    SHELF_CACHE = {}
end

local function get_cookie_hash(cookies)
    local parts = {}
    for k, v in pairs(cookies) do
        table.insert(parts, k .. "=" .. v)
    end
    table.sort(parts)
    return table.concat(parts, ";")
end

function Client:fetch_shelf_detail(force_refresh)
    local now = os.time()
    local cookies = self.settings:get("cookies", {})
    local cache_key = next(cookies) and get_cookie_hash(cookies) or "default"
    local cached = SHELF_CACHE[cache_key]
    if not force_refresh and cached and (now - cached.timestamp) < SHELF_CACHE_TTL then
        return cached.data
    end

    -- 书架直接使用官方 API
    local shelf_info = self:fetch_shelf_info()
    if type(shelf_info) ~= "table" or (shelf_info.code ~= nil and tonumber(shelf_info.code) ~= 0)
        or type(shelf_info.data) ~= "table" then
        error("番茄书架请求失败，请检查登录状态")
    end

    local book_shelf_info = shelf_info.data.book_shelf_info or shelf_info.data.bookShelfInfo or shelf_info.data
    if type(book_shelf_info) ~= "table" or #book_shelf_info == 0 then
        return { code = 0, data = { detail_list = {} } }
    end

    local shelf_book_ids = {}
    for _, item in ipairs(book_shelf_info) do
        if item.book_id then
            table.insert(shelf_book_ids, item.book_id)
        end
    end

    local progress_result = self:fetch_read_progress()
    local progress_map = {}
    if progress_result and progress_result.data then
        for _, item in ipairs(progress_result.data) do
            progress_map[tostring(item.book_id)] = {
                read_progress = item.read_progress,
                index = item.index,
                item_id = item.item_id,
            }
        end
    end

    local books = {}
    for _, book_id in ipairs(shelf_book_ids) do
        local progress = progress_map[tostring(book_id)]
        table.insert(books, {
            book_id = book_id,
            item_id = progress and progress.item_id or "0",
        })
    end

    local detail_result = self:post_json(FanQie.bookshelf_multidetail_url(), { books = books })
    if detail_result and detail_result.data and detail_result.data.detail_list then
        for _, book in ipairs(detail_result.data.detail_list) do
            local progress = progress_map[tostring(book.book_id)]
            if progress then
                book.read_progress = progress.read_progress
                book.index = progress.index
                book.latest_read_item_id = progress.item_id
            end
        end
    end

    SHELF_CACHE[cache_key] = {
        timestamp = now,
        data = detail_result,
    }

    return detail_result
end

function Client:fetch_read_progress()
    return self:get_json(FanQie.progress_url())
end

function Client:update_read_progress(book_id, item_id, index, progress)
    return self:post_json(FanQie.update_progress_url(), {
        book_id = book_id,
        item_id = item_id,
        read_progress = progress or 0,
        index = index,
        read_timestamp = tostring(math.floor(os.time())),
        genre_type = 0,
    })
end

function Client:fetch_chapter_directory(book_id)
    -- 目录直接使用官方 API
    local ok, result = pcall(function()
        return self:get_json(FanQie.directory_url(book_id))
    end)

    if ok and result and result.code == 0 and result.data then
        return result
    end

    local err_msg = "官方 API 获取目录失败"
    if result then
        err_msg = err_msg .. ": code=" .. tostring(result.code) .. " message=" .. tostring(result.message or "")
    end
    error(err_msg)
end

-- Fetch chapter content via the official FanQie API (public, no login needed).
-- Returns {content, title, author} on success; errors on failure.
function Client:official_get_content(book_id, item_id)
    return require("source.fanqie.official").fetch(self, book_id, item_id)
end

return Client
