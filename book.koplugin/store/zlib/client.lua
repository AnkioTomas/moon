--[[--
Z-Library eAPI 客户端（HTTP Basic 门禁 + Z-Library 账号会话，仅异步）。

@module koplugin.book.store.zlib.client
--]]

local JSON = require("json")
local Request = require("http.request")
local Cache = require("http.cache")
local Text = require("utils.text")
local logger = require("utils.log")
local _ = require("gettext")
local T = require("ffi/util").template

-- 官方种子镜像（不带尾斜杠）。前排入口来自上游域名清单，并经
-- eAPI /info/ok 实测可用；旧入口保留作地区性回退；末尾补自 zlibrary.koplugin
-- 的 domains.json 与 Android 种子（未逐个实测）。
local SEED_URLS = {
    "https://iread.ink",
    "https://zh.per101.ru",
    "https://zlib.bz",
    "https://lexlib.tw",
    "https://librella.fi",
    "https://lexlib.fi",
    "https://bookabooki.tw",
    "https://bookabooki.fi",
    "https://librella.tw",
    "https://fuckfbi.ru",
    "https://zh.z-lib.gd",
    "https://z-library.la",
    "https://zh.z-library.sk",
    "https://z-library.sk",
    "https://thai-books.sk",
    "https://frenchbooks.sk",
    "https://portuguese-books.sk",
    "https://urdu-books.sk",
    "https://spanish-books.sk",
    "https://italian-books.sk",
    "https://czechbooks.sk",
    "https://z-lib.sk",
    "https://german-books.sk",
    "https://1lib.sk",
    "https://z-lib.gd",
    "https://z-lib.gl",
    "https://z-lib.bz",
    "https://z-lib.do",
    "https://z-lib.fo",
    "https://z-library.hn",
    "https://japanese-books.sk",
    "https://1lib.su",
    "https://zlib.by",
    "https://101ml.su",
    "https://zlib.re",
    "https://library-oceania.sk",
    "https://library-latin.sk",
    "https://library-asia.sk",
    "https://lib-africa.sk"
}

local USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/96.0.4664.110 Safari/537.36"

local MAX_REDIRECT_HOPS = 5
local RACE_WIDTH = 5 -- 首次（尚无可用镜像）并发竞速的镜像数
local SERIAL_ATTEMPTS = 3 -- 已选定镜像 / 消耗下载额度的请求，依次试的镜像数

local DEAD_TTL = 7 * 24 * 3600 -- 竞速中失败的镜像在这段时间内不再尝试

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

-- 带 HTTP Basic 门禁的镜像：凭据只发给同 origin 的请求，不随跨主机重定向或其它镜像泄露
local MIRROR_AUTH = {
    ["https://iread.ink"] = "iread:DGvG2h3JMOvEoS",
}

--- 给指向门禁镜像的请求补 Authorization；其它地址原样返回。
---@param url string
---@param headers table<string, string>
---@return table<string, string>
local function withMirrorAuth(url, headers)
    local cred = MIRROR_AUTH[originOf(url)]
    if not cred then return headers end
    local out = { Authorization = "Basic " .. Text.base64Encode(cred) }
    for k, v in pairs(headers) do out[k] = v end
    return out
end

-- ---------------------------------------------------------------------------
-- 镜像选择与故障转移
-- ---------------------------------------------------------------------------

--- 候选 base 列表：用户配置 > 钉住 > 种子；去重，最多 cap 个
---@param cfg table|nil
---@param cap number
---@return string[]
local function baseCandidates(cfg, cap)
    local out, seen = {}, {}
    local dead = cfg and cfg.dead_bases or {}
    local now = os.time()
    --- 归一化一个候选地址（去空白、去尾部斜杠、补 https 前缀）后按去重追加。
    ---@param u string|nil 候选地址，非字符串或归一化后为空则跳过
    local function add(u)
        if type(u) ~= "string" then return end
        u = u:gsub("%s+", ""):gsub("/+$", "")
        if u == "" then return end
        if not u:match("^[hH][tT][tT][pP][sS]?://") then u = "https://" .. u end
        local died = dead[u]
        local skip = died and now - died < DEAD_TTL and u ~= (cfg and cfg.base_url) and u ~= pinned_base
        if not seen[u] and not skip then
            seen[u] = true
            out[#out + 1] = u
        end
    end
    add(cfg and cfg.base_url)
    add(pinned_base)
    for _idx, seed in ipairs(SEED_URLS) do add(seed) end
    if #out == 0 and next(dead) then
        cfg.dead_bases = nil
        return baseCandidates(cfg, cap)
    end
    local capped = {}
    for i = 1, math.min(cap, #out) do capped[i] = out[i] end
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
---@return boolean
local function looksLikeChallenge(body)
    if type(body) ~= "string" or body == "" then return false end
    local head = body:sub(1, 4096)
    if not head:find("<", 1, true) then return false end
    for _idx, marker in ipairs(CHALLENGE_MARKERS) do
        if head:find(marker, 1, true) then return true end
    end
    return false
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
--- 竞速有镜像胜出（说明网络通）时，把同场失败的镜像落盘拉黑；胜出的镜像移出黑名单。
---@param lanes table[]
function Client:_blacklistFailed(lanes)
    local dead = self.cfg.dead_bases or {}
    local now, changed = os.time(), false
    for _idx, lane in ipairs(lanes) do
        if lane.failed and lane.base ~= pinned_base then
            dead[lane.base] = now
            changed = true
        end
    end
    if pinned_base and dead[pinned_base] then
        dead[pinned_base] = nil
        changed = true
    end
    if not changed then return end
    self.cfg.dead_bases = dead
    require("utils.settings").saveSource("zlib", self.cfg)
end

---@param method string
---@param path string eAPI 路径（以 / 开头）
---@param opts table session、form、cache_ttl、timeout
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:_jsonAsync(method, path, opts, cb)
    local race = not opts.serial and not pinned_base -- 只在还没选定镜像时竞速，之后固定用胜出的那个
    local bases = baseCandidates(self.cfg, race and RACE_WIDTH or SERIAL_ATTEMPTS)
    local cancelled, settled = false, false
    local lanes = {}
    local cache_job
    local result = {}
    local function stopLanes()
        for _idx, lane in ipairs(lanes) do
            if lane.job then lane.job.cancel() end
        end
    end
    --- 取消在途请求：置位取消标记，并中断缓存读取与所有镜像请求。
    function result.cancel()
        cancelled = true
        if cache_job then cache_job.cancel() end
        stopLanes()
    end

    local body = opts.form and Text.formEncode(opts.form) or nil
    local cache_ttl = opts.cache_ttl or 0
    local cache_key = cache_ttl > 0 and Cache.key(method, "zlib://api" .. path, opts.form) or nil
    local deliver
    local headers = self:headers(opts.session)
    if body then
        headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
        headers["X-Requested-With"] = "XMLHttpRequest"
    end
    local last_err = _("网络请求失败")
    local next_base = 0
    local pending = 0

    local issue
    local launch
    --- 第一个给出确定答案的镜像胜出，其余请求取消；只回调一次。
    local function finish(data, err)
        if settled or cancelled then return end
        settled = true
        stopLanes()
        if race and data then self:_blacklistFailed(lanes) end
        deliver(data, err)
    end

    --- 这条请求的镜像不可用：记下错误；没有在途请求了就换下一个候选，候选耗尽则回调最终错误。
    ---@param lane table
    ---@param err string
    local function failover(lane, err, ...)
        if settled or cancelled then return end
        last_err = err
        lane.failed = true
        pending = pending - 1
        logger.dbg("book.zlib failover", method, path, lane.base, ...)
        if pending > 0 then return end
        if next_base < #bases then
            pending = 1
            launch()
        else
            logger.warn("book.zlib request failed", method, path, "attempts", #bases, last_err)
            finish(nil, last_err)
        end
    end

    launch = function()
        next_base = next_base + 1
        local lane = { base = bases[next_base], index = next_base }
        lanes[#lanes + 1] = lane
        local url = lane.base .. path
        logger.dbg("book.zlib mirror attempt", method, path,
            "attempt", lane.index, "of", #bases, lane.base,
            "timeout", opts.timeout or require("http.timeout").net(1))
        issue(lane, url, method, body, headers, { [url] = true }, 0)
    end

    --- 发出单次请求或继续跟随重定向。
    ---@param lane table
    ---@param url string
    ---@param m string
    ---@param req_body string|nil
    ---@param headers table<string, string>
    ---@param seen table<string, boolean> 已请求过的 URL（重定向循环检测）
    ---@param hops number 已跟随的跳数
    issue = function(lane, url, m, req_body, headers, seen, hops)
        lane.job = Request.request({
            url = url,
            method = m,
            body = req_body,
            headers = withMirrorAuth(url, headers),
            timeout = opts.timeout or require("http.timeout").net(1),
        }, function(res, err)
            if cancelled or settled then return end
            local code = res and tonumber(res.code) or nil

            -- 传输层失败：这条镜像作废
            if not code then
                if originOf(url) == pinned_base then pinned_base = nil end
                local transport_err = classifyTransportError(res, err)
                return failover(lane, transport_err, "transport", transport_err)
            end
            ---@cast res table

            -- 30x：手动跟随（Turbo 默认不跟随）
            if REDIRECT_CODES[code] then
                -- 30x 的 Location 允许是相对地址（RFC 9110）
                local target = Text.absoluteUrl(url, Request.header(res, "location"))
                if not target then
                    return failover(lane, T(_("HTTP %1"), code), "invalid_redirect", code)
                end
                if seen[target] or hops + 1 > MAX_REDIRECT_HOPS then
                    return failover(lane, _("重定向过多"), "redirect_loop", target)
                end
                seen[target] = true
                -- 跨主机 = 镜像迁移；成功后按实际请求 URL 钉住新 origin。
                -- Location 的路径和查询是服务端给出的请求目标，不能丢掉。
                local new_origin = originOf(target)
                local is_mirror_move = new_origin and new_origin ~= originOf(url)
                logger.dbg("book.zlib redirect", code, originOf(url), new_origin or target)
                -- 镜像迁移与 307/308：保持 POST 和 body，跟随完整的 Location。
                if not is_mirror_move and code ~= 307 and code ~= 308 and m ~= "GET" then
                    -- 站内 301/302/303：转 GET 丢 body 及 Content-* 头
                    local kept = {}
                    for k, v in pairs(headers) do
                        local lk = k:lower()
                        if lk ~= "content-type" and lk ~= "content-length" then
                            kept[k] = v
                        end
                    end
                    issue(lane, target, "GET", nil, kept, seen, hops + 1)
                else
                    issue(lane, target, m, req_body, headers, seen, hops + 1)
                end
                return
            end

            -- 5xx 是镜像自己病了：换下一个
            if code >= 500 then
                return failover(lane, T(_("HTTP %1"), code), "status", code)
            end

            -- bot 挑战页：不是 JSON，是拦截页；换镜像才可能有用
            if looksLikeChallenge(res.body) then
                return failover(lane, _("服务器拒绝自动访问，正在尝试其它镜像"), "bot_challenge")
            end

            -- 这个 base 能用：钉住（胜出的镜像，下次排在最前）
            local selected = originOf(url) or lane.base
            if selected ~= pinned_base then
                logger.info("book.zlib mirror selected", selected)
            end
            pinned_base = selected

            local data, decode_err = decode(res.body)
            if not Request.ok(code) then
                local api_err = apiError(data, T(_("HTTP %1"), code))
                logger.dbg("book.zlib request rejected", method, path,
                    "attempt", lane.index, "of", #bases, selected,
                    "status", code, api_err)
                finish(nil, api_err)
                return
            end
            if not data then
                logger.dbg("book.zlib invalid response", method, path,
                    "attempt", lane.index, "of", #bases, selected,
                    "status", code, "bytes",
                    type(res.body) == "string" and #res.body or 0, decode_err)
                finish(nil, decode_err)
                return
            end
            logger.dbg("book.zlib request success", method, path,
                "attempt", lane.index, "of", #bases, selected, "status", code)
            finish(data)
        end)
    end

    cache_job = Cache.fetch(cache_key, cache_ttl, function(done)
        deliver = done
        pending = race and #bases or 1
        for _idx = 1, pending do
            if settled then break end
            launch()
        end
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
    local key = tostring(user.remix_userkey or user.user_key or "")
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
    local base = pinned_base or cfg.base_url or SEED_URLS[1]
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
        job = Request.download({
            url = link,
            method = "GET",
            headers = withMirrorAuth(link, self:headers(true)),
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
