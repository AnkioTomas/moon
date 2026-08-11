--[[--
Book API 客户端（HTTP + Bearer Token）

@module koplugin.book.api
--]]

local http = require("socket.http")
-- 必须拉起 ssl.https，否则 https:// 会拿到奇怪响应 / 非 JSON
pcall(require, "ssl.https")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketurl = require("socket.url")
local socketutil = require("socketutil")
local JSON = require("json")
local logger = require("logger")

local Api = {}

local function trim_slash(url)
    return (url or ""):gsub("/+$", "")
end

local function previewBody(raw)
    if type(raw) ~= "string" or raw == "" then
        return ""
    end
    return (raw:gsub("%s+", " "):sub(1, 120))
end

function Api:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o.base_url = trim_slash(o.base_url or "")
    o.token = o.token or ""
    return o
end

function Api:configured()
    return self.base_url ~= "" and self.token ~= ""
end

--- binary=true 时不要求 JSON，Accept */*
--- as_json=true 时 body 以 application/json 发送（统计上报用）；默认仍为 form
function Api:_request(method, path, query, body_tbl, sink_file, binary, as_json)
    if not self:configured() then
        return nil, "未配置服务器或令牌"
    end

    local url = self.base_url .. path
    if query and next(query) then
        local parts = {}
        for k, v in pairs(query) do
            table.insert(parts, tostring(k) .. "=" .. socketurl.escape(tostring(v)))
        end
        url = url .. "?" .. table.concat(parts, "&")
    end

    local headers = {
        ["Authorization"] = "Bearer " .. self.token,
        ["Accept"] = binary and "*/*" or "application/json",
        ["User-Agent"] = socketutil.USER_AGENT,
        -- 二进制下载必须 close：服务端若缺 Content-Length，keep-alive 会挂死/超时
        ["Connection"] = binary and "close" or "keep-alive",
    }

    local source
    if body_tbl then
        local body
        if as_json then
            local ok, encoded = pcall(JSON.encode, body_tbl)
            if not ok or type(encoded) ~= "string" then
                return nil, "JSON 编码失败"
            end
            body = encoded
            headers["Content-Type"] = "application/json"
        else
            local payload = {}
            for k, v in pairs(body_tbl) do
                table.insert(payload, tostring(k) .. "=" .. socketurl.escape(tostring(v)))
            end
            body = table.concat(payload, "&")
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        end
        headers["Content-Length"] = tostring(#body)
        source = ltn12.source.string(body)
    end

    local chunks = {}
    local sink = sink_file or ltn12.sink.table(chunks)
    local request = {
        url = url,
        method = method or "GET",
        headers = headers,
        source = source,
        sink = sink,
    }

    socketutil:set_timeout(10, sink_file and 120 or 30)
    local code, headers_resp = socket.skip(1, http.request(request))
    socketutil:reset_timeout()

    if code == socketutil.TIMEOUT_CODE
        or code == socketutil.SSL_HANDSHAKE_CODE
        or code == socketutil.SINK_TIMEOUT_CODE then
        return nil, "网络超时"
    end

    if not code or tonumber(code) == nil then
        logger.warn("book.api request failed", url, code)
        return nil, "请求失败: " .. tostring(code)
    end

    code = tonumber(code)
    if sink_file then
        if code < 200 or code >= 300 then
            return nil, "下载失败 HTTP " .. tostring(code)
        end
        return true, headers_resp
    end

    local raw = table.concat(chunks)
    -- 去掉 BOM
    if raw:sub(1, 3) == "\239\187\191" then
        raw = raw:sub(4)
    end
    local data
    local jok, decoded = pcall(JSON.decode, raw)
    if jok and type(decoded) == "table" then
        data = decoded
    end

    if code == 401 or (data and data.code == 401) then
        return nil, (data and data.msg) or "令牌无效或未登录"
    end
    if not data then
        logger.warn("book.api non-json", url, code, previewBody(raw))
        return nil, string.format("响应不是 JSON (HTTP %s) %s", tostring(code), previewBody(raw))
    end
    if data.code and data.code ~= 200 then
        return nil, data.msg or ("错误码 " .. tostring(data.code))
    end
    return data
end

function Api:ping()
    return self:_request("GET", "/index/auth/ping")
end

function Api:listBooks(opts)
    opts = opts or {}
    return self:_request("GET", "/index/book/list", {
        page = opts.page or 1,
        pageSize = opts.pageSize or 50,
        search = opts.search or "",
        series = opts.series or "",
        category = opts.category or "",
        favorite = opts.favorite or "",
        finished = opts.finished or "",
        author = opts.author or "",
    })
end

--- 最近阅读：只走云端 /recent；成功结果缓存 5 分钟
local RECENT_TTL = 5 * 60
local _recent_cache = { t = 0, limit = nil, data = nil }

function Api.clearRecentCache()
    _recent_cache.t = 0
    _recent_cache.limit = nil
    _recent_cache.data = nil
end

function Api:recentBooks(limit)
    limit = limit or 8
    local now = os.time()
    if _recent_cache.data
        and _recent_cache.limit == limit
        and (now - (_recent_cache.t or 0)) < RECENT_TTL then
        return _recent_cache.data
    end
    local res, err = self:_request("GET", "/index/book/recent", { limit = limit })
    if res then
        _recent_cache.t = now
        _recent_cache.limit = limit
        _recent_cache.data = res
    end
    return res, err
end

function Api:filters()
    return self:_request("GET", "/index/book/filters")
end

--- 藏书统计（服务端新增）；失败由调用方降级显示
function Api:stats()
    return self:_request("GET", "/index/book/stats")
end

--- 注册阅读设备（高维统计）
--- body: { id, model }
function Api:registerReadingDevice(device_id, model)
    return self:_request("POST", "/index/stats/device", nil, {
        id = device_id,
        model = model or "Unknown",
    }, nil, false, true)
end

--- 上报阅读统计（KOReader page_stat 语义）
--- body: { books = {}, stats = {}, device_id? }
function Api:importReadingStats(payload)
    local res, err = self:_request("POST", "/index/stats/import", nil, payload or {}, nil, false, true)
    if res then
        Api.clearInsightCache()
    end
    return res, err
end

--- 阅读活动汇总 KPI
function Api:readingSummary()
    return self:_request("GET", "/index/stats/summary")
end

--- 多维统计：成功结果缓存 30 分钟
local INSIGHT_TTL = 30 * 60
local _insight_cache = { t = 0, data = nil }

function Api.clearInsightCache()
    _insight_cache.t = 0
    _insight_cache.data = nil
end

function Api:readingInsight()
    local now = os.time()
    if _insight_cache.data and (now - (_insight_cache.t or 0)) < INSIGHT_TTL then
        return _insight_cache.data
    end
    local res, err = self:_request("GET", "/index/stats/insight")
    if res then
        _insight_cache.t = now
        _insight_cache.data = res
    end
    return res, err
end

--- 每日一言（独立公网接口，不走 Book 服务器）
function Api.hitokoto()
    local url = "https://api.ankio.net/hitokoto"
    local chunks = {}
    local request = {
        url = url,
        method = "GET",
        headers = {
            ["Accept"] = "application/json",
            ["User-Agent"] = socketutil.USER_AGENT,
            ["Connection"] = "close",
        },
        sink = ltn12.sink.table(chunks),
    }
    socketutil:set_timeout(8, 15)
    local code = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    if not code or tonumber(code) == nil then
        return nil, "一言请求失败"
    end
    code = tonumber(code)
    local raw = table.concat(chunks)
    if raw:sub(1, 3) == "\239\187\191" then
        raw = raw:sub(4)
    end
    local jok, data = pcall(JSON.decode, raw)
    if not jok or type(data) ~= "table" then
        return nil, "一言响应不是 JSON"
    end
    if code ~= 200 or (data.code and data.code ~= 200) then
        return nil, data.msg or ("一言 HTTP " .. tostring(code))
    end
    local row = data.data or data
    if type(row) ~= "table" or not row.hitokoto then
        return nil, "一言数据为空"
    end
    return { code = 200, data = row }
end

function Api:getProgress(filename)
    return self:_request("GET", "/index/book/progress", {
        filename = filename,
    })
end

function Api:updateProgress(filename, frac, spine, page, percent_text)
    local res, err = self:_request("POST", "/index/book/progressUpdate", nil, {
        filename = filename,
        frac = frac,
        spine = spine or 0,
        page = page or 0,
        percent = percent_text or (string.format("%.2f", (frac or 0) * 100) .. "%"),
    })
    if res then
        Api.clearRecentCache()
    end
    return res, err
end

--- HEAD 探测 Content-Length；服务端不支持则返回 nil
function Api:probeFileSize(filename)
    if not filename or filename == "" then
        return nil
    end
    local ok, headers = self:_request(
        "HEAD",
        "/index/book/file",
        { filename = filename },
        nil,
        ltn12.sink.null(),
        true
    )
    if not ok or type(headers) ~= "table" then
        return nil
    end
    local cl = headers["content-length"] or headers["Content-Length"]
    local n = tonumber(cl)
    if n and n > 0 then
        return n
    end
    return nil
end

--- on_progress(bytes) 可选；在阻塞下载过程中回调已写入字节数
function Api:downloadBook(filename, dest_path, on_progress)
    local file, err = io.open(dest_path, "wb")
    if not file then
        return nil, err or "无法创建本地文件"
    end
    local sink = ltn12.sink.file(file)
    if on_progress and socketutil.chainSinkWithProgressCallback then
        sink = socketutil.chainSinkWithProgressCallback(sink, on_progress)
    end
    local ok, msg = self:_request(
        "GET",
        "/index/book/file",
        { filename = filename },
        nil,
        sink,
        true
    )
    if not ok then
        os.remove(dest_path)
        return nil, msg
    end
    return true
end

local function sniffExt(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local head = f:read(16) or ""
    f:close()
    if head:sub(1, 3) == "\255\216\255" then return ".jpg" end
    if head:sub(1, 8) == "\137PNG\r\n\26\n" then return ".png" end
    if head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WEBP" then return ".webp" end
    if head:sub(1, 6) == "GIF87a" or head:sub(1, 6) == "GIF89a" then return ".gif" end
    return nil
end

-- /webdav/{filename}；按段编码，保留路径分隔
local function webdavPath(filename)
    filename = tostring(filename or ""):gsub("^/+", "")
    local parts = {}
    for seg in filename:gmatch("[^/]+") do
        -- 路径段编码：空格必须是 %20，不能是 query 风格的 +
        local enc = seg:gsub("([^%w%-%._~])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
        table.insert(parts, enc)
    end
    return "/webdav/" .. table.concat(parts, "/")
end

function Api:downloadCover(filename, dest_path)
    if not filename or filename == "" then
        return nil, "无效文件名"
    end
    local chunks = {}
    local ok, msg = self:_request(
        "GET",
        webdavPath(filename),
        nil,
        nil,
        ltn12.sink.table(chunks),
        true
    )
    if not ok then
        return nil, msg
    end
    local data = table.concat(chunks)
    if not data or #data < 64 then
        return nil, "封面为空"
    end
    local tmp = dest_path .. ".part"
    local file, err = io.open(tmp, "wb")
    if not file then
        return nil, err or "无法创建封面文件"
    end
    file:write(data)
    file:close()
    local ext = sniffExt(tmp)
    if not ext then
        pcall(os.remove, tmp)
        return nil, "封面不是图片"
    end
    -- dest_path 是按书籍文件名生成的缓存基名，通常自带 .epub 等文档后缀。
    -- 封面必须再追加实际图片后缀，ImageWidget 才能通过扩展名识别并解码。
    local final = dest_path .. ext
    pcall(os.remove, final)
    local renamed, rename_err = os.rename(tmp, final)
    if not renamed then
        local rf = io.open(tmp, "rb")
        local wf = rf and io.open(final, "wb")
        if not (rf and wf) then
            if rf then rf:close() end
            pcall(os.remove, tmp)
            return nil, rename_err or "封面改名失败"
        end
        wf:write(rf:read("*a") or "")
        wf:close()
        rf:close()
        pcall(os.remove, tmp)
    end
    return true, final
end

return Api
