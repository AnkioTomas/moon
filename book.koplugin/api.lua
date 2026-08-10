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
function Api:_request(method, path, query, body_tbl, sink_file, binary)
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
        local payload = {}
        for k, v in pairs(body_tbl) do
            table.insert(payload, tostring(k) .. "=" .. socketurl.escape(tostring(v)))
        end
        local body = table.concat(payload, "&")
        headers["Content-Type"] = "application/x-www-form-urlencoded"
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

--- 最近阅读；若 /recent 未部署则回退 list + progressTimestamp 排序
function Api:recentBooks(limit)
    limit = limit or 8
    local res, err = self:_request("GET", "/index/book/recent", { limit = limit })
    if res then
        return res
    end

    logger.warn("book.api recent fallback to list:", err)
    local list, err2 = self:listBooks{ page = 1, pageSize = math.max(50, limit * 6) }
    if not list then
        return nil, err or err2
    end
    local rows = list.data or {}
    table.sort(rows, function(a, b)
        local ta = tonumber(a.progressTimestamp) or 0
        local tb = tonumber(b.progressTimestamp) or 0
        if ta == tb then
            local pa = tonumber(a.progressPercent) or 0
            local pb = tonumber(b.progressPercent) or 0
            return pa > pb
        end
        return ta > tb
    end)
    local out = {}
    for _, row in ipairs(rows) do
        local ts = tonumber(row.progressTimestamp) or 0
        local pct = tonumber(row.progressPercent) or 0
        if ts > 0 or pct > 0 then
            table.insert(out, row)
            if #out >= limit then break end
        end
    end
    return { code = 200, msg = "success", data = out, count = #out }
end

function Api:filters()
    return self:_request("GET", "/index/book/filters")
end

function Api:getProgress(filename)
    return self:_request("GET", "/index/book/progress", {
        filename = filename,
    })
end

function Api:updateProgress(filename, frac, spine, page, percent_text)
    return self:_request("POST", "/index/book/progressUpdate", nil, {
        filename = filename,
        frac = frac,
        spine = spine or 0,
        page = page or 0,
        percent = percent_text or (string.format("%.2f", (frac or 0) * 100) .. "%"),
    })
end

function Api:downloadBook(filename, dest_path)
    local file, err = io.open(dest_path, "wb")
    if not file then
        return nil, err or "无法创建本地文件"
    end
    local ok, msg = self:_request(
        "GET",
        "/index/book/file",
        { filename = filename },
        nil,
        ltn12.sink.file(file),
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

function Api:downloadCover(filename, dest_path)
    -- 最终路径带真实后缀；先下到临时文件再改名
    local tmp = dest_path .. ".part"
    local file, err = io.open(tmp, "wb")
    if not file then
        return nil, err or "无法创建封面文件"
    end
    local ok, msg = self:_request(
        "GET",
        "/index/book/cover",
        { filename = filename },
        nil,
        ltn12.sink.file(file),
        true
    )
    -- sink.file 会自行 close；失败时确保删掉半截文件
    if not ok then
        pcall(os.remove, tmp)
        return nil, msg
    end
    local attr_ok, size = pcall(function()
        local f = io.open(tmp, "rb")
        if not f then return nil end
        local n = f:seek("end")
        f:close()
        return n
    end)
    if not attr_ok or not size or size < 64 then
        pcall(os.remove, tmp)
        return nil, "封面为空"
    end
    local ext = sniffExt(tmp)
    if not ext then
        pcall(os.remove, tmp)
        return nil, "封面不是图片"
    end
    local final = dest_path
    if not final:match("%.%w+$") then
        final = dest_path .. ext
    end
    pcall(os.remove, final)
    local renamed, rename_err = os.rename(tmp, final)
    if not renamed then
        pcall(os.remove, tmp)
        return nil, rename_err or "封面改名失败"
    end
    return true, final
end

return Api
