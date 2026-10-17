--[[--
Kavita HTTP 客户端：x-api-key 认证，只回 wire，不做领域转换。
调用方先看 configured()，这里不再判。

@module moonsource_kavita.client
--]]

local JSON = require("json")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("gettext")
local T = require("ffi/util").template

--- 单次请求默认超时（秒）。全量书架（`all-v2`）在慢设备 / 慢服务器上 30s 拉不完，
--- 一个请求超时就会中断整轮同步、书架永远加载不出来，所以默认给足，并允许在设置里调大。
local DEFAULT_TIMEOUT = 60
--- 设置里的合法区间：太小等于次次超时，太大等于卡住没法恢复。
local MIN_TIMEOUT = 5
local MAX_TIMEOUT = 600

---@class KavitaClient
---@field base_url string
---@field api_key string
---@field timeout integer 单次请求超时秒（含下载）
local Client = {}
Client.__index = Client
Client.DEFAULT_TIMEOUT = DEFAULT_TIMEOUT
Client.MIN_TIMEOUT = MIN_TIMEOUT
Client.MAX_TIMEOUT = MAX_TIMEOUT

---@param cfg { base_url: string|nil, api_key: string|nil, timeout: integer|string|nil }
---@return KavitaClient
function Client.new(cfg)
    local timeout = math.floor(tonumber(cfg.timeout) or DEFAULT_TIMEOUT)
    if timeout < MIN_TIMEOUT then timeout = MIN_TIMEOUT end
    if timeout > MAX_TIMEOUT then timeout = MAX_TIMEOUT end
    return setmetatable({
        base_url = Text.rtrimSlashes(cfg.base_url),
        api_key = Text.stripWhitespace(cfg.api_key),
        timeout = timeout,
    }, Client)
end

---@return boolean
function Client:configured()
    return self.base_url ~= "" and self.api_key ~= ""
end

--- Kavita 按 User-Agent 识别客户端；不带时设备列表里显示 Unknown Client。
---@return table
function Client:headers()
    local device = package.loaded["device"]
    local platform = type(device) == "table" and device.isAndroid and device:isAndroid() and "Android" or "Linux"
    return { ["x-api-key"] = self.api_key, ["User-Agent"] = "KOReader/MoonBook (" .. platform .. ")" }
end

--- 查询串：单值参数与 `Text.formEncode` 同形；值是数组时展开成重复键
--- （Kavita 的 `Libraries` 过滤器要 `&Libraries=8&Libraries=10`，逗号串会被当成一个库、恒返回 0 条）。
---@param query table
---@return string
local function queryString(query)
    local keys = {}
    for key in pairs(query) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _idx, key in ipairs(keys) do
        local value = query[key]
        if type(value) == "table" then
            for _i, item in ipairs(value) do
                parts[#parts + 1] = Text.urlEncode(key) .. "=" .. Text.urlEncode(item)
            end
        elseif value ~= nil then
            parts[#parts + 1] = Text.urlEncode(key) .. "=" .. Text.urlEncode(value)
        end
    end
    return table.concat(parts, "&")
end

---@param path string
---@param query table|nil
---@return string
function Client:url(path, query)
    if query then return self.base_url .. path .. "?" .. queryString(query) end
    return self.base_url .. path
end

--- 原始请求：2xx 回 cb(res)（带状态码与响应头，分页接口要读 `Pagination` 头）；
--- 401/403 与非 2xx 一律 cb(nil, err, code)。
---@param method string
---@param path string
---@param query table|nil
---@param body table|nil JSON 请求体
---@param cb fun(res: table|nil, err: string|nil, code: integer|nil)
---@return HttpJob
function Client:requestRes(method, path, query, body, cb)
    local headers = self:headers()
    local payload
    if body then
        headers["Content-Type"] = "application/json"
        payload = JSON.encode(body)
    end
    return Request.request({
        url = self:url(path, query), method = method, headers = headers, body = payload, timeout = self.timeout,
    }, function(res, err)
        if err or not res then
            cb(nil, err and tostring(err) or _("网络请求失败"))
            return
        end
        local code = tonumber(res.code)
        if code == 401 or code == 403 then
            cb(nil, _("Kavita API Key 无效或无权限"), code)
        elseif not Request.ok(code) then
            cb(nil, T(_("请求失败 (HTTP %1)"), tostring(code)), code)
        else
            -- 只规范化 body；响应头原样带着（`Request.header` 认 Turbo 头与普通表两种）。
            cb({ code = code, headers = res.headers, body = Text.stripBom(res.body or "") }, nil, code)
        end
    end)
end

--- 原始请求：2xx 回 cb(body)，否则 cb(nil, err, code)。
---@param method string
---@param path string
---@param query table|nil
---@param body table|nil JSON 请求体
---@param cb fun(body: string|nil, err: string|nil, code: integer|nil)
---@return HttpJob
function Client:request(method, path, query, body, cb)
    return self:requestRes(method, path, query, body, function(res, err, code)
        cb(res and res.body, err, code)
    end)
end

--- JSON 解码：写接口成功时回空体，按 {} 交回；服务端或反代可能回 HTML 错误页，
--- 解析失败按请求失败处理，不让异常冒到回调链外。
---@param raw string
---@return table|nil, string|nil
local function decodeJson(raw)
    if Text.trim(raw) == "" then return {} end
    local ok, data = pcall(JSON.decode, raw)
    if ok and type(data) == "table" then return data end
    return nil, _("响应不是 JSON")
end

--- JSON 请求。
---@param method string
---@param path string
---@param query table|nil
---@param body table|nil
---@param cb fun(data: table|nil, err: string|nil, code: integer|nil)
---@return HttpJob
function Client:json(method, path, query, body, cb)
    return self:request(method, path, query, body, function(raw, err, code)
        if not raw then
            cb(nil, err, code)
            return
        end
        local data, derr = decodeJson(raw)
        cb(data, derr, code)
    end)
end

--- 分页接口的 JSON 请求：Kavita 把分页信息放在响应头 `Pagination` 里（不在 body），
--- 回调第四参是本页声明的总页数（缺失 / 不可信时为 nil，调用方自行兜底）。
--- 头的内容只由 client 解释，源不必碰 `http.request`。
---@param method string
---@param path string
---@param query table|nil
---@param body table|nil
---@param cb fun(data: table|nil, err: string|nil, code: integer|nil, pages: integer|nil)
---@return HttpJob
function Client:jsonPaged(method, path, query, body, cb)
    return self:requestRes(method, path, query, body, function(res, err, code)
        if not res then
            cb(nil, err, code)
            return
        end
        local data, derr = decodeJson(res.body)
        cb(data, derr, code, Client.totalPages(Request.header(res, "Pagination")))
    end)
end

--- `Pagination` 头 → 总页数：`{"currentPage":1,"itemsPerPage":200,"totalItems":316,"totalPages":2}`。
--- 缺失 / 解析不出 / 负数一律回 nil（当分页信息不可信），调用方按「本页拉满就还有下一页」兜底。
---@param raw string|nil
---@return integer|nil
function Client.totalPages(raw)
    if type(raw) ~= "string" or raw == "" then return nil end
    local ok, data = pcall(JSON.decode, raw)
    if not ok or type(data) ~= "table" then return nil end
    local pages = tonumber(data.totalPages)
    if not pages or pages < 0 then return nil end
    return math.floor(pages)
end

--- 下载一卷原文件。Request.download 遇到非 2xx 也会落盘，这里删掉并报错。
---@param chapter_id integer
---@param dest string
---@param on_progress fun(bytes: number, total: number|nil)
---@param cb fun(ok: boolean, err: string|nil)
---@return HttpJob
function Client:download(chapter_id, dest, on_progress, cb)
    return Request.download({
        url = self:url("/api/Download/chapter", { chapterId = chapter_id }),
        headers = self:headers(), timeout = self.timeout, on_progress = on_progress,
    }, dest, function(ok, err, res)
        if ok and not Request.ok(res and res.code) then
            os.remove(dest)
            ok, err = false, T(_("请求失败 (HTTP %1)"), tostring(res and res.code))
        end
        cb(ok, err and tostring(err))
    end)
end

return Client
