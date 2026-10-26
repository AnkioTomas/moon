--[[--
仓库文件下载源：按序回落的镜像列表（jsDelivr 各节点 + GitHub 公益加速）。

镜像一律不可信，内容只靠调用方的 sha256 / 长度把关；本模块只负责挑地址：
上次成功的源排最前，30 分钟内失败过的源排到最后。
`get` / `download` 失败（含返回 HTML 首页）就换下一个源重试同一文件。

manifest 也走镜像链。

换源前先取消正在进行的请求；调用方取消后整条回落链停止，不再请求下一个源。

@module koplugin.book.http.mirror
--]]

local Request = require("http.request")
local logger = require("utils.log")

---@class MirrorDownloadOpts : HttpRequestOpts
---@field check (fun(dest: string): boolean, string|nil)|nil 下载后的校验
local Mirror = {}

--- 仓库文件模板，{path} 为仓库内路径（如 assets/dict/manifest.json）。
local RAW = "https://raw.githubusercontent.com/AnkioTomas/moon/main/{path}"
Mirror.DEFAULTS = {
    "https://fastly.jsdelivr.net/gh/AnkioTomas/moon@main/{path}",
    "https://gh-proxy.com/" .. RAW,
    "https://edgeone.gh-proxy.org/" .. RAW,
    "https://jsd.onmicrosoft.cn/gh/AnkioTomas/moon@main/{path}",
    "https://gcore.jsdelivr.net/gh/AnkioTomas/moon@main/{path}",
    "https://ghfast.top/" .. RAW,
    "https://cdn.jsdelivr.net/gh/AnkioTomas/moon@main/{path}",
    "https://testingcf.jsdelivr.net/gh/AnkioTomas/moon@main/{path}",
    RAW,
}

--- Release 包公益加速前缀（同步自 XIU2/UserScript「Github 增强 - 高速下载」），前缀 + github.com 之后的路径。
Mirror.RELEASE_PROXIES = {
    "https://gh-proxy.org/https://github.com",
    "https://cdn.gh-proxy.org/https://github.com",
    "https://edgeone.gh-proxy.org/https://github.com",
    "https://cors.isteed.cc/github.com",
    "https://ghproxy.it/https://github.com",
    "https://github.boki.moe/https://github.com",
    "https://gh.jasonzeng.dev/https://github.com",
    "https://gh.monlor.com/https://github.com",
    "https://github.ednovas.xyz/https://github.com",
    "https://ghfile.geekertao.top/https://github.com",
    "https://ghp.keleyaa.com/https://github.com",
    "https://gh.chjina.com/https://github.com",
    "https://cdn.crashmc.com/https://github.com",
    "https://git.yylx.win/https://github.com",
    "https://gitproxy.mrhjx.cn/https://github.com",
    "https://ghproxy.cxkpro.top/https://github.com",
    "https://down.npee.cn/?https://github.com",
    "https://xget.xi-xu.me/gh",
    "https://gh.zwy.one/https://github.com",
    "https://ghproxy.monkeyray.net/https://github.com",
    "https://ghproxy.net/https://github.com",
    "https://ghfast.top/https://github.com",
    "https://wget.la/https://github.com",
    "https://gh.llkk.cc/https://github.com",
}

--- 失败源的冷却秒数。
Mirror.COOLDOWN = 30 * 60

--- 失败源落盘拉黑的秒数。
Mirror.DEAD_TTL = 7 * 24 * 3600

--- 模板 → 最近失败时间（只在内存，重启即清）。
local failed = {}

---@return table http 配置；设置模块不可用（测试桩）时给空表
local function conf()
    local ok, cfg = pcall(function() return require("utils.settings").get("http") end)
    return ok and type(cfg) == "table" and cfg or {}
end

--- 源（模板或加速前缀）是否在落盘黑名单里。
---@param key string
---@return boolean
function Mirror.isDead(key)
    local at = (conf().mirror_dead or {})[key]
    return at ~= nil and os.time() - at < Mirror.DEAD_TTL
end

--- 落盘拉黑一批源，同时清掉过期条目。只应在同场有源成功（网络确实通）时调用，免得断网把全部源拉黑。
---@param keys string[]
function Mirror.markDead(keys)
    if #keys == 0 then return end
    local cfg, now = conf(), os.time()
    local dead = {}
    for key, at in pairs(cfg.mirror_dead or {}) do
        if now - at < Mirror.DEAD_TTL then dead[key] = at end
    end
    for _idx, key in ipairs(keys) do dead[key] = now end
    cfg.mirror_dead = dead
    pcall(function() require("utils.settings").save("http") end)
end

--- 按优先级排好的模板列表：上次成功 → 其余默认；冷却中的源垫底。
---@return string[]
function Mirror.templates()
    local cfg, now = conf(), os.time()
    local list, seen = {}, {}
    local function add(t)
        if t and not seen[t] then seen[t] = true; list[#list + 1] = t end
    end
    for _idx, t in ipairs(Mirror.DEFAULTS) do
        if t == cfg.mirror_last then add(t) end
    end
    local cooling, dead = {}, {}
    for _idx, t in ipairs(Mirror.DEFAULTS) do
        if Mirror.isDead(t) then
            dead[#dead + 1] = t
        elseif failed[t] and now - failed[t] < Mirror.COOLDOWN then
            cooling[#cooling + 1] = t
        else
            add(t)
        end
    end
    for _idx, t in ipairs(cooling) do add(t) end
    -- 黑名单源只在其余都没了时才兜底，避免全被拉黑后无源可用
    if #list == 0 then for _idx, t in ipairs(dead) do add(t) end end
    return list
end

---@param template string
---@param path string 仓库内路径
---@return string
local function expand(template, path)
    return (template:gsub("{path}", function() return path end))
end

--- 仓库文件的单个地址（图片等无法回落的场景）：上次成功的源，没有就用 fastly 节点的 jsDelivr。
---@param path string
---@return string
function Mirror.url(path)
    local last = conf().mirror_last
    for _idx, t in ipairs(Mirror.DEFAULTS) do
        if t == last then return expand(t, path) end
    end
    return expand(Mirror.DEFAULTS[1], path)
end

local function markOk(template)
    failed[template] = nil
    if Mirror.isDead(template) then conf().mirror_dead[template] = nil end
    local cfg = conf()
    if cfg.mirror_last ~= template then
        cfg.mirror_last = template
        pcall(function() require("utils.settings").save("http") end)
    end
end

local function markFail(template, url, err)
    failed[template] = os.time()
    logger.warn("book.http mirror failed", url, err)
end

---@param res table|nil
---@return boolean 死镜像常回 200 + 自家 HTML 首页
local function isHtml(res)
    local headers, mime = res and res.headers, nil
    if type(headers) == "table" and type(headers.get) == "function" then
        mime = headers:get("Content-Type", true)
    elseif type(headers) == "table" then
        for k, v in pairs(headers) do
            if type(k) == "string" and k:lower() == "content-type" then mime = v end
        end
    end
    return type(mime) == "string" and mime:lower():find("text/html", 1, true) ~= nil
end

--- 逐个源尝试：start(url, next_cb) 发请求，next_cb(err) 非空就换下一个源。
---@return table handle { cancel }
local function chain(path, start, cb)
    local list, idx, job, cancelled = Mirror.templates(), 0, nil, false
    local last_err, bad = nil, {}
    local function try()
        if cancelled then return end
        idx = idx + 1
        local template = list[idx]
        if not template then return cb(nil, last_err or "no mirror") end
        local url, attempt = expand(template, path), idx
        local handle = start(url, function(err, ...)
            if cancelled then return end
            if err then
                last_err = err
                bad[#bad + 1] = template
                markFail(template, url, err)
                return try()
            end
            markOk(template)
            Mirror.markDead(bad)
            cb(true, nil, ...)
        end)
        -- 同步失败时 try() 已递归发出下一个请求，不能用旧句柄覆盖它。
        if attempt == idx then job = handle end
    end
    try()
    return { cancel = function()
        cancelled = true
        if job then job:cancel() end
    end }
end

--- 浅拷贝请求参数，补上地址与短连接超时（死源 5 秒左右就换下一个）。
local function withUrl(opts, url)
    local o = { allow_redirects = true, connect_timeout = require("http.timeout").net(1 / 6) }
    for k, v in pairs(opts) do o[k] = v end
    o.url, o.check = url, nil
    return o
end

--- GET 仓库文件（manifest 等小文件），失败换源。
---@param path string
---@param opts HttpRequestOpts|nil
---@param cb fun(body: string|nil, err: any)
---@return table handle
function Mirror.get(path, opts, cb)
    opts = opts or {}
    return chain(path, function(url, next_cb)
        local o = withUrl(opts, url)
        o.url = nil
        return Request.get(url, o, function(body, err, res)
            if not body then return next_cb(err or "empty") end
            if isHtml(res) then return next_cb("html response") end
            next_cb(nil, body)
        end)
    end, function(ok, err, body)
        if ok then cb(body) else cb(nil, err) end
    end)
end

--- 下载仓库文件到 dest，失败（含 check 不过）换源重下；内容校验由调用方负责。
---@param path string
---@param opts MirrorDownloadOpts 不含 url；可校验下载文件
---@param dest string
---@param cb fun(ok: boolean, err: any)
---@return table handle
function Mirror.download(path, opts, dest, cb)
    return chain(path, function(url, next_cb)
        return Request.download(withUrl(opts, url), dest, function(ok, err, res)
            if ok and isHtml(res) then ok, err = false, "html response" end
            if ok and opts.check then ok, err = opts.check(dest) end
            if not ok then
                os.remove(dest)
                return next_cb(err or "download failed")
            end
            next_cb(nil)
        end)
    end, function(ok, err)
        cb(ok == true, err)
    end)
end

return Mirror
