--[[--
Kavita HTTP 客户端（x-api-key header 认证）

只返回 wire；不做契约字段转换。
网络仅异步：Request.request。

@module koplugin.book.source.kavita.client
--]]

local JSON = require("json")
local logger = require("utils.log")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("gettext")
local T = require("ffi/util").template

local Client = {}

local MIN_VERSION = { major = 0, minor = 9, patch = 0 }

---@param version string|nil
---@return table|nil
local function parseVersion(version)
    if type(version) ~= "string" then return nil end
    local major, minor, patch = version:match("^(%d+)%.(%d+)%.(%d+)")
    if not major then return nil end
    return {
        major = tonumber(major),
        minor = tonumber(minor),
        patch = tonumber(patch) or 0,
    }
end

---@param a table
---@param b table
---@return boolean
local function versionGte(a, b)
    if a.major ~= b.major then return a.major > b.major end
    if a.minor ~= b.minor then return a.minor > b.minor end
    return a.patch >= b.patch
end

---@param o { base_url: string|nil, api_key: string|nil }|table|nil
---@return table
function Client:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o.base_url = Text.rtrimSlashes(o.base_url or "")
    o.api_key = o.api_key or ""
    return o
end

---@return boolean
function Client:configured()
    return self.base_url ~= "" and self.api_key ~= ""
end

---@param path string
---@param query table|nil
---@return string|nil, string|nil
function Client:_url(path, query)
    if not self:configured() then
        return nil, _("未配置服务器地址或 API Key")
    end
    local url = self.base_url .. path
    if query and next(query) then
        url = url .. "?" .. Text.formEncode(query)
    end
    return url
end

---@return table
function Client:_headers()
    return { ["x-api-key"] = self.api_key }
end

---@param res table|nil
---@param req_err any
---@param cb fun(data: table|nil, err: string|nil)
---@param empty_ok boolean|nil 2xx 空 body 视为成功（如 progress/标注写接口）
local function handleResponse(res, req_err, cb, empty_ok)
    if req_err then
        cb(nil, tostring(req_err))
        return
    end
    if not res then
        cb(nil, _("网络不可用，请先连接 Wi-Fi"))
        return
    end
    local code = tonumber(res.code)
    if not code then
        cb(nil, _("请求失败"))
        return
    end
    if code == 401 or code == 403 then
        cb(nil, _("Kavita API Key 无效或无权限"))
        return
    end
    if code < 200 or code >= 300 then
        cb(nil, T(_("请求失败 (HTTP %1)"), tostring(code)))
        return
    end
    local raw = Text.stripBom(res.body or "")
    if empty_ok and Text.trim(raw) == "" then
        cb({})
        return
    end
    local ok, data = pcall(JSON.decode, raw)
    if not ok or type(data) ~= "table" then
        cb(nil, _("响应不是 JSON"))
        return
    end
    cb(data)
end

---@param path string
---@param query table|nil
---@param cb fun(data: table|nil, err: string|nil)
---@return table|nil
function Client:getJSON(path, query, cb)
    local url, err = self:_url(path, query)
    if not url then cb(nil, err); return nil end
    return Request.request({
        url = url,
        method = "GET",
        headers = self:_headers(),
        timeout = 30,
    }, function(res, req_err)
        handleResponse(res, req_err, cb)
    end)
end

---@param cb fun(ok: boolean, version: string|nil, err: string|nil)
---@return table|nil
function Client:testVersionAsync(cb)
    if not self:configured() then
        cb(false, nil, _("未配置服务器地址或 API Key"))
        return nil
    end
    local url = self.base_url .. "/api/Plugin/version?apiKey=" .. Text.urlEncode(self.api_key)
    return Request.request({
        url = url,
        method = "GET",
        timeout = 30,
    }, function(res, req_err)
        if req_err then
            cb(false, nil, _("网络不可用，请先连接 Wi-Fi"))
            return
        end
        if not res then
            cb(false, nil, _("网络不可用，请先连接 Wi-Fi"))
            return
        end
        local code = tonumber(res.code)
        if not code then
            cb(false, nil, _("请求失败"))
            return
        end
        if code == 401 or code == 403 then
            cb(false, nil, _("Kavita API Key 无效或无权限"))
            return
        end
        if code < 200 or code >= 300 then
            cb(false, nil, T(_("请求失败 (HTTP %1)"), tostring(code)))
            return
        end
        local version = Text.trim(Text.stripBom(res.body or ""))
        if version == "" then
            cb(false, nil, _("版本响应为空"))
            return
        end
        cb(true, version, nil)
    end)
end

---@param series_id string|number
---@return { url: string, headers: table }|nil, string|nil
function Client:coverRequest(series_id)
    if not series_id or tostring(series_id) == "" then
        return nil, _("无效 seriesId")
    end
    if not self:configured() then
        return nil, _("未配置服务器地址或 API Key")
    end
    return {
        url = self.base_url .. "/api/Image/series-cover?seriesId=" .. tostring(series_id),
        headers = self:_headers(),
    }
end

---@param path string
---@param body table
---@param cb fun(data: table|nil, err: string|nil)
---@param empty_ok boolean|nil
---@return table|nil
function Client:postJSON(path, body, cb, empty_ok)
    local url, err = self:_url(path)
    if not url then cb(nil, err); return nil end
    local ok, encoded = pcall(JSON.encode, body)
    if not ok or type(encoded) ~= "string" then
        cb(nil, _("请求编码失败"))
        return nil
    end
    local headers = self:_headers()
    headers["Content-Type"] = "application/json"
    return Request.request({
        url = url,
        method = "POST",
        headers = headers,
        body = encoded,
        timeout = 30,
    }, function(res, req_err)
        handleResponse(res, req_err, cb, empty_ok)
    end)
end

--- 单本 series 的简介/作者（书架骨架 SeriesDto 不带 summary/writers）。
---@param series_id string|number
---@param cb fun(data: table|nil, err: string|nil)
---@return table|nil
function Client:fetchSeriesMetadataAsync(series_id, cb)
    return self:getJSON("/api/Series/metadata", { seriesId = tostring(series_id) }, cb)
end

--- 单本 series 的 SeriesDto（`GET /api/Series/{id}`），取 libraryId 等。
---@param series_id string|number
---@param cb fun(data: table|nil, err: string|nil)
---@return table|nil
function Client:fetchSeriesAsync(series_id, cb)
    return self:getJSON("/api/Series/" .. tostring(series_id), nil, cb)
end

--- series 的卷/章列表（`GET /api/Series/volumes?seriesId=`）。
---@param series_id string|number
---@param cb fun(data: table[]|nil, err: string|nil)
---@return table|nil
function Client:fetchSeriesVolumesAsync(series_id, cb)
    return self:getJSON("/api/Series/volumes", { seriesId = tostring(series_id) }, cb)
end

--- 章节阅读进度（`GET /api/Reader/get-progress?chapterId=`）。
--- 400/404 = 该章无进度，返回空的成功（cb(nil, nil, true)）。
---@param chapter_id string|number
---@param cb fun(data: table|nil, err: string|nil, no_progress: boolean|nil)
---@return table|nil
function Client:getProgressAsync(chapter_id, cb)
    local url, err = self:_url("/api/Reader/get-progress", { chapterId = tostring(chapter_id) })
    if not url then cb(nil, err); return nil end
    return Request.request({
        url = url,
        method = "GET",
        headers = self:_headers(),
        timeout = 30,
    }, function(res, req_err)
        if req_err then cb(nil, tostring(req_err)); return end
        if not res then cb(nil, _("网络不可用，请先连接 Wi-Fi")); return end
        local code = tonumber(res.code)
        if code == 400 or code == 404 then cb(nil, nil, true); return end
        handleResponse(res, req_err, function(data, e) cb(data, e) end)
    end)
end

--- 上报阅读进度（`POST /api/Reader/progress`）。
---@param payload table
---@param cb fun(ok: boolean, err: string|nil)
---@return table|nil
function Client:saveProgressAsync(payload, cb)
    return self:postJSON("/api/Reader/progress", payload, function(data, err)
        cb(data ~= nil, err)
    end, true)
end

--- 标记章节已读（`POST /api/Reader/mark-chapter-read`，幂等）。
---@param payload table
---@param cb fun(ok: boolean, err: string|nil)
---@return table|nil
function Client:markChapterReadAsync(payload, cb)
    return self:postJSON("/api/Reader/mark-chapter-read", payload, function(data, err)
        cb(data ~= nil, err)
    end, true)
end

--- 建注解（`POST /api/Annotation/create`）；成功回传含 `id` 的注解对象。
---@param payload table
---@param cb fun(data: table|nil, err: string|nil)
---@return table|nil
function Client:createAnnotationAsync(payload, cb)
    return self:postJSON("/api/Annotation/create", payload, cb)
end

---@param cb fun(libraries: table[]|nil, err: string|nil)
---@return table|nil
function Client:listLibrariesAsync(cb)
    -- 0.9.1.4 实测 `/api/Library` 返回 204，可用的库列表端点是 `/api/Library/libraries`。
    self:getJSON("/api/Library/libraries", nil, function(data, err)
        if not data then cb(nil, err); return end
        cb(data)
    end)
end

---@param chapter_id string|number
---@param dest_path string
---@param on_progress fun(bytes: number, total: number|nil)|nil
---@param cb fun(ok: boolean, err: string|nil)
---@return table|nil
function Client:downloadChapterAsync(chapter_id, dest_path, on_progress, cb)
    if not self:configured() then
        cb(false, _("未配置服务器地址或 API Key"))
        return nil
    end
    local url, err = self:_url("/api/Download/chapter", { chapterId = tostring(chapter_id) })
    if not url then cb(false, err); return nil end
    return Request.download({
        url = url,
        headers = self:_headers(),
        timeout = 30,
        on_progress = on_progress,
    }, dest_path, function(ok, dl_err)
        if not ok then
            cb(false, dl_err or _("下载失败"))
            return
        end
        cb(true)
    end)
end

---@param library_id string|number
---@param page_number number|nil
---@param page_size number|nil
---@param cb fun(data: table[]|nil, err: string|nil)
---@return table|nil
function Client:fetchSeriesPage(library_id, page_number, page_size, cb)
    if not self:configured() then
        cb(nil, _("未配置服务器地址或 API Key"))
        return nil
    end
    local body = {
        Statements = {
            { Field = 19, Value = tostring(library_id), Comparison = 0 },
        },
        Combination = 1,
        SortOptions = { SortField = 1, IsAscending = true },
    }
    local ok, encoded = pcall(JSON.encode, body)
    if not ok or type(encoded) ~= "string" then
        cb(nil, _("请求编码失败"))
        return nil
    end
    local url = self:_url("/api/Series/all-v2", {
        pageSize = tostring(page_size or 1000),
        pageNumber = tostring(page_number or 1),
    })
    if not url then
        cb(nil, _("未配置服务器地址或 API Key"))
        return nil
    end
    return Request.request({
        url = url,
        method = "POST",
        headers = { ["x-api-key"] = self.api_key, ["Content-Type"] = "application/json" },
        body = encoded,
        timeout = 30,
    }, function(res, req_err)
        if req_err then
            cb(nil, tostring(req_err))
            return
        end
        if not res then
            cb(nil, _("网络不可用，请先连接 Wi-Fi"))
            return
        end
        local code = tonumber(res.code)
        if not code then
            cb(nil, _("请求失败"))
            return
        end
        if code == 401 or code == 403 then
            cb(nil, _("Kavita API Key 无效或无权限"))
            return
        end
        if code < 200 or code >= 300 then
            cb(nil, T(_("请求失败 (HTTP %1)"), tostring(code)))
            return
        end
        local raw = Text.stripBom(res.body or "")
        local ok2, data = pcall(JSON.decode, raw)
        if not ok2 or type(data) ~= "table" then
            cb(nil, _("响应不是 JSON"))
            return
        end
        cb(data)
    end)
end

Client.MIN_VERSION = MIN_VERSION
Client.parseVersion = parseVersion
Client.versionGte = versionGte

return Client
