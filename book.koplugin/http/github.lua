--[[--
GitHub 加速镜像调度（仓库文件 + Release 资产，与 Z-Library 相同的动态目录缓存策略）。

镜像列表来自 `https://api.ankio.net/gh/mirrors`（`jsdelivr` + `raw` + `release`），拉回后
长期缓存到 `settings("http")`：
- 某个镜像可用就一直用（钉在 `mirror_last` / `mirror_release_last`），不再请求目录接口；
- 失效后依次回落本地缓存的其余可用镜像，同场有源成功则把失败源落盘拉黑 `DEAD_TTL`；
- 仅在本地缓存为空、全被拉黑，或本地所有可用镜像均失败时，才重新请求目录接口；
- 目录接口不可达时：有旧缓存则清黑名单兜底重试一次，首次无缓存则退回极简内置列表（不落盘）。

镜像一律不可信，内容只靠调用方的 sha256 / 长度把关；本模块只负责挑地址、防 HTML 假 200 与换源。

@module koplugin.book.http.github
--]]

local JSON = require("json")
local Request = require("http.request")
local logger = require("utils.log")

---@class GithubDownloadOpts : HttpRequestOpts
---@field check (fun(dest: string): boolean, string|nil)|nil 下载后的校验
local Github = {}

Github.MIRRORS_API = "https://api.ankio.net/gh/mirrors"
Github.DEAD_TTL = 7 * 24 * 3600

local GITHUB = "https://github.com"
local RAW_OFFICIAL = "https://raw.githubusercontent.com/{owner}/{repo}/{ref}/{path}"
local PROBE_MIRRORS = 5
local PROBE_TIMEOUT_RATIO = 1 / 3 -- × 「网络超时」，缺省 10 秒

--- 仅在本地无缓存且 MIRRORS_API 不可达时兜底，不写入 settings("http")。
Github.FALLBACK_FILES = {
    "https://fastly.jsdelivr.net/gh/{owner}/{repo}@{ref}/{path}",
    "https://gh-proxy.org/" .. RAW_OFFICIAL,
    "https://edgeone.gh-proxy.org/" .. RAW_OFFICIAL,
    "https://gcore.jsdelivr.net/gh/{owner}/{repo}@{ref}/{path}",
    RAW_OFFICIAL,
}

Github.FALLBACK_RELEASE = {
    "https://gh-proxy.com/https://github.com",
    "https://gh-proxy.org/https://github.com",
    "https://edgeone.gh-proxy.org/https://github.com",
    "https://ghfast.top/https://github.com",
    "https://wget.la/https://github.com",
}

---@return table
local function conf()
    local ok, cfg = pcall(function() return require("utils.settings").get("http") end)
    return ok and type(cfg) == "table" and cfg or {}
end

local function saveHttp()
    local ok, err = pcall(function() require("utils.settings").save("http") end)
    if not ok then logger.warn("book.http github save failed", err) end
end

local function normalizePrefix(value)
    if type(value) ~= "string" then return nil end
    local s = value:gsub("%s+", ""):gsub("/+$", "")
    return s:match("^[hH][tT][tT][pP][sS]?://[^/]+") and s or nil
end

local function normalizeTemplate(value)
    if type(value) ~= "string" then return nil end
    local s = value:gsub("%s+", "")
    if not s:match("^[hH][tT][tT][pP][sS]?://") then return nil end
    if s:find("{owner}", 1, true) and s:find("{repo}", 1, true)
        and s:find("{ref}", 1, true) and s:find("{path}", 1, true) then
        return s
    end
    return nil
end

--- 源（模板或加速前缀）是否在落盘黑名单里。
---@param key string
---@return boolean
function Github.isDead(key)
    local at = (conf().mirror_dead or {})[key]
    return at ~= nil and os.time() - at < Github.DEAD_TTL
end

--- 落盘拉黑一批源，同时清掉过期条目。只应在同场有源成功（网络确实通）时调用。
---@param keys string[]
function Github.markDead(keys)
    if #keys == 0 then return end
    local cfg, now = conf(), os.time()
    local dead = {}
    for key, at in pairs(cfg.mirror_dead or {}) do
        if now - at < Github.DEAD_TTL then dead[key] = at end
    end
    for _idx, key in ipairs(keys) do dead[key] = now end
    cfg.mirror_dead = dead
    saveHttp()
end

local function markOk(last_key, key)
    local cfg, dirty = conf(), false
    if type(cfg.mirror_dead) == "table" and cfg.mirror_dead[key] ~= nil then
        cfg.mirror_dead[key] = nil
        dirty = true
    end
    if cfg[last_key] ~= key then
        cfg[last_key] = key
        dirty = true
    end
    if dirty then saveHttp() end
end

local function contains(list, value)
    if not value then return false end
    for _idx, item in ipairs(list) do
        if item == value then return true end
    end
    return false
end

--- 本地可用候选：上次成功源优先 → 本地缓存列表，跳过未过期的黑名单源。
local function candidates(pool_key, last_key, norm)
    local cfg = conf()
    local out, seen = {}, {}
    local function add(v)
        v = norm(v)
        if v and not seen[v] and not Github.isDead(v) then
            seen[v] = true
            out[#out + 1] = v
        end
    end
    add(cfg[last_key])
    if type(cfg[pool_key]) == "table" then
        for _idx, item in ipairs(cfg[pool_key]) do add(item) end
    end
    return out
end

--- 过滤本轮未试过的去重候选（可选截断前 limit 项）。
local function untried(list, tried, limit)
    local out, seen = {}, {}
    for _idx, item in ipairs(list) do
        if not tried[item] and not seen[item] then
            seen[item] = true
            out[#out + 1] = item
            if limit and #out >= limit then break end
        end
    end
    return out
end

--- MIRRORS_API 不可达时的兜底：旧缓存有拉黑项则清黑名单重用，无缓存则用极简内置列表（不落盘）。
local function fallbackPool(pool_key, defaults, norm)
    local cfg = conf()
    if type(cfg[pool_key]) == "table" and #cfg[pool_key] > 0 then
        local out, had_dead = {}, false
        for _idx, item in ipairs(cfg[pool_key]) do
            local v = norm(item)
            if v then
                if type(cfg.mirror_dead) == "table" and cfg.mirror_dead[v] ~= nil then
                    cfg.mirror_dead[v] = nil
                    had_dead = true
                end
                out[#out + 1] = v
            end
        end
        return had_dead and out or {}
    end
    return defaults
end

--- 死镜像常回 200 + 自家 HTML 首页。
local function isHtml(headers)
    local mime
    if type(headers) == "table" and type(headers.get) == "function" then
        mime = headers:get("Content-Type", true)
    elseif type(headers) == "table" then
        for k, v in pairs(headers) do
            if type(k) == "string" and k:lower() == "content-type" then mime = v end
        end
    end
    return type(mime) == "string" and mime:lower():find("text/html", 1, true) ~= nil
end

local function parseMirrors(body)
    if type(body) ~= "string" or body == "" then return nil end
    local ok, payload = pcall(JSON.decode, body)
    if not ok or type(payload) ~= "table" then return nil end
    local data = type(payload.data) == "table" and payload.data or payload

    local files, seen_f = {}, {}
    local function addFile(t)
        if t and not seen_f[t] then seen_f[t] = true; files[#files + 1] = t end
    end
    for _idx, item in ipairs(type(data.jsdelivr) == "table" and data.jsdelivr or {}) do
        addFile(normalizeTemplate(item))
    end
    for _idx, item in ipairs(type(data.raw) == "table" and data.raw or {}) do
        local p = normalizePrefix(item)
        if p then addFile(p .. "/{owner}/{repo}/{ref}/{path}") end
    end
    if #files > 0 then addFile(RAW_OFFICIAL) end

    local release, seen_r = {}, {}
    for _idx, item in ipairs(type(data.release) == "table" and data.release or {}) do
        local p = normalizePrefix(item)
        if p and not seen_r[p] then seen_r[p] = true; release[#release + 1] = p end
    end
    if #files == 0 and #release == 0 then return nil end
    return { files = files, release = release }
end

--- 从 MIRRORS_API 拉取最新探测可用的镜像并落盘，同时清黑名单。
local function refresh(cb)
    logger.info("book.http github mirrors refresh", Github.MIRRORS_API)
    return Request.get(Github.MIRRORS_API, {
        allow_redirects = true,
        accept = "application/json",
        timeout = require("http.timeout").net(1),
    }, function(body, err)
        local parsed = parseMirrors(body)
        if not parsed then
            logger.warn("book.http github mirrors refresh failed", err or "invalid response")
            return cb(false)
        end
        local cfg = conf()
        if #parsed.files > 0 then
            cfg.mirror_files = parsed.files
            local last = normalizeTemplate(cfg.mirror_last)
            cfg.mirror_last = contains(parsed.files, last) and last or ""
        end
        if #parsed.release > 0 then
            cfg.mirror_release = parsed.release
            local last_r = normalizePrefix(cfg.mirror_release_last)
            cfg.mirror_release_last = contains(parsed.release, last_r) and last_r or ""
        end
        cfg.mirror_dead = {}
        saveHttp()
        cb(true)
    end)
end

local function expandMoon(template, path)
    local vars = { owner = "AnkioTomas", repo = "moon", ref = "main", path = path }
    return (template:gsub("{(%w+)}", vars))
end

--- 仓库文件的单个地址（图片等无法回落的场景）：上次成功源 → 本地缓存首个可用源 → 内置首选。
---@param path string
---@return string
function Github.url(path)
    local list = candidates("mirror_files", "mirror_last", normalizeTemplate)
    return expandMoon(list[1] or Github.FALLBACK_FILES[1], path)
end

local function withUrl(opts, url)
    local o = { allow_redirects = true, connect_timeout = require("http.timeout").net(1 / 6) }
    for k, v in pairs(opts or {}) do o[k] = v end
    o.url, o.check = url, nil
    return o
end

--- 串行回落引擎（get / download 共用）。
local function runFile(path, startFn, cb)
    local cancelled, refreshed = false, false
    local tried, bad = {}, {}
    local queue, idx, seq, job, last_err = {}, 0, 0, nil, nil

    local try, startWave, refreshAndRetry

    refreshAndRetry = function()
        refreshed = true
        seq = seq + 1
        local my_seq = seq
        local handle = refresh(function(ok)
            if cancelled then return end
            if ok then bad = {} end
            local pool = ok and candidates("mirror_files", "mirror_last", normalizeTemplate)
                or fallbackPool("mirror_files", Github.FALLBACK_FILES, normalizeTemplate)
            local fresh = untried(pool, tried)
            if #fresh > 0 then return startWave(fresh) end
            cb(false, last_err or "no mirror")
        end)
        if not cancelled and my_seq == seq then job = handle end
    end

    startWave = function(list)
        queue, idx = list, 0
        try()
    end

    try = function()
        if cancelled then return end
        idx = idx + 1
        local template = queue[idx]
        if not template then
            if not refreshed then return refreshAndRetry() end
            return cb(false, last_err or "no mirror")
        end
        if tried[template] then return try() end
        tried[template] = true
        local url = expandMoon(template, path)
        seq = seq + 1
        local my_seq = seq
        local handle = startFn(url, function(err, payload)
            if cancelled then return end
            if err == nil then
                markOk("mirror_last", template)
                Github.markDead(bad)
                return cb(true, nil, payload)
            end
            last_err = err
            bad[#bad + 1] = template
            logger.warn("book.http github mirror failed", url, err)
            return try()
        end)
        -- 回调同步触发时已发出下一个请求，不能用旧句柄覆盖它。
        if not cancelled and my_seq == seq then job = handle end
    end

    local initial = candidates("mirror_files", "mirror_last", normalizeTemplate)
    if #initial > 0 then startWave(initial) else refreshAndRetry() end
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job:cancel() end
    end }
end

--- GET 本仓库文件（manifest 等小文件），失败换源。
---@param path string
---@param opts HttpRequestOpts|nil
---@param cb fun(body: string|nil, err: any)
---@return table handle
function Github.get(path, opts, cb)
    return runFile(path, function(url, next_cb)
        local o = withUrl(opts, url)
        o.url = nil
        return Request.get(url, o, function(body, err, res)
            if not body then return next_cb(err or "empty") end
            if isHtml(res and res.headers) then return next_cb("html response") end
            next_cb(nil, body)
        end)
    end, function(ok, err, body)
        if ok then cb(body) else cb(nil, err) end
    end)
end

--- 下载本仓库文件到 dest，失败（含断流 / check 不过）换源重下；内容校验由调用方负责。
---@param path string
---@param opts GithubDownloadOpts|nil
---@param dest string
---@param cb fun(ok: boolean, err: any)
---@return table handle
function Github.download(path, opts, dest, cb)
    opts = opts or {}
    local idle_seconds = require("http.timeout").net(1)
    return runFile(path, function(url, next_cb)
        local UIManager = require("ui/uimanager")
        local dead, idle_fn, job = false, nil, nil
        local function disarm()
            if idle_fn then UIManager:unschedule(idle_fn); idle_fn = nil end
        end
        local function arm()
            if dead then return end
            disarm()
            idle_fn = function()
                idle_fn = nil
                if dead then return end
                dead = true
                if job and job.cancel then job:cancel() end
                next_cb("download stalled")
            end
            UIManager:scheduleIn(idle_seconds, idle_fn)
        end
        local request = withUrl(opts, url)
        local progress = request.on_progress
        request.on_progress = function(...)
            arm()
            if progress then progress(...) end
        end
        job = Request.download(request, dest, function(ok, err, res)
            if dead then return end
            dead = true
            disarm()
            if ok and isHtml(res and res.headers) then ok, err = false, "html response" end
            if ok and opts.check then ok, err = opts.check(dest) end
            if not ok then
                os.remove(dest)
                return next_cb(err or "download failed")
            end
            next_cb(nil)
        end)
        if not dead then arm() end
        return { cancel = function()
            dead = true
            disarm()
            if job and job.cancel then job:cancel() end
        end }
    end, function(ok, err)
        cb(ok == true, err)
    end)
end

--- 并发探测 Release 直连与动态镜像：上次可用镜像优先单独复用，失效再按批探测，全不可用才刷新目录，最终回落直连。
---@param release { url: string, size: number|nil }
---@param cb fun(url: string)
---@return table handle { cancel }
function Github.pickRelease(release, cb)
    local UIManager = require("ui/uimanager")
    local path = release.url:sub(#GITHUB + 1)
    local settled, refreshed = false, false
    local tried, bad, flagged = {}, {}, {}
    local jobs, refresh_job = {}, nil

    local function cancelProbes()
        for _idx, j in ipairs(jobs) do j:cancel() end
        jobs = {}
    end
    local function cancelAll()
        settled = true
        if refresh_job and refresh_job.cancel then refresh_job:cancel(); refresh_job = nil end
        cancelProbes()
    end
    local function flagBad(prefix)
        if prefix ~= GITHUB and not flagged[prefix] then
            flagged[prefix] = true
            bad[#bad + 1] = prefix
        end
    end

    local probeWave, nextWave, refreshAndProbe

    local function settle(url, winner)
        if settled then return end
        cancelAll()
        if winner and winner ~= GITHUB then
            markOk("mirror_release_last", winner)
            Github.markDead(bad)
        end
        logger.dbg("book.http github release download from", url)
        cb(url)
    end

    refreshAndProbe = function()
        refreshed = true
        local finished = false
        local handle = refresh(function(ok)
            finished = true
            refresh_job = nil
            if settled then return end
            if ok then bad, flagged = {}, {} end
            local pool = ok and candidates("mirror_release", "mirror_release_last", normalizePrefix)
                or fallbackPool("mirror_release", Github.FALLBACK_RELEASE, normalizePrefix)
            local batch = untried(pool, tried, PROBE_MIRRORS)
            if #batch > 0 then return probeWave(batch) end
            settle(release.url, nil)
        end)
        if not finished and not settled then refresh_job = handle end
    end

    nextWave = function()
        if settled then return end
        local pinned = normalizePrefix(conf().mirror_release_last)
        if pinned and not Github.isDead(pinned) and not tried[pinned] then
            return probeWave({ pinned })
        end
        local pool = candidates("mirror_release", "mirror_release_last", normalizePrefix)
        local batch = untried(pool, tried, PROBE_MIRRORS)
        if #batch > 0 then return probeWave(batch) end
        if not refreshed then return refreshAndProbe() end
        settle(release.url, nil)
    end

    probeWave = function(mirror_prefixes)
        cancelProbes()
        local prefixes = { GITHUB }
        for _idx, p in ipairs(mirror_prefixes) do
            tried[p] = true
            prefixes[#prefixes + 1] = p
        end
        local pending, wave_done = #prefixes, false
        for i, prefix in ipairs(prefixes) do
            local url = prefix .. path
            jobs[i] = Request.stream({
                url = url,
                timeout = require("http.timeout").net(PROBE_TIMEOUT_RATIO),
                allow_redirects = true,
            }, {
                on_headers = function(code, headers)
                    if settled or wave_done then return end
                    if code ~= 200 then return flagBad(prefix) end
                    local length = tonumber((headers:get("Content-Length", true)))
                    if length and release.size and length ~= release.size then return flagBad(prefix) end
                    if isHtml(headers) then return flagBad(prefix) end
                    wave_done = true
                    UIManager:nextTick(require("ui.guard").wrap("github release settle", function()
                        settle(url, prefix)
                    end))
                end,
                on_done = function(err)
                    if settled or wave_done then return end
                    if err then flagBad(prefix) end
                    pending = pending - 1
                    if pending == 0 then
                        wave_done = true
                        UIManager:nextTick(require("ui.guard").wrap("github release next wave", nextWave))
                    end
                end,
            })
        end
    end

    nextWave()
    return { cancel = cancelAll }
end

return Github
