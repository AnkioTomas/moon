--[[--
Z-Library eAPI 客户端（HTTP Basic 门禁 + Z-Library 账号会话，仅异步）。

@module koplugin.book.zlib.client
--]]

local JSON = require("json")
local Request = require("http.request")
local Cache = require("http.cache")
local Text = require("utils.text")
local logger = require("utils.log")
local _ = require("gettext")
local T = require("ffi/util").template

-- 官方种子镜像（不带尾斜杠）。前排入口来自上游域名清单，并经
-- eAPI /info/ok 实测可用；旧入口保留作地区性回退。
local SEED_URLS = {
    "https://fuckfbi.ru",
    "https://zh.chris101.ru",
    "https://zh.z-lib.gd",
    "https://z-library.la",
    "https://librella.tw",
    "https://bookabooki.tw",
    "https://zh.z-library.sk",
    "https://librella.fi",
    "https://lexlib.tw",
    "https://lexlib.fi",
    "https://bookabooki.fi",
    "https://z-library.sk",
    "https://thai-books.sk",
    "https://frenchbooks.sk",
    "https://portuguese-books.sk",
    "https://urdu-books.sk",
    "https://z-library.ec",
    "https://spanish-books.sk",
    "https://italian-books.sk",
    "https://czechbooks.sk",
    "https://z-lib.sk",
    "https://german-books.sk",
    "https://zh.z2026.ru",
    "https://sss101.ru"
}

local USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/96.0.4664.110 Safari/537.36"

local MAX_REDIRECT_HOPS = 5
local MAX_BASE_ATTEMPTS = 3

-- 钉住的镜像 origin（重定向跨主机或故障转移成功时更新，本次会话有效）
local pinned_base

local Client = {}
Client.__index = Client

-- ---------------------------------------------------------------------------
-- URL 工具
-- ---------------------------------------------------------------------------

--- 取 URL 的 origin（scheme://host[:port]）与其组成部分
---@param url string|nil
---@return string|nil origin, string|nil scheme, string|nil host
local function originOf(url)
    local scheme, host, port = tostring(url or ""):match("^([hH][tT][tT][pP][sS]?)://([^/:]+):?(%d*)")
    if not scheme then return nil end
    local origin = scheme:lower() .. "://" .. host
    if port ~= "" then origin = origin .. ":" .. port end
    return origin, scheme:lower(), host
end

--- 30x 的 Location 允许是相对地址（RFC 9110）：相对当前 URL 解析成绝对地址
---@param current_url string
---@param location string|nil
---@return string|nil
local function absoluteUrl(current_url, location)
    if type(location) ~= "string" or location == "" then return nil end
    if location:match("^[hH][tT][tT][pP][sS]?://") then return location end
    local origin, scheme = originOf(current_url)
    if not origin then return nil end
    if location:sub(1, 2) == "//" then return scheme .. ":" .. location end
    if location:sub(1, 1) == "/" then return origin .. location end
    if location:sub(1, 1) == "?" then
        return (current_url:match("^[^?#]*") or current_url) .. location
    end
    local dir = current_url:match("^(https?://.*/)") or (origin .. "/")
    return dir .. location
end

-- ---------------------------------------------------------------------------
-- 镜像选择与故障转移
-- ---------------------------------------------------------------------------

--- 候选 base 列表：用户配置 > 钉住 > 种子；去重，最多 MAX_BASE_ATTEMPTS 个
---@param cfg table|nil
---@return string[]
local function baseCandidates(cfg)
    local out, seen = {}, {}
    --- 归一化一个候选地址（去空白、去尾部斜杠、补 https 前缀）后按去重追加。
    ---@param u string|nil 候选地址，非字符串或归一化后为空则跳过
    local function add(u)
        if type(u) ~= "string" then return end
        u = u:gsub("%s+", ""):gsub("/+$", "")
        if u == "" then return end
        if not u:match("^[hH][tT][tT][pP][sS]?://") then u = "https://" .. u end
        if not seen[u] then
            seen[u] = true
            out[#out + 1] = u
        end
    end
    add(cfg and cfg.base_url)
    add(pinned_base)
    for _, seed in ipairs(SEED_URLS) do add(seed) end
    local capped = {}
    for i = 1, math.min(MAX_BASE_ATTEMPTS, #out) do capped[i] = out[i] end
    return capped
end

-- WAF/风控的「验证浏览器」拦截页：不是故障，重试没意义，换镜像才有用
local CHALLENGE_MARKERS = {
    "Verifying your browser",
    "DiamWall",
    "/cdn-cgi/mitigation/",
    "__cf_chl",
    "Just a moment",
    "Checking your browser",
}

--- 判断响应体是否为 WAF 或浏览器验证页，而非 eAPI JSON。
---@param body any
---@return boolean
local function looksLikeChallenge(body)
    if type(body) ~= "string" or body == "" then return false end
    local head = body:sub(1, 4096)
    if not head:find("<", 1, true) then return false end
    for _, marker in ipairs(CHALLENGE_MARKERS) do
        if head:find(marker, 1, true) then return true end
    end
    return false
end

--- 传输层错误分类（Turbo res.error.code / message）
---@param res table|nil
---@param err any
---@return string
local function classifyTransportError(res, err)
    local code = type(res and res.error) == "table" and res.error.code or nil
    local msg = tostring(type(res and res.error) == "table" and res.error.message or err or "")
    if code == -5 or code == -6 then -- CONNECT_TIMEOUT / REQUEST_TIMEOUT
        return _("连接超时，请检查网络")
    end
    if msg:lower():find("resolve") or msg:lower():find("name") then
        return _("找不到服务器地址，镜像可能已失效")
    end
    return msg ~= "" and msg or _("网络请求失败")
end

local REDIRECT_CODES = { [301] = true, [302] = true, [303] = true, [307] = true, [308] = true }

-- ---------------------------------------------------------------------------
-- 客户端
-- ---------------------------------------------------------------------------

--- 创建客户端；配置表由调用方拥有，登录成功后会原地写入会话字段。
---@param cfg table|nil
---@return table
function Client.new(cfg)
    return setmetatable({ cfg = cfg or {} }, Client)
end

--- 判断是否已有可用于下载的 Z-Library 会话。
---@return boolean
function Client:hasSession()
    local cfg = self.cfg
    return (cfg.user_id or "") ~= "" and (cfg.user_key or "") ~= ""
end

--- 判断是否具备登录所需的邮箱和密码。
---@return boolean
function Client:hasCredentials()
    local cfg = self.cfg
    return (cfg.email or "") ~= "" and (cfg.password or "") ~= ""
end

--- 构造 API 或下载请求头。
---@param with_session boolean|nil 是否附带 remix 会话 Cookie
---@return table<string, string>
function Client:headers(with_session)
    local headers = {
        ["Accept"] = "application/json, text/javascript, */*; q=0.01",
        ["User-Agent"] = USER_AGENT,
    }
    if with_session and self:hasSession() then
        headers["Cookie"] = string.format("remix_userid=%s; remix_userkey=%s", self.cfg.user_id, self.cfg.user_key)
    end
    return headers
end

--- 解码 eAPI JSON 响应。
---@param body any
---@return table|nil data
---@return string|nil err
local function decode(body)
    if type(body) ~= "string" or body == "" then return nil, _("响应为空") end
    local ok, data = pcall(JSON.decode, body)
    if not ok or type(data) ~= "table" then return nil, _("无效响应格式") end
    return data
end

--- 从 eAPI 响应提取可展示的错误文案。
---@param data table|nil
---@param fallback string
---@return string
local function apiError(data, fallback)
    local err = type(data) == "table" and data.error or nil
    if type(err) == "table" then err = err.message end
    if err ~= nil and tostring(err) ~= "" then return tostring(err) end
    if type(data) == "table" and type(data.message) == "string" and data.message ~= "" then
        return data.message
    end
    return fallback
end

--- 带镜像故障转移与 30x 手动跟随的 JSON 请求。
--- 成功 cb(data)；最终失败 cb(nil, err)。
---@param method string
---@param path string eAPI 路径（以 / 开头）
---@param opts table|nil session、form、cache_ttl、timeout
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:_jsonAsync(method, path, opts, cb)
    opts = opts or {}
    local bases = baseCandidates(self.cfg)
    local cancelled = false
    local job
    local cache_job
    local result = {}
    --- 取消在途请求：置位取消标记，并中断缓存读取与当前 HTTP 请求。
    function result.cancel()
        cancelled = true
        if cache_job and cache_job.cancel then cache_job.cancel() end
        if job and job.cancel then job.cancel() end
    end

    local body = opts.form and Text.formEncode(opts.form) or nil
    local cache_ttl = tonumber(opts.cache_ttl) or 0
    local cache_key = cache_ttl > 0 and Cache.key(method, "zlib://api" .. path, opts.form) or nil
    local headers = self:headers(opts.session)
    if body then
        headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
        headers["X-Requested-With"] = "XMLHttpRequest"
    end
    local last_err = _("网络请求失败")
    local bi = 0
    local current_base

    local issue
    --- 请求下一个候选镜像；候选耗尽时只回调一次最终错误。
    local function tryNextBase()
        if cancelled then return end
        bi = bi + 1
        if bi > #bases then
            logger.warn("book.zlib request failed", method, path,
                "attempts", #bases, last_err)
            cb(nil, last_err)
            return
        end
        current_base = bases[bi]
        local url = current_base .. path
        issue(url, method, body, headers, { [url] = true }, 0)
    end

    --- 发出单次请求或继续跟随重定向。
    ---@param url string
    ---@param m string
    ---@param req_body string|nil
    ---@param headers table<string, string>
    ---@param seen table<string, boolean> 已请求过的 URL（重定向循环检测）
    ---@param hops number 已跟随的跳数
    issue = function(url, m, req_body, headers, seen, hops)
        job = Request.request({
            url = url,
            method = m,
            body = req_body,
            headers = headers,
            timeout = opts.timeout or 30,
        }, function(res, err)
            if cancelled then return end
            local code = res and tonumber(res.code) or nil

            -- 传输层失败：换下一个候选镜像
            if not code then
                if originOf(url) == pinned_base then pinned_base = nil end
                last_err = classifyTransportError(res, err)
                logger.dbg("book.zlib failover", method, path,
                    current_base, "transport", last_err)
                tryNextBase()
                return
            end

            -- 30x：手动跟随（Turbo 默认不跟随）
            if REDIRECT_CODES[code] then
                local target = absoluteUrl(url, Request.header(res, "location"))
                if not target then
                    last_err = T(_("HTTP %1"), code)
                    tryNextBase()
                    return
                end
                if seen[target] or hops + 1 > MAX_REDIRECT_HOPS then
                    cb(nil, _("重定向过多"))
                    return
                end
                seen[target] = true
                -- 跨主机 = 镜像迁移；成功后按实际请求 URL 钉住新 origin。
                -- Location 的路径和查询是服务端给出的请求目标，不能丢掉。
                local new_origin = originOf(target)
                local is_mirror_move = new_origin and new_origin ~= originOf(url)
                logger.dbg("book.zlib redirect", code, originOf(url), new_origin or target)
                if is_mirror_move and m ~= "GET" then
                    -- 镜像迁移：保持 POST 和 body，但跟随完整的 Location。
                    issue(target, m, req_body, headers, seen, hops + 1)
                elseif code ~= 307 and code ~= 308 and m ~= "GET" then
                    -- 站内 301/302/303：转 GET 丢 body 及 Content-* 头
                    local kept = {}
                    for k, v in pairs(headers) do
                        local lk = k:lower()
                        if lk ~= "content-type" and lk ~= "content-length" then
                            kept[k] = v
                        end
                    end
                    issue(target, "GET", nil, kept, seen, hops + 1)
                else
                    issue(target, m, req_body, headers, seen, hops + 1)
                end
                return
            end

            -- 5xx 是镜像自己病了：换下一个
            if code >= 500 then
                last_err = T(_("HTTP %1"), code)
                logger.dbg("book.zlib failover", method, path,
                    current_base, "status", code)
                tryNextBase()
                return
            end

            -- bot 挑战页：不是 JSON，是拦截页；换镜像才可能有用
            if looksLikeChallenge(res.body) then
                last_err = _("服务器拒绝自动访问，正在尝试其它镜像")
                logger.dbg("book.zlib failover", method, path,
                    current_base, "bot_challenge")
                tryNextBase()
                return
            end

            -- 这个 base 能用：钉住（故障转移选中的镜像，下次直接用）
            local selected = originOf(url) or current_base
            if selected ~= pinned_base then
                logger.dbg("book.zlib mirror selected", selected)
            end
            pinned_base = selected

            local data, decode_err = decode(res.body)
            if not Request.ok(code) then
                cb(nil, apiError(data, T(_("HTTP %1"), code)))
                return
            end
            if not data then cb(nil, decode_err); return end
            if cache_key then Cache.set(cache_key, data, cache_ttl) end
            cb(data)
        end)
    end

    if cache_key then
        cache_job = Cache.getAsync(cache_key, function(hit)
            if cancelled then return end
            if hit ~= nil then
                logger.dbg("book.zlib cache hit", method, path)
                cb(hit)
            else
                tryNextBase()
            end
        end)
    else
        tryNextBase()
    end
    return result
end

--- 拉取默认热门书单。
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:listPopularAsync(cb)
    return self:_jsonAsync("GET", "/eapi/book/most-popular", {
        session = true,
        cache_ttl = 30 * 60,
    }, function(data, err)
        if data and tonumber(data.success) == 1 then cb(data) else cb(nil, err or apiError(data, _("加载失败"))) end
    end)
end

--- 搜索书籍；空关键词可按语言获取默认书城。
---@param query string|nil
---@param page number|nil
---@param limit number|nil
---@param cb fun(data: table|nil, err: string|nil)
---@param language string|nil Z-Library 搜索语言键
---@return { cancel: fun() }
function Client:searchAsync(query, page, limit, cb, language)
    local form = { message = query or "", page = page or 1, limit = limit or 12 }
    if type(language) == "string" and language ~= "" then
        form["languages[0]"] = language
    end
    return self:_jsonAsync("POST", "/eapi/book/search", {
        session = true,
        form = form,
        cache_ttl = (query or "") == "" and 30 * 60 or 5 * 60,
    }, function(data, err)
        if data and not data.error then cb(data) else cb(nil, err or apiError(data, _("搜索失败"))) end
    end)
end

--- 拉取单本书的原始详情。
---@param id string
---@param hash string
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:detailAsync(id, hash, cb)
    return self:_jsonAsync("GET", string.format("/eapi/book/%s/%s", id, hash), { session = true }, function(data, err)
        if data and tonumber(data.success) == 1 and type(data.book) == "table" then
            cb(data.book)
        else
            cb(nil, err or apiError(data, _("获取详情失败")))
        end
    end)
end

--- 用配置中的账号登录，并持久化返回的会话 Cookie 字段。
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:loginAsync(cb)
    if not self:hasCredentials() then
        cb(nil, _("请先在设置里填写 Z-Library 邮箱和密码"))
        return nil
    end
    local cfg = self.cfg
    return self:_jsonAsync("POST", "/eapi/user/login", {
        form = { email = cfg.email or "", password = cfg.password or "" },
    }, function(data, err)
        if not data or tonumber(data.success) ~= 1 then
            cb(nil, err or apiError(data, _("登录失败")))
            return
        end
        local user = data.user or data.response or {}
        local id = tostring(user.id or user.user_id or "")
        local key = tostring(user.remix_userkey or user.user_key or "")
        if id == "" or key == "" then cb(nil, _("登录失败：无效会话")); return end
        cfg.user_id, cfg.user_key = id, key
        require("utils.settings").saveSource("zlib", cfg)
        cb(true)
    end)
end

--- 获取带会话授权的 CDN 下载直链。
---@param id string
---@param hash string
---@param cb fun(link: string|nil, err: string|nil)
---@return { cancel: fun() }
function Client:downloadLinkAsync(id, hash, cb)
    return self:_jsonAsync("GET", string.format("/eapi/book/%s/%s/file", id, hash), {
        session = true,
    }, function(data, err)
        local file = data and data.file
        if not data or tonumber(data.success) ~= 1 or type(file) ~= "table" then
            cb(nil, err or apiError(data, _("获取下载链接失败")))
            return
        end
        if file.allowDownload == false then cb(nil, _("已达下载限额，请稍后再试")); return end
        if type(file.downloadLink) ~= "string" or file.downloadLink == "" then cb(nil, _("未返回下载链接")); return end
        cb(file.downloadLink)
    end)
end

--- 下载书籍到临时路径；会话失效时仅自动重新登录一次。
---@param id string
---@param hash string
---@param dest string
---@param on_progress fun(bytes: number)|nil
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Client:downloadAsync(id, hash, dest, on_progress, cb)
    local cancelled, job, retried, done = false, nil, false, false
    local result = {}
    --- 取消下载并清掉半截文件。已交付结果后调用是空操作：
    --- 对话框拆除、installAsync 收尾都会再调一次 cancel，那时删的是成品。
    function result.cancel()
        if done then return end
        cancelled = true
        if job and job.cancel then job.cancel() end
        pcall(os.remove, dest)
    end
    --- 在未取消时交付最终下载结果。
    ---@param ok boolean|nil
    ---@param err string|nil
    local function finish(ok, err)
        if cancelled then return end
        done = true
        cb(ok, err)
    end
    --- 下载已授权的 CDN 文件，并拒绝错误返回的 HTML 页面。
    ---@param link string
    local function fetchFile(link)
        if cancelled then return end
        pcall(os.remove, dest)
        job = Request.download({
            url = link,
            method = "GET",
            headers = self:headers(true),
            timeout = 180,
            -- CDN 直链常带 301/302：允许 Turbo 自动跟随
            allow_redirects = true,
            on_progress = on_progress,
        }, dest, function(ok, err, res)
            if not ok then pcall(os.remove, dest); finish(nil, err); return end
            local content_type = Request.header(res, "Content-Type")
            if type(content_type) == "string" and content_type:lower():find("text/html", 1, true) then
                pcall(os.remove, dest)
                finish(nil, _("已达下载限额或返回了网页"))
                return
            end
            finish(true)
        end)
    end
    --- 获取直链；发现会话失效时清空旧会话并重登一次。
    local function getLink()
        job = self:downloadLinkAsync(id, hash, function(link, err)
            if link then fetchFile(link); return end
            if not retried and type(err) == "string"
                and (err:find("Please login", 1, true) or err:find("请登录", 1, true)) then
                retried = true
                self.cfg.user_id, self.cfg.user_key = nil, nil
                require("utils.settings").saveSource("zlib", self.cfg)
                job = self:loginAsync(function(ok, login_err)
                    if ok then getLink() else finish(nil, login_err) end
                end)
                return
            end
            finish(nil, err)
        end)
    end
    if self:hasSession() then
        getLink()
    else
        job = self:loginAsync(function(ok, err)
            if ok then getLink() else finish(nil, err) end
        end)
    end
    return result
end

return Client
