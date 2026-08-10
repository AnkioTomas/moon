--[[--
Book API 客户端（HTTP + Bearer Token）

@module koplugin.book.api
--]]

local http = require("socket.http")
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

function Api:_request(method, path, query, body_tbl, sink_file)
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
        ["Accept"] = "application/json",
        ["User-Agent"] = socketutil.USER_AGENT,
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
    local code = socket.skip(1, http.request(request))
    socketutil:reset_timeout()

    if code == socketutil.TIMEOUT_CODE
        or code == socketutil.SSL_HANDSHAKE_CODE
        or code == socketutil.SINK_TIMEOUT_CODE then
        return nil, "网络超时"
    end

    if not code or tonumber(code) == nil then
        logger.warn("book.api request failed", url, code)
        return nil, "请求失败"
    end

    code = tonumber(code)
    if sink_file then
        if code < 200 or code >= 300 then
            return nil, "下载失败 HTTP " .. tostring(code)
        end
        return true
    end

    local raw = table.concat(chunks)
    local data
    local jok, decoded = pcall(JSON.decode, raw)
    if jok then
        data = decoded
    end

    if code == 401 or (data and data.code == 401) then
        return nil, "令牌无效或未登录"
    end
    if not data then
        return nil, "响应不是 JSON (HTTP " .. tostring(code) .. ")"
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
        ltn12.sink.file(file)
    )
    if not ok then
        os.remove(dest_path)
        return nil, msg
    end
    return true
end

function Api:downloadCover(filename, dest_path)
    local file, err = io.open(dest_path, "wb")
    if not file then
        return nil, err or "无法创建封面文件"
    end
    local ok, msg = self:_request(
        "GET",
        "/index/book/cover",
        { filename = filename },
        nil,
        ltn12.sink.file(file)
    )
    if not ok then
        os.remove(dest_path)
        return nil, msg
    end
    local f = io.open(dest_path, "rb")
    if not f then
        return nil, "封面为空"
    end
    local size = f:seek("end")
    f:close()
    if not size or size < 64 then
        os.remove(dest_path)
        return nil, "封面无效"
    end
    return true
end

return Api
