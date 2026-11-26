--[[--
Z-Library eAPI 客户端（镜像竞速、反机器人检测与账号会话，仅异步）。

@module koplugin.book.store.zlib.client
--]]

local JSON = require("json")
local Request = require("http.request")
local Cache = require("http.cache")
local Text = require("utils.text")
local logger = require("utils.log")
local _ = require("gettext")
local T = require("ffi/util").template

-- 动态镜像目录（api.ankio.net 探测后返回可用列表）；拉回后长期缓存到 cfg.mirrors，
-- 仅在本地缓存为空或其中所有镜像均不可用时才再次请求。
local MIRRORS_API = "https://api.ankio.net/zlib/mirrors"

-- 仅在本地尚无缓存且 MIRRORS_API 不可达时兜底，不写入 cfg.mirrors。
local FALLBACK_MIRRORS = {
    "https://z-lib.gd",
    "https://zlib.bz",
    "https://z-lib.by",
    "https://z-lib.gl",
    "https://z-library.ec",
}

local USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

local MAX_REDIRECT_HOPS = 5
local RACE_WIDTH = 5 -- 首次（尚无可用镜像）并发竞速的镜像数
local SERIAL_ATTEMPTS = 3 -- 已选定镜像 / 消耗下载额度的请求，依次试的镜像数

local DEAD_TTL = 7 * 24 * 3600 -- 竞速中失败的镜像在这段时间内不再尝试

-- 钉住的镜像 origin（重定向跨主机或故障转移成功时更新，本次会话有效）
local pinned_base

local Client = {}
Client.__index = Client
Client.MIRRORS_API = MIRRORS_API

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

-- ---------------------------------------------------------------------------
-- 镜像选择与故障转移
-- ---------------------------------------------------------------------------

--- 归一化单个镜像地址（去空白、去尾部斜杠、补 https 前缀）。
---@param u any
---@return string|nil
local function normalizeBase(u)
    if type(u) ~= "string" then return nil end
    u = u:gsub("%s+", ""):gsub("/+$", "")
    if u == "" then return nil end
    if not u:match("^[hH][tT][tT][pP][sS]?://") then u = "https://" .. u end
    return u
end

--- 当前有效的钉住镜像：优先本次会话的 pinned_base，其次未拉黑的持久化 cfg.last_mirror。
---@param cfg table|nil
---@return string|nil
local function activePinned(cfg)
    if pinned_base then return pinned_base end
    local last = normalizeBase(cfg and cfg.last_mirror)
    if not last then return nil end
    local died = cfg and cfg.dead_bases and cfg.dead_bases[last]
    if died and os.time() - died < DEAD_TTL then return nil end
    return last
end

--- 本地可用候选列表：用户配置 > 钉住 > 本地长期缓存的 mirrors；去重并跳过未过期的 dead_bases。
--- 返回空表意味着本地尚无缓存或所有缓存镜像均已拉黑，应向 MIRRORS_API 拉取新列表。
---@param cfg table|nil
---@return string[]
local function localCandidates(cfg)
    local out, seen = {}, {}
    local dead = cfg and cfg.dead_bases or {}
    local user_base = normalizeBase(cfg and cfg.base_url)
    local pinned = activePinned(cfg)
    local now = os.time()
    local function add(u)
        u = normalizeBase(u)
        if not u then return end
        local died = dead[u]
        local skip = died and now - died < DEAD_TTL and u ~= user_base and u ~= pinned
        if not seen[u] and not skip then
            seen[u] = true
            out[#out + 1] = u
        end
    end
    add(user_base)
    add(pinned)
    for _idx, mirror in ipairs(cfg and type(cfg.mirrors) == "table" and cfg.mirrors or {}) do
        add(mirror)
    end
    return out
end

--- 从候选列表里挑出本轮请求尚未尝试过且去重后的镜像。
---@param list string[]
---@param tried table<string, boolean>
---@return string[]
local function untriedCandidates(list, tried)
    local out, seen = {}, {}
    for _idx, raw in ipairs(list) do
        local u = normalizeBase(raw)
        if u and not seen[u] and not tried[u] then
            seen[u] = true
            out[#out + 1] = u
        end
    end
    return out
end

--- 解析 MIRRORS_API 返回的 JSON，提取归一化后的镜像 origin 列表。
---@param body string|nil
---@return string[]|nil
local function parseMirrorList(body)
    if type(body) ~= "string" or body == "" then return nil end
    local ok, payload = pcall(JSON.decode, body)
    if not ok or type(payload) ~= "table" then return nil end
    local raw = type(payload.data) == "table" and payload.data.mirrors or payload.mirrors
    if type(raw) ~= "table" then return nil end
    local out, seen = {}, {}
    for _idx, item in ipairs(raw) do
        local u = normalizeBase(item)
        if u and not seen[u] then
            seen[u] = true
            out[#out + 1] = u
        end
    end
    return #out > 0 and out or nil
end

--- 从服务器拉取最新探测可用的 Z-Library 镜像列表。
---@param cb fun(mirrors: string[]|nil, err: string|nil)
---@return { cancel: fun() }
local function fetchMirrorsAsync(cb)
    return Request.request({
        url = Client.MIRRORS_API,
        method = "GET",
        headers = {
            ["Accept"] = "application/json",
            ["User-Agent"] = USER_AGENT,
        },
        allow_redirects = true,
        timeout = require("http.timeout").net(1),
    }, function(res, err)
        local code = res and tonumber(res.code) or nil
        if not code or not Request.ok(code) then
            cb(nil, err or (code and T(_("HTTP %1"), code)) or _("网络请求失败"))
            return
        end
        local list = parseMirrorList(res.body)
        if not list then
            cb(nil, _("无效响应格式"))
            return
        end
        cb(list)
    end)
end

-- HTML <title> 里的浏览器验证/反机器人拦截文案（仅 HTML 正文有效，杜绝 JSON 书名/简介误报）
local CHALLENGE_TITLES = {
    "just a moment",
    "checking your browser",
    "verifying your browser",
}

local CF_CHALLENGE_MARKERS = {
    "/cdn-cgi/mitigation/",
    "__cf_chl",
}

--- 判断响应 Content-Type 是否可能是 HTML 拦截页。
--- 显式非 HTML（特别是 eAPI 的 application/json）不扫描正文，避免书名或简介含关键词触发误判；
--- 缺失或无法解析的 Content-Type 按 HTML 处理，防止裸拦截页漏网。
---@param res table
---@return boolean
local function isHTMLBody(res)
    local ct = Request.header(res, "Content-Type")
    if type(ct) ~= "string" then return true end
    local media = ct:match("^%s*([^;%s]+)")
    if not media or media == "" then return true end
    media = media:lower()
    return media == "text/html" or media == "application/xhtml+xml"
end

--- 判断响应 Set-Cookie 是否下发了 __diamwall。
--- 注意：__diamwall 是 DiamWall 的放行凭证，正常 200 响应也会带，不可单靠它判拦截；
--- 只有整条重定向链陷入死循环或超跳数时，它才证明是被 DiamWall 反机器人拦截。
---@param res table
---@return boolean
local function hasDiamWallCookie(res)
    for _idx, line in ipairs(Request.headerAll(res, "Set-Cookie")) do
        if line:lower():find("__diamwall", 1, true) then return true end
    end
    return false
end

--- 判断是否为 DiamWall 反机器人拦截：
--- 1) 非标准状态码 513（Verifying your browser）/ 517（Access Denied）；
--- 2) HTML 响应体的 <title> 含 diamwall（锚定 title，不做裸子串匹配）。
---@param code number
---@param res table
---@return boolean
local function isBotProtection(code, res)
    if code == 513 or code == 517 then return true end
    if not isHTMLBody(res) then return false end
    local body = res.body
    if type(body) ~= "string" or body == "" then return false end
    local head = body:sub(1, 8192):lower()
    for title in head:gmatch("<title[^>]*>([^<]*)</title>") do
        if title:find("diamwall", 1, true) then return true end
    end
    return false
end

--- 判断响应是否为浏览器 JS 挑战页（Z-Library c_token 或 Cloudflare WAF HTML 拦截页）。
--- 仅在 HTML 正文中检测；application/json 响应直接跳过。
---@param res table
---@return boolean
local function isChallengePage(res)
    if not isHTMLBody(res) then return false end
    local body = res.body
    if type(body) ~= "string" or body == "" then return false end
    if #body < 20000 then
        for hex in body:gmatch("'([%x]+)','c_token=") do
            if #hex == 40 then return true end
        end
    end
    local head = body:sub(1, 8192)
    local lower = head:lower()
    for title in lower:gmatch("<title[^>]*>([^<]*)</title>") do
        for _idx, phrase in ipairs(CHALLENGE_TITLES) do
            if title:find(phrase, 1, true) then return true end
        end
    end
    if lower:find("<html", 1, true) or lower:find("<!doctype", 1, true) then
        for _idx, marker in ipairs(CF_CHALLENGE_MARKERS) do
            if head:find(marker, 1, true) then return true end
        end
    end
    return false
end

--- 判断解码后的 JSON 是否为 Z-Library API 业务信封，避免把代理/WAF/停放域名的非预期响应钉死为可用镜像。
---@param data table|nil
---@param path string
---@return boolean
local function isApiEnvelope(data, path)
    if type(data) ~= "table" then return false end
    if path:sub(1, 6) == "/eapi/" then
        if path == "/eapi/info/domains" then
            return tonumber(data.success) == 1 and type(data.domains) == "table"
        end
        return data.success ~= nil or data.error ~= nil or type(data.books) == "table"
    end
    return type(data.response) == "table" or type(data.errors) == "table" or data.error ~= nil
end

--- 传输层错误分类（Turbo res.error.code / message）
---@param res table|nil
---@return string
local function classifyTransportError(res, err)
    local err_obj = res and res.error
    local code, message
    if type(err_obj) == "table" then
        code = err_obj.code
        message = err_obj.message
    end
    local msg = tostring(message or err or "")
    if code == -5 or code == -6 then -- CONNECT_TIMEOUT / REQUEST_TIMEOUT
        return _("连接超时，请检查网络")
    end
    local lower = msg:lower()
    if lower:find("resolve", 1, true) or lower:find("not known", 1, true) then
        return _("找不到服务器地址，镜像可能已失效")
    end
    return msg ~= "" and msg or _("网络请求失败")
end

local REDIRECT_CODES = { [301] = true, [302] = true, [303] = true, [307] = true, [308] = true }

-- ---------------------------------------------------------------------------
-- 客户端
-- ---------------------------------------------------------------------------

--- 创建客户端；配置表由调用方拥有，登录成功后会原地写入会话字段。
---@param cfg table settings/zlib.lua
---@return table
function Client.new(cfg)
    return setmetatable({ cfg = cfg }, Client)
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
---@param with_session boolean|nil 是否附带 remix 会话凭据
---@param is_eapi boolean|nil 是否为 /eapi/* 请求（补 source: android 与 remix-* 请求头）
---@return table<string, string>
function Client:headers(with_session, is_eapi)
    local headers = {
        ["Accept"] = is_eapi and "application/json" or "application/json, text/javascript, */*; q=0.01",
        ["User-Agent"] = USER_AGENT,
    }
    if is_eapi then
        -- /eapi/book/search 缺少 source 头会直接返回 400 Access denied
        headers["source"] = "android"
    end
    if with_session and self:hasSession() then
        headers["Cookie"] = string.format("remix_userid=%s; remix_userkey=%s", self.cfg.user_id, self.cfg.user_key)
        if is_eapi then
            headers["remix-userid"] = tostring(self.cfg.user_id)
            headers["remix-userkey"] = tostring(self.cfg.user_key)
        end
    end
    return headers
end

--- 解码 eAPI JSON 响应。
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
--- 竞速有镜像胜出（说明网络通）时，落盘保存胜出镜像、拉黑同场失败镜像并清理过期黑名单条目。
---@param lanes table[]
function Client:_blacklistFailed(lanes)
    local dead, now, changed = {}, os.time(), false
    for base, at in pairs(self.cfg.dead_bases or {}) do
        if now - at < DEAD_TTL then
            dead[base] = at
        else
            changed = true
        end
    end
    for _idx, lane in ipairs(lanes) do
        if lane.failed and lane.base ~= pinned_base then
            dead[lane.base] = now
            changed = true
        end
    end
    if pinned_base then
        if dead[pinned_base] then
            dead[pinned_base] = nil
            changed = true
        end
        if self.cfg.last_mirror ~= pinned_base then
            self.cfg.last_mirror = pinned_base
            changed = true
        end
    end
    if not changed then return end
    self.cfg.dead_bases = next(dead) and dead or nil
    require("utils.settings").saveSource("zlib", self.cfg)
end

---@param method string
---@param path string eAPI 路径（以 / 开头）
---@param opts table session、form、cache_ttl、timeout
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:_jsonAsync(method, path, opts, cb)
    local cancelled, settled, refreshed, filling = false, false, false, false
    local lanes, tried = {}, {}
    local cache_job, refresh_job
    local result = {}
    local function stopLanes()
        for _idx, lane in ipairs(lanes) do
            if lane.job then lane.job.cancel() end
        end
    end
    --- 取消在途请求：置位取消标记，并中断缓存读取、镜像刷新与所有镜像请求。
    function result.cancel()
        cancelled = true
        if cache_job then cache_job.cancel() end
        if refresh_job then refresh_job.cancel() end
        stopLanes()
    end

    local body = opts.form and Text.formEncode(opts.form) or nil
    local is_eapi = path:sub(1, 6) == "/eapi/"
    local cache_ttl = opts.cache_ttl or 0
    local cache_key = cache_ttl > 0 and Cache.key(method, "zlib://api" .. path, opts.form) or nil
    local deliver
    local headers = self:headers(opts.session, is_eapi)
    -- 会话 Cookie 交给会话罐：手动跟随的每一跳都会收 Set-Cookie，下一跳 / 下次请求自动带上
    local jar = headers.Cookie and require("http.cookie_jar").session("zlib", headers.Cookie)
    headers.Cookie = nil
    if body then
        headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
        if not is_eapi then headers["X-Requested-With"] = "XMLHttpRequest" end
    end
    local last_err = _("网络请求失败")
    local bases, next_base, pending, local_exhausted = {}, 0, 0, true

    local issue, launch, fillWindow, startWave, refreshMirrors
    --- 第一个给出确定答案的镜像胜出，其余请求取消；只回调一次。
    local function finish(data, err)
        if settled or cancelled then return end
        settled = true
        if refresh_job then refresh_job.cancel() end
        stopLanes()
        if data then self:_blacklistFailed(lanes) end
        deliver(data, err)
    end

    local function onWaveExhausted()
        if settled or cancelled then return end
        if local_exhausted and not refreshed then
            return refreshMirrors()
        end
        logger.warn("book.zlib request failed", method, path, "attempts", #lanes, last_err)
        finish(nil, last_err)
    end

    fillWindow = function()
        if filling then return end
        filling = true
        local limit = (not opts.serial and not activePinned(self.cfg)) and RACE_WIDTH or 1
        while not settled and not cancelled and pending < limit and next_base < #bases do
            pending = pending + 1
            launch()
        end
        filling = false
        if not settled and not cancelled and pending == 0 then
            onWaveExhausted()
        end
    end

    startWave = function(pool, exhausted)
        local cap = opts.serial and math.min(SERIAL_ATTEMPTS, #pool) or #pool
        bases = {}
        for i = 1, cap do bases[i] = pool[i] end
        next_base = 0
        local_exhausted = exhausted and (#bases == #pool)
        if #bases == 0 then
            onWaveExhausted()
            return
        end
        fillWindow()
    end

    refreshMirrors = function()
        refreshed = true
        logger.info("book.zlib mirrors refresh", Client.MIRRORS_API)
        refresh_job = fetchMirrorsAsync(function(mirrors, err)
            refresh_job = nil
            if settled or cancelled then return end
            if mirrors and #mirrors > 0 then
                self.cfg.mirrors = mirrors
                self.cfg.dead_bases = nil
                self.cfg.last_mirror = nil
                lanes = {}
                require("utils.settings").saveSource("zlib", self.cfg)
                local fresh = untriedCandidates(mirrors, tried)
                if #fresh > 0 then return startWave(fresh, true) end
            else
                logger.warn("book.zlib mirrors refresh failed", err)
                -- 目录接口不可达时：本地缓存若全被拉黑则清黑名单重试一次；首次无缓存则用极简兜底
                local fallback
                if type(self.cfg.mirrors) == "table" and #self.cfg.mirrors > 0 then
                    if next(self.cfg.dead_bases or {}) then
                        self.cfg.dead_bases = nil
                        fallback = untriedCandidates(self.cfg.mirrors, tried)
                    end
                else
                    fallback = untriedCandidates(FALLBACK_MIRRORS, tried)
                end
                if fallback and #fallback > 0 then return startWave(fallback, true) end
            end
            logger.warn("book.zlib request failed", method, path, "attempts", #lanes, last_err)
            finish(nil, last_err)
        end)
    end

    --- 这条请求的镜像不可用：清掉失效钉住、记下错误；补发下一个候选，全部耗尽则刷新镜像列表或回调最终错误。
    ---@param lane table
    ---@param err string
    local function failover(lane, err, ...)
        if settled or cancelled then return end
        local pinned = activePinned(self.cfg)
        if pinned and (lane.base == pinned or lane.current_origin == pinned) then
            pinned_base = nil
            if self.cfg.last_mirror == lane.base or self.cfg.last_mirror == lane.current_origin then
                self.cfg.last_mirror = nil
            end
        end
        last_err = err
        lane.failed = true
        pending = pending - 1
        logger.dbg("book.zlib failover", method, path, lane.base, ...)
        if not filling then fillWindow() end
    end

    launch = function()
        next_base = next_base + 1
        local base = bases[next_base]
        tried[base] = true
        local lane = { base = base, index = #lanes + 1 }
        lanes[#lanes + 1] = lane
        local url = lane.base .. path
        logger.dbg("book.zlib mirror attempt", method, path,
            "attempt", lane.index, "of", #bases, lane.base,
            "timeout", opts.timeout or require("http.timeout").net(1))
        issue(lane, url, method, body, headers, jar, { [url] = true }, 0)
    end

    --- 重定向前按需剥离请求体头（转 GET）或认证头（HTTPS 降级到 HTTP）。
    ---@param src table<string, string>
    ---@param drop_body boolean
    ---@param drop_auth boolean
    ---@return table<string, string>
    local function filterHeaders(src, drop_body, drop_auth)
        if not drop_body and not drop_auth then return src end
        local kept = {}
        for k, v in pairs(src) do
            local lk = k:lower()
            local skip = (drop_body and (lk == "content-type" or lk == "content-length"))
                or (drop_auth and (lk == "cookie" or lk == "remix-userid" or lk == "remix-userkey"))
            if not skip then kept[k] = v end
        end
        return kept
    end

    --- 发出单次请求或继续跟随重定向。
    ---@param lane table
    ---@param url string
    ---@param m string
    ---@param req_body string|nil
    ---@param req_headers table<string, string>
    ---@param req_jar table|nil
    ---@param seen table<string, boolean> 已请求过的 URL（重定向循环检测）
    ---@param hops number 已跟随的跳数
    issue = function(lane, url, m, req_body, req_headers, req_jar, seen, hops)
        local cur_origin, cur_scheme = originOf(url)
        lane.current_origin = cur_origin
        lane.job = Request.request({
            url = url,
            method = m,
            body = req_body,
            headers = req_headers,
            jar = req_jar,
            timeout = opts.timeout or require("http.timeout").net(1),
        }, function(res, err)
            if cancelled or settled then return end
            local code = res and tonumber(res.code) or nil

            -- 传输层失败：这条镜像作废
            if not code then
                local transport_err = classifyTransportError(res, err)
                return failover(lane, transport_err, "transport", transport_err)
            end
            ---@cast res table

            if hasDiamWallCookie(res) then
                lane.saw_diamwall = true
            end

            -- DiamWall 反机器人拦截（513/517 或 HTML <title> 含 diamwall），须早于 5xx 与 30x 判定
            if isBotProtection(code, res) then
                return failover(lane, _("服务器拒绝自动访问，正在尝试其它镜像"), "diamwall_blocked", code)
            end

            -- 浏览器 JS/WAF 挑战页（常带 503，须早于 5xx 判定；application/json 不扫描正文）
            if isChallengePage(res) then
                return failover(lane, _("服务器拒绝自动访问，正在尝试其它镜像"), "bot_challenge", code)
            end

            -- 30x：手动跟随（Turbo 默认不跟随）
            if REDIRECT_CODES[code] then
                -- 30x 的 Location 允许是相对地址（RFC 9110）
                local target = Text.absoluteUrl(url, Request.header(res, "location"))
                if not target then
                    return failover(lane, T(_("HTTP %1"), code), "invalid_redirect", code)
                end
                if seen[target] or hops + 1 > MAX_REDIRECT_HOPS then
                    if lane.saw_diamwall then
                        return failover(lane, _("服务器拒绝自动访问，正在尝试其它镜像"), "diamwall_blocked", code)
                    end
                    return failover(lane, _("重定向过多"), "redirect_loop", target)
                end
                seen[target] = true
                -- 跨主机 = 镜像迁移；成功后按实际请求 URL 钉住新 origin。
                -- Location 的路径和查询是服务端给出的请求目标，不能丢掉。
                local new_origin, new_scheme = originOf(target)
                local is_mirror_move = new_origin and new_origin ~= cur_origin
                local downgraded = cur_scheme == "https" and new_scheme == "http"
                local to_get = not is_mirror_move and code ~= 307 and code ~= 308 and m ~= "GET"
                logger.dbg("book.zlib redirect", code, cur_origin, new_origin or target)
                local next_body = not to_get and req_body or nil
                local next_jar = not downgraded and req_jar or nil
                issue(
                    lane,
                    target,
                    to_get and "GET" or m,
                    next_body,
                    filterHeaders(req_headers, to_get, downgraded),
                    next_jar,
                    seen,
                    hops + 1
                )
                return
            end

            -- 5xx 是镜像自己病了：换下一个
            if code >= 500 then
                return failover(lane, T(_("HTTP %1"), code), "status", code)
            end

            local data, decode_err = decode(res.body)
            local valid_envelope = isApiEnvelope(data, path)
            if not Request.ok(code) then
                -- 非 2xx 只有携带合法 API 错误信封（如额度用尽、凭据失效）才是服务端业务拒答；
                -- 其余（403 WAF HTML / 404 失效镜像等）一律故障转移，绝不钉死坏镜像。
                if not valid_envelope then
                    return failover(lane, T(_("HTTP %1"), code), "status", code)
                end
                local selected = cur_origin or lane.base
                if selected ~= pinned_base then
                    logger.info("book.zlib mirror selected", selected)
                end
                pinned_base = selected
                local api_err = apiError(data, T(_("HTTP %1"), code))
                logger.dbg("book.zlib request rejected", method, path,
                    "attempt", lane.index, "of", #bases, selected,
                    "status", code, api_err)
                finish(nil, api_err)
                return
            end

            -- 2xx 但返回 HTML / 空正文 / 非 Z-Library JSON：镜像异常，换下一个且不钉住
            if not data or not valid_envelope then
                return failover(lane, decode_err or _("无效响应格式"), "non_json", code)
            end

            -- 确认镜像正常吐出 Z-Library JSON 后才钉住（胜出的镜像，下次排在最前）
            local selected = cur_origin or lane.base
            if selected ~= pinned_base then
                logger.info("book.zlib mirror selected", selected)
            end
            pinned_base = selected
            logger.dbg("book.zlib request success", method, path,
                "attempt", lane.index, "of", #bases, selected, "status", code)
            finish(data)
        end)
    end

    cache_job = Cache.fetch(cache_key, cache_ttl, function(done)
        deliver = done
        startWave(localCandidates(self.cfg), true)
    end, cb)
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
---@param filters { order?: string, extension?: string }|nil 排序（popular / date）与文件格式
---@return { cancel: fun() }
function Client:searchAsync(query, page, limit, cb, language, filters)
    local form = { message = query or "", page = page or 1, limit = limit or 12 }
    if type(language) == "string" and language ~= "" then
        form["languages[0]"] = language
    end
    if filters and filters.order then form.order = filters.order end
    if filters and filters.extension then form["extensions[0]"] = filters.extension end
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

--- 登录响应里的会话：rpc.php 放在 response（user_id / user_key），旧 eAPI 放在 user（id / remix_userkey）。
---@param data table
---@return string|nil id, string|nil key
local function sessionOf(data)
    local user = type(data.response) == "table" and data.response or type(data.user) == "table" and data.user or {}
    local id = tostring(user.id or user.user_id or "")
    local key = tostring(user.remix_userkey or user.remix_user_key or user.user_key or "")
    if id == "" or key == "" then return nil end
    return id, key
end

--- 登录失败时服务器给的文案（rpc.php 在 response.message 或 errors[]，其余同 apiError）。
---@param data table|nil
---@return string
local function loginError(data)
    local resp = type(data) == "table" and type(data.response) == "table" and data.response.message
    if type(resp) == "string" and resp ~= "" then return resp end
    local first = type(data) == "table" and type(data.errors) == "table" and data.errors[1]
    if type(first) == "table" then first = first.message end
    if type(first) == "string" and first ~= "" then return first end
    return apiError(data, _("登录失败"))
end

--- 用配置中的账号登录，并持久化返回的会话 Cookie 字段。
--- 先走网站自己用的 /rpc.php（/eapi/user/login 时好时坏，会对正确密码报 Authorization failed），
--- 被拒再试 /eapi/user/login；登录只走一个镜像（并发登录会触发 Too many logins）。
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:loginAsync(cb)
    if not self:hasCredentials() then
        cb(nil, _("请先在设置里填写 Z-Library 邮箱和密码"))
        return nil
    end
    local cfg = self.cfg
    local base = activePinned(cfg) or cfg.base_url or (type(cfg.mirrors) == "table" and cfg.mirrors[1]) or FALLBACK_MIRRORS[1]
    local attempts = {
        { path = "/rpc.php", form = {
            isModal = "true", email = cfg.email, password = cfg.password, site_mode = "books",
            action = "login", gg_json_mode = "1", redirectUrl = base .. "/",
        } },
        { path = "/eapi/user/login", form = { email = cfg.email, password = cfg.password } },
    }
    local result, first_err = {}, nil
    local function try(i)
        local at = attempts[i]
        result.job = self:_jsonAsync("POST", at.path, { form = at.form, serial = true }, function(data, err)
            local id, key
            if data then id, key = sessionOf(data) end
            logger.info("book.zlib login", at.path, pinned_base or base, id and "ok" or (err or loginError(data)))
            if id then
                cfg.user_id, cfg.user_key = id, key
                require("utils.settings").saveSource("zlib", cfg)
                cb(true)
                return
            end
            local msg = err or loginError(data)
            first_err = first_err or msg
            if i < #attempts and not msg:find("Too many logins", 1, true) then return try(i + 1) end
            cb(nil, first_err)
        end)
    end
    try(1)
    return { cancel = function() if result.job then result.job.cancel() end end }
end

--- 获取带会话授权的 CDN 下载直链。
---@param id string
---@param hash string
---@param cb fun(link: string|nil, err: string|nil)
---@return { cancel: fun() }
function Client:downloadLinkAsync(id, hash, cb)
    return self:_jsonAsync("GET", string.format("/eapi/book/%s/%s/file", id, hash), {
        session = true,
        serial = true, -- 取链接会消耗下载额度，不并发
    }, function(data, err)
        local file = data and type(data.file) == "table" and data.file or nil
        if not data or tonumber(data.success) ~= 1 then
            cb(nil, err or apiError(data, _("获取下载链接失败")))
            return
        end
        if file and file.allowDownload == false then cb(nil, _("已达下载限额，请稍后再试")); return end
        local raw_link = (file and file.downloadLink) or data.downloadLink or data.url or data.link
        if type(raw_link) ~= "string" or raw_link == "" then cb(nil, _("未返回下载链接")); return end
        local base = activePinned(self.cfg) or self.cfg.base_url
            or (type(self.cfg.mirrors) == "table" and self.cfg.mirrors[1])
            or FALLBACK_MIRRORS[1]
        cb(Text.absoluteUrl(base .. "/", raw_link) or raw_link)
    end)
end

--- 判断错误是否为会话失效/被撤销（Z-Library eAPI 返回 Please login 或 Invalid credentials）。
---@param err any
---@return boolean
local function isSessionExpiredError(err)
    if type(err) ~= "string" then return false end
    local lower = err:lower()
    return lower:find("please login", 1, true) ~= nil
        or lower:find("invalid credentials", 1, true) ~= nil
        or err:find("请登录", 1, true) ~= nil
end

--- 下载书籍到 dest；会话失效时仅自动重新登录一次。
--- 半截文件由 Request.download（dest.part）自己清理，dest 归调用方。
---@param id string
---@param hash string
---@param dest string
---@param on_progress fun(bytes: number)|nil
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Client:downloadAsync(id, hash, dest, on_progress, cb)
    local cancelled, job, retried = false, nil, false
    local result = {}
    function result.cancel()
        cancelled = true
        if job then job.cancel() end
    end
    --- 在未取消时交付最终下载结果。
    ---@param ok boolean|nil
    ---@param err string|nil
    local function finish(ok, err)
        if cancelled then return end
        cb(ok, err)
    end
    --- 下载已授权的 CDN 文件，并拒绝错误返回的 HTML 页面。
    ---@param link string
    local function fetchFile(link)
        if cancelled then return end
        -- 只有发往当前 HTTPS 镜像同源的下载才带账号 Cookie；签名 CDN 链接不需要，避免泄露会话凭据
        local mirror = activePinned(self.cfg) or self.cfg.base_url
        local mirror_origin = mirror and originOf(mirror) or nil
        local link_origin, link_scheme = originOf(link)
        local send_session = link_scheme == "https" and mirror_origin ~= nil and link_origin == mirror_origin
        local dl_headers = self:headers(send_session, false)
        if mirror_origin then dl_headers["Referer"] = mirror_origin .. "/" end
        job = Request.download({
            url = link,
            method = "GET",
            headers = dl_headers,
            timeout = require("http.timeout").net(6),
            -- CDN 直链常带 301/302：允许 Turbo 自动跟随
            allow_redirects = true,
            on_progress = on_progress,
        }, dest, function(ok, err, res)
            if not ok then finish(nil, err); return end
            local content_type = Request.header(res, "Content-Type")
            if type(content_type) == "string" and content_type:lower():find("text/html", 1, true) then
                os.remove(dest)
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
            if not retried and isSessionExpiredError(err) then
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
