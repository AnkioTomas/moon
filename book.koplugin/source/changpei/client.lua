--[[--
长佩文学网 HTTP 客户端（仅异步）。

走官网网页的 JSON 接口（www.gongzicp.com/webapi），请求头照网页端：`Client: pc` + 桌面浏览器 UA。
正文是 AES 密文，解密放子进程。回包 data.check 是服务端的风险等级：登录态 Cookie（PHPSESSID 等）+ `Client: pc` 时为 1，
匿名或 `Client: h5` 时 ≥ 2，此时正文为空 / 被换字打乱，要在浏览器过人机验证，不能用（本客户端当作未通过）。
登录态是网页 Cookie（setting.lua：扫码 / 浏览器授权 / 粘贴），Cookie 失效回包 code 9996；没买的 VIP 章不出正文。

@module koplugin.book.source.changpei.client
--]]

local Job = require("workers.job")
local JSON = require("json")
local Mapper = require("source.changpei.mapper")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("gettext")

local Client = {}

local SOURCE_ID = "changpei"
local LOGIN_REQUIRED = 9996
local MAX_SHELF_PAGES = 50

local API = "https://www.gongzicp.com/webapi"
-- 匿名榜单 / 搜索页走 http 缓存：切榜单、回书城不再每次联网。
local LIST_TTL = 5 * 60
Client.USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
    .. "Chrome/126.0.0.0 Safari/537.36"
local HEADERS = {
    ["Client"] = "pc",
    ["Referer"] = "https://www.gongzicp.com/",
    ["User-Agent"] = Client.USER_AGENT,
}

--- 已保存的登录 Cookie。
---@return string|nil
function Client.cookie()
    local cookie = require("utils.settings").getSource(SOURCE_ID).cookie
    return type(cookie) == "string" and cookie ~= "" and cookie or nil
end

---@param cookie string|nil
---@return table<string, string>
local function headers(cookie)
    local out = { ["Cookie"] = cookie }
    local token = cookie and cookie:match("moon_token=([^;%s]+)")
    if token then
        -- 扫码登录拿到的是网页端 sessionStorage 里的 token（请求头 token），不是 Cookie；借 Cookie 串带着存
        out["Cookie"] = cookie:gsub(";?%s*moon_token=[^;%s]+", ""):gsub(";?%s*moon_refresh=[^;%s]+", ""):gsub("^;%s*", "")
        out["token"] = token
    end
    for key, value in pairs(HEADERS) do out[key] = value end
    return out
end

---@type (fun(ok: boolean))[]|nil 正在换 token 时排队的回调；并发的 9996 只换一次
local renewing

--- 登录 token 过期：用 refresh_token（扫码登录存的 moon_refresh，或浏览器 Cookie 里的 ukey）换新 token，
--- 写回已保存的 Cookie。没有 refresh_token 或服务端拒绝返回 false。
---@param cb fun(ok: boolean)
function Client.renewAsync(cb)
    if renewing then renewing[#renewing + 1] = cb; return end
    local cookie = Client.cookie()
    local refresh = cookie and (cookie:match("moon_refresh=([^;%s]+)") or cookie:match("ukey=([^;%s]+)"))
    local imei = cookie and cookie:match("_c_n_=([^;%s]+)")
    if not refresh or not imei then cb(false); return end
    renewing = { cb }
    local QRLogin = require("source.changpei.qrlogin")
    local function finish(ok)
        local waiters = renewing
        renewing = nil
        for _idx, waiter in ipairs(waiters) do waiter(ok) end
    end
    Request.post("https://www.gongzicp.com/cp.UserExternal/get_token", QRLogin.frame(refresh, 5), {
        headers = {
            ["Content-Type"] = "application/grpc-web+proto",
            ["X-Grpc-Web"] = "1",
            ["Client"] = "pc",
            ["version"] = "1",
            ["imei"] = imei,
            ["Referer"] = "https://www.gongzicp.com/",
            ["User-Agent"] = Client.USER_AGENT,
        },
        content_type = "application/grpc-web+proto",
        timeout = require("http.timeout").net(0.5),
    }, function(body, _err, res)
        -- get_token 回包：token(3)。grpc-status 非 0 = refresh_token 也失效
        local token = body and (tonumber(Request.header(res, "grpc-status")) or 0) == 0 and QRLogin.decode(body)[3]
        if type(token) ~= "string" or token == "" then finish(false); return end
        local settings = require("utils.settings")
        local cfg = settings.getSource(SOURCE_ID)
        local saved = cfg.cookie:gsub(";?%s*moon_token=[^;%s]+", "")
        cfg.cookie = saved .. "; moon_token=" .. token
        settings.saveSource(SOURCE_ID, cfg)
        finish(true)
    end)
end

--- cookie 显式传入：登录入口要先校验再保存，校验用的新 Cookie 失效不能污染已保存的登录态。
---@param cookie string|nil
---@param cb fun(wire: table|nil, err: string|nil)
---@param retry boolean|nil
---@return fun(raw: string|nil, err: any)
local function reply(cookie, cb, retry)
    return function(raw, err)
        if not raw then cb(nil, err and tostring(err) or _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok or type(wire) ~= "table" then cb(nil, _("响应无效")); return end
        if wire.code ~= 200 then
            local msg = wire.msg or _("响应无效")
            if wire.code == LOGIN_REQUIRED and cookie and cookie == Client.cookie() then
                -- 只有 PHPSESSID 的 Cookie 登录是服务端会话，闲置（休眠）一阵就丢，没有续期凭据
                if not (cookie:match("moon_refresh=") or cookie:match("ukey=")) then
                    msg = _("长佩登录已失效。网页 Cookie 登录无法自动续期，请改用扫码登录")
                end
                if retry then
                    -- token 过期：用 refresh_token 换新的再重发一次；换不到才算登录失效
                    Client.renewAsync(function(renewed)
                        if renewed then retry() else cb(nil, require("source.auth").expire(SOURCE_ID, msg)) end
                    end)
                    return
                end
                msg = require("source.auth").expire(SOURCE_ID, msg)
            end
            cb(nil, msg)
            return
        end
        if cookie and cookie == Client.cookie() then require("source.auth").ok(SOURCE_ID) end
        cb(wire)
    end
end

local function get(path, query, cookie, cb, renewed, cache_ttl)
    local cancelled, job = false, nil
    local retry = cookie and not renewed and function()
        if not cancelled then job = get(path, query, Client.cookie(), cb, true) end
    end
    job = Request.get(API .. path .. "?" .. query, {
        accept = "application/json",
        headers = headers(cookie),
        timeout = require("http.timeout").net(0.5),
        cache_ttl = cache_ttl,
    }, reply(cookie, cb, retry))
    return { cancel = function()
        cancelled = true
        job.cancel()
    end }
end

-- 网页端非 GET 请求的签名：md5(固定前缀 .. 按键名排序的 &k=v .. &服务器时间)，params 的值是已渲染的字符串。
local SIGN_PREFIX = "SIa7xu0LRrbu$En3*I1T3EiO^40cN49D"

---@param params table<string, string>
---@param timestamp string
---@return string
local function sign(params, timestamp)
    local keys = {}
    for key in pairs(params) do keys[#keys + 1] = key end
    table.sort(keys)
    local parts = { SIGN_PREFIX }
    for _idx, key in ipairs(keys) do parts[#parts + 1] = "&" .. key .. "=" .. params[key] end
    parts[#parts + 1] = "&" .. timestamp
    return require("crypto.md5").hex(table.concat(parts))
end

--- 带签名的 JSON POST：先取服务器时间（本机时钟不可信）再发。
---@param path string
---@param params table<string, string>
---@param body string
---@param cb fun(wire: table|nil, err: string|nil)
---@return { cancel: fun() }
local function post(path, params, body, cb, renewed)
    local cookie = Client.cookie()
    local cancelled, job = false, nil
    local retry = cookie and not renewed and function()
        if not cancelled then job = post(path, params, body, cb, true) end
    end
    job = get("/system/init", "", nil, function(init, err)
        if cancelled then return end
        local timestamp = (init and type(init.data) == "table" and init.data.timestamp) --[[@as string|number|nil]]
        if not timestamp then cb(nil, err or _("响应无效")); return end
        ---@cast timestamp string|number
        timestamp = tostring(timestamp)
        local head = headers(cookie)
        head["Timestamp"] = timestamp
        head["Rand-Str"] = sign(params, timestamp)
        job = Request.post(API .. path, body, {
            accept = "application/json",
            headers = head,
            content_type = "application/json",
            timeout = require("http.timeout").net(0.5),
        }, reply(cookie, cb, retry))
    end)
    return { cancel = function()
        cancelled = true
        job:cancel()
    end }
end

---@param keyword string
---@param cb fun(wire: table|nil, err: string|nil)
---@return HttpJob
function Client.searchAsync(keyword, cb)
    return get("/search/novels", "page=1&k=" .. Text.urlEncode(keyword), nil, cb, true, LIST_TTL)
end

---@param novel_id string
---@param cb fun(wire: table|nil, err: string|nil)
---@return HttpJob
function Client.chaptersAsync(novel_id, cb)
    return get("/novel/chapterGetList", "nid=" .. novel_id, Client.cookie(), cb)
end

---@param cb fun(wire: table|nil, err: string|nil)
---@return HttpJob
function Client.rankNavAsync(cb)
    return get("/novel/rankingNav", "", nil, cb, true, LIST_TTL)
end

---@param rid integer
---@param tid integer
---@param page integer
---@param cb fun(wire: table|nil, err: string|nil)
---@return HttpJob
function Client.rankAsync(rid, tid, page, cb)
    return get("/novel/rankingGetList", ("tid=0&rid=%d&date=%d&page=%d"):format(rid, tid, page), nil, cb, true, LIST_TTL)
end

--- 网页书架（根目录，不含分组里的书），逐页取到空页为止。
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return { cancel: fun() }
function Client.shelfAsync(cb)
    local rows, cancelled, job = {}, false, nil
    local function page(n)
        job = get("/usercoll/getList", "filter=0&sort_key=1&sort_flag=2&did=0&page=" .. n, Client.cookie(),
            function(wire, err)
                if cancelled then return end
                if not wire then cb(nil, err); return end
                local list = type(wire.data) == "table" and wire.data.list or {}
                for _idx, row in ipairs(list) do
                    if row.type == "novel" then rows[#rows + 1] = row end
                end
                if #list == 0 or n >= MAX_SHELF_PAGES then cb(rows) else page(n + 1) end
            end)
    end
    page(1)
    return { cancel = function()
        cancelled = true
        if job then job:cancel() end
    end }
end

--- 网页端加 / 移出书架同一个接口：status 1 加入，0 移出。
local function collect(stable_id, status, cb)
    local nid = ("%d"):format(tonumber(stable_id))
    return post("/usercoll/collHandle", { module = "novel", cid = nid, status = tostring(status) },
        '{"module":"novel","cid":' .. nid .. ',"status":' .. status .. "}", cb)
end

---@param stable_id string
---@param cb fun(wire: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client.shelfAddAsync(stable_id, cb) return collect(stable_id, 1, cb) end

---@param stable_id string
---@param cb fun(wire: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client.shelfRemoveAsync(stable_id, cb) return collect(stable_id, 0, cb) end

--- 阅读历史：服务端按 novel_id 记最近读到的章（latest_read_cid）。
---@param cb fun(wire: table|nil, err: string|nil)
---@return HttpJob
function Client.historyAsync(cb)
    return get("/usernovel/getHistory", "", Client.cookie(), cb)
end

--- 取一章即在服务端记为「读到这里」（登录 Cookie 下网页接口自动写阅读历史）。
---@param chapter_id string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return HttpJob
function Client.markReadAsync(chapter_id, cb)
    return get("/novel/chapterGetInfo", "cid=" .. chapter_id .. "&server=0", Client.cookie(), function(wire, err)
        cb(wire and true or nil, err)
    end)
end

--- 校验 cookie：返回账号信息（nickname 等），失效回调错误。
---@param cookie string
---@param cb fun(info: table|nil, err: string|nil)
---@return HttpJob
function Client.userAsync(cookie, cb)
    return get("/user/getUserInfo", "", cookie, function(wire, err)
        cb(wire and wire.data or nil, err)
    end)
end

--- 一章正文（纯文本，段落以换行分隔）。
---@param _novel_id string
---@param chapter_id string
---@param cb fun(text: string|nil, err: string|nil, kind: "unpaid"|nil)
---@return { cancel: fun() }
function Client.contentAsync(_novel_id, chapter_id, cb)
    local cancelled, job = false, nil
    job = get("/novel/chapterGetInfo", "cid=" .. chapter_id .. "&server=0", Client.cookie(), function(wire, err)
        if cancelled then return end
        if not wire then cb(nil, err); return end
        job = Job.run(function()
            local text, reason, kind = Mapper.content(wire)
            return { text = text, err = reason, kind = kind }
        end, {
            name = "changpei_content",
            kind = "light",
            timeout = 60,
            on_done = function(res)
                if cancelled then return end
                if res.text then cb(res.text); return end
                if res.kind == "verify" then
                    if not Client.cookie() then
                        cb(nil, _("长佩需要登录后阅读，请先在设置里登录长佩账号"))
                        return
                    end
                    -- 登录态已不被服务端信任：标记失效，用户在浏览器过验证后可重新授权
                    cb(nil, require("source.auth").expire("changpei",
                        _("长佩要求人机验证，请先在浏览器打开 gongzicp.com 阅读一章完成验证，再重新授权")))
                    return
                end
                cb(nil, res.err or _("长佩章节内容为空"), res.kind)
            end,
            on_failed = function(reason) if not cancelled then cb(nil, tostring(reason)) end end,
            on_cancelled = function() end,
        })
    end)
    return { cancel = function()
        cancelled = true
        job:cancel()
    end }
end

return Client
