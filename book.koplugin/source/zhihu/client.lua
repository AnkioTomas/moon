--[[--
知乎盐选网页接口。

榜单匿名可用。搜索是 `/api/v4/search_v3?t=km_general`，没有登录态会被风控。
正文走签名的 VIP JSON 接口，检查购买权限，再异步还原乱序字形。

扫码登录沿用匿名会话，确认后校验 Cookie 再保存。

@module source.zhihu.client
--]]

local JSON = require("json")
local Mapper = require("source.zhihu.mapper")
local Sign = require("source.zhihu.sign")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("l10n").get("source.zhihu")

local Client = {}

local API = "https://api.zhihu.com"
local WEB = "https://www.zhihu.com"
local UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
local SOURCE_ID = "zhihu"
local CAPTCHA = "https://captcha.zhihu.com/api/v1/captcha"
local CAPTCHA_APP = "lsxNQs26Wva2"

---@class ZhihuQRSession
---@field jar table<string, string>
---@field token string
---@field link string
---@field expires_at number|nil
---@field challenge_id string|nil

---@return string|nil
function Client.cookie()
    local cookie = require("utils.settings").getSource("zhihu").cookie
    return type(cookie) == "string" and cookie ~= "" and cookie or nil
end

---@param headers table|nil
---@return table
local function opts(headers)
    return {
        timeout = require("http.timeout").net(1),
        headers = require("http.request.header").merge(headers, { ["User-Agent"] = UA }),
    }
end

--- 搜索没有登录态会被风控。Cookie 存在 settings，跟其它源一样随请求带上。
---@param headers table|nil
---@return table|nil
local function withCookie(headers)
    local saved = Client.cookie()
    if not saved then return headers end
    headers = headers or {}
    if not headers.Cookie then headers.Cookie = saved end
    return headers
end

---@param url string
---@param headers table|nil
---@param cb fun(body: string|nil, err: any)
---@return HttpJob
local function get(url, headers, cb)
    local cookie = Client.cookie()
    return Request.get(url, opts(withCookie(headers)), function(body, err, res)
        if res and tonumber(res.code) == 401 and cookie and cookie == Client.cookie() then
            cb(nil, require("source.auth").expire("zhihu", _("知乎登录已失效，请重新登录")))
            return
        end
        cb(body, err)
    end)
end

---@param raw string|nil
---@return table|nil
local function decode(raw)
    if not raw or raw == "" then return nil end
    local ok, wire = pcall(JSON.decode, raw)
    if not ok or type(wire) ~= "table" then return nil end
    return wire
end

---@param cookie string
---@param cb fun(ok: boolean, err: string|nil)
---@return HttpJob
function Client.loginCheckAsync(cookie, cb)
    return Request.get(WEB .. "/api/v4/me", opts({ Cookie = cookie, ["User-Agent"] = UA,
        Referer = WEB .. "/signin" }), function(raw, err)
        local user = decode(raw)
        if err or not user or user.error or type(user.id) ~= "string" or user.id == "" then
            cb(false, err and tostring(err) or _("知乎登录校验失败，请在浏览器确认已登录并完成安全验证"))
            return
        end
        cb(true)
    end)
end

---@param keyword string
---@param cb fun(books: Book[]|nil, err: string|nil)
---@return HttpJob
function Client.searchAsync(keyword, cb)
    local url = WEB .. "/api/v4/search_v3?t=km_general&q=" .. Text.urlEncode(keyword)
        .. "&correction=1&offset=0&limit=20&lc_idx=0&show_all_topics=0&search_source=Normal"
    return get(url, { ["X-API-Version"] = "3.0.91", ["X-App-Za"] = "OS=Web" }, function(raw, err)
        local books = Mapper.search(decode(raw))
        if not books then cb(nil, err and tostring(err) or _("请求失败")); return end
        cb(books)
    end)
end

---@param id string 章节 id 或根评论 id
---@param offset integer|string 首页 0，其后原样带回服务端游标
---@param replies boolean
---@param cb fun(page: WechatReviewPage|nil, err: string|nil)
---@return HttpJob
function Client.reviewsAsync(id, offset, replies, cb)
    local path = replies and "/comment/" .. Text.urlEncode(id) .. "/child_comment"
        or "/paid_column_section_manuscripts/" .. Text.urlEncode(id) .. "/root_comment"
    local url = API .. "/comment_v5" .. path .. "?limit=" .. (replies and 5 or 20)
        .. "&order_by=" .. (replies and "ts" or "score") .. "&offset=" .. Text.urlEncode(offset == 0 and "" or offset)
    return get(url, { Referer = WEB .. "/" }, function(raw, err)
        local page = not err and Mapper.reviewPage(decode(raw), offset)
        if not page then cb(nil, err and tostring(err) or _("无法获取段评")); return end
        cb(page)
    end)
end

---@param rank string
---@param filter string
---@param cb fun(books: Book[]|nil, err: string|nil, filters: table[]|nil)
---@return HttpJob
function Client.browseAsync(rank, filter, cb)
    local url = API .. "/km-vip-zhihu-web/vip_tab/svip_story?modules=billboard"
        .. "&billboard_type=" .. Text.urlEncode(rank) .. "&billboard_filter=" .. Text.urlEncode(filter)
        .. "&offset=0&limit=10"
    return get(url, { Referer = WEB .. "/fiore/h5/vip-web" }, function(raw, err)
        local books, filters = Mapper.feed(decode(raw), rank)
        if not books then cb(nil, err and tostring(err) or _("请求失败")); return end
        cb(books, nil, filters)
    end)
end

---@param stable_id string 长篇专栏 id
---@param cb fun(wire: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client.catalogAsync(stable_id, cb)
    local state = { cancelled = false, job = nil }
    local catalog = { data = {} }
    local function fetch(offset)
        local url = API .. "/remix/well/" .. Text.urlEncode(stable_id)
            .. "/catalog?is_new_column=true&order_by=global_idx&limit=50&offset=" .. offset
        local fired = false
        local job = get(url, nil, function(raw, err)
            fired = true
            if state.cancelled then return end
            state.job = nil
            local wire = decode(raw)
            if err or not wire or wire.error or type(wire.data) ~= "table" or type(wire.paging) ~= "table" then
                cb(nil, err and tostring(err) or _("请求失败"))
                return
            end
            if offset == 0 then catalog.extra = wire.extra end
            for _idx, row in ipairs(wire.data) do catalog.data[#catalog.data + 1] = row end
            local paging = wire.paging
            if paging.has_next == true or paging.is_end == false then
                local step = tonumber(paging.limit)
                if #wire.data == 0 or not step or step <= 0 or tonumber(paging.offset) ~= offset then
                    cb(nil, _("请求失败"))
                    return
                end
                fetch(offset + step)
            else
                cb(catalog)
            end
        end)
        if not fired then state.job = job end
    end
    fetch(0)
    return { cancel = function()
        state.cancelled = true
        if state.job and state.job.cancel then state.job.cancel() end
    end }
end

---@param stable_id string 长篇专栏 id
---@param cb fun(book: Book|nil, err: string|nil)
---@return { cancel: fun() }
function Client.detailAsync(stable_id, cb)
    local state = { cancelled = false, job = nil }
    local fetched = false
    local job = get(API .. "/remix/paid_columns/" .. Text.urlEncode(stable_id)
        .. "?is_new_column=true&is_web=true", nil, function(raw, err)
        fetched = true
        if state.cancelled then return end
        state.job = nil
        local wire = decode(raw)
        if not wire then cb(nil, err and tostring(err) or _("请求失败")); return end
        local book = Mapper.detail(wire, stable_id)
        if not book then cb(nil, err and tostring(err) or _("请求失败")); return end
        if type(wire.sku_id) ~= "string" or wire.sku_id == "" then cb(book); return end
        local graded = false
        local rating_job = get(API .. "/darwin/sku_grading/" .. Text.urlEncode(wire.sku_id), nil, function(body, rating_err)
            graded = true
            if state.cancelled then return end
            state.job = nil
            local grading = decode(body)
            if rating_err or not grading or grading.error then
                require("utils.log").warn("zhihu rating fetch failed", rating_err or "invalid response")
                cb(book)
                return
            end
            cb(Mapper.detail(wire, stable_id, grading))
        end)
        if not graded then state.job = rating_job end
    end)
    if not fetched then state.job = job end
    return { cancel = function()
        state.cancelled = true
        if state.job and state.job.cancel then state.job.cancel() end
    end }
end

---@param stable_id string
---@return string|nil
---@return string|nil
local function ids(stable_id)
    return tostring(stable_id):match("^(%d+)/(%d+)$")
end

---@param stable_id string
---@param cb fun(wire: table|nil, err: string|nil)
---@return HttpJob|{ cancel: fun() }
function Client.simpleAsync(stable_id, cb)
    local well, section = ids(stable_id)
    if not well then
        require("ui/uimanager"):nextTick(function() cb(nil, _("请求失败")) end)
        return { cancel = function() end }
    end
    local url = API .. "/remix-web/paid_columns/" .. well .. "/sections/" .. section .. "/manuscript/simple"
    return get(url, nil, function(raw, err)
        local wire = decode(raw)
        if type(wire) ~= "table" or type(wire.section) ~= "table" then
            cb(nil, err and tostring(err) or _("请求失败"))
            return
        end
        cb(wire)
    end)
end

---@param stable_id string
---@param cb fun(wire: table|nil, err: string|nil)
---@return HttpJob|{ cancel: fun() }
function Client.manuscriptAsync(stable_id, cb)
    local well, section = ids(stable_id)
    if not well then
        require("ui/uimanager"):nextTick(function() cb(nil, _("请求失败")) end)
        return { cancel = function() end }
    end
    local path = "/remix-web/paid_columns/" .. well .. "/sections/" .. section
        .. "/manuscript?v=1&manuscript_version=0"
    local headers = Sign.headers(path, Client.cookie())
    headers.Referer = WEB .. "/"
    return get(API .. path, headers, function(raw, err)
        local wire = decode(raw)
        if err or not wire or wire.error then
            cb(nil, err and tostring(err) or _("请求失败")); return
        end
        cb(wire)
    end)
end

--- 只接受未折叠的完整正文，不能把付费预览当成已购章节缓存。
---@param stable_id string
---@param cb fun(html: string|nil, err: string|nil)
---@return { cancel: fun() }
function Client.contentAsync(stable_id, cb)
    local state = { cancelled = false, request = nil, font = nil }
    local fired = false
    local job = Client.manuscriptAsync(stable_id, function(wire, err)
        fired = true
        if state.cancelled then return end
        state.request = nil
        if not wire then cb(nil, err); return end
        if wire.is_fold == true or wire.authentication_result == false then
            cb(nil, _("本章未购买")); return
        end
        if wire.is_fold ~= false or type(wire.manuscript) ~= "string" or wire.manuscript == "" then
            cb(nil, _("请求失败")); return
        end
        if wire.use_font ~= true then cb(wire.manuscript); return end
        local restored = false
        local font_job = require("source.zhihu.font").restoreAsync(wire, function(html, font_err)
            restored = true
            if state.cancelled then return end
            state.font = nil
            cb(html, font_err)
        end)
        if not restored then state.font = font_job end
    end)
    if not fired then state.request = job end
    return { cancel = function()
        state.cancelled = true
        if state.request then state.request.cancel() end
        if state.font then state.font:cancel() end
    end }
end

---@param stable_id string
---@param cb fun(progress: table|nil, err: string|nil, meta: table|nil)
---@return { cancel: fun() }
function Client.progressAsync(stable_id, cb)
    if not Client.cookie() then return require("source.base").defer(cb, nil, _("请先登录知乎")) end
    local cancelled, active = false, nil
    local function readSection(id)
        local fired = false
        local job = Client.manuscriptAsync(id, function(wire, err)
            fired = true
            if cancelled then return end
            active = nil
            if not wire then cb(nil, err); return end
            local progress = Mapper.progress(wire)
            local _column, section = ids(id)
            if not progress or progress.section_id ~= section then cb(nil, _("请求失败")); return end
            if progress.fraction == nil then
                if stable_id:find("/", 1, true) then cb(nil, nil, { empty = true }); return end
                progress.fraction = 0
            end
            cb(progress)
        end)
        if not fired then active = job end
    end
    if ids(stable_id) then
        readSection(stable_id)
    elseif stable_id:match("^%d+$") then
        local fired = false
        local job = get(API .. "/remix/paid_columns/" .. stable_id .. "?is_new_column=true&is_web=true", nil,
            function(raw, err)
                fired = true
                if cancelled then return end
                active = nil
                local wire = decode(raw)
                if err or not wire or wire.error then cb(nil, err and tostring(err) or _("请求失败")); return end
                local section = wire.last_learned_section_id
                if section == nil or section == JSON.null or section == "0" or section == 0 or section == "" then
                    cb(nil, nil, { empty = true }); return
                end
                if type(section) ~= "string" or not section:match("^%d+$") then cb(nil, _("请求失败")); return end
                readSection(stable_id .. "/" .. section)
            end)
        if not fired then active = job end
    else
        return require("source.base").defer(cb, nil, _("请求失败"))
    end
    return { cancel = function()
        cancelled = true
        if active then active.cancel() end
    end }
end

---@param section_id string
---@param fraction number
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return HttpJob|{ cancel: fun() }
function Client.putProgressAsync(section_id, fraction, cb)
    local cookie = Client.cookie()
    if not cookie then return require("source.base").defer(cb, nil, _("请先登录知乎")) end
    if not section_id:match("^%d+$") or fraction ~= fraction or fraction < 0 or fraction > 1 then
        return require("source.base").defer(cb, nil, _("缺少知乎阅读位置"))
    end
    local body = JSON.encode({ {
        unit_id = section_id, type = "paid_column", progress = fraction,
        client_updated_at = os.time() * 1000, is_finished = fraction == 1,
    } })
    return Request.post(API .. "/promus/progress", body, opts(withCookie({
        ["Content-Type"] = "application/json", Referer = WEB .. "/",
    })), function(raw, err, res)
        if res and tonumber(res.code) == 401 and cookie == Client.cookie() then
            cb(nil, require("source.auth").expire("zhihu", _("知乎登录已失效，请重新登录")))
            return
        end
        local wire = decode(raw)
        if err or not wire or wire.error or wire.success ~= true then
            cb(nil, err and tostring(err) or _("请求失败"))
            return
        end
        cb(true)
    end)
end

local function remember(jar, header)
    if type(header) ~= "string" or header == "" then return end
    local name, value = header:match("^%s*([^=;%s]+)=([^;]*)")
    if name then jar[name] = value ~= "" and value ~= '""' and value or nil end
end

local function cookieHeader(jar)
    local names = {}
    for name in pairs(jar) do names[#names + 1] = name end
    table.sort(names)
    if #names == 0 then return nil end
    local parts = {}
    for _idx, name in ipairs(names) do parts[#parts + 1] = name .. "=" .. jar[name] end
    return table.concat(parts, "; ")
end

---@param jar table<string, string>
---@param res table|nil
local function absorb(jar, res)
    for _idx, line in ipairs(Request.headerAll(res, "Set-Cookie")) do remember(jar, line) end
end

---@param wire table|nil
---@param err any
---@return string
local function failMessage(wire, err)
    local detail = type(wire) == "table" and wire.error or nil
    if type(detail) == "table" and tonumber(detail.code) == 40352 then
        return _("知乎需要安全验证，请在网页完成验证后继续扫码登录")
    end
    if type(detail) == "table" and type(detail.message) == "string" and detail.message ~= "" then
        return detail.message
    end
    if type(err) == "string" and err ~= "" then return err end
    return _("登录失败")
end

---@param raw string|nil
---@param res table|nil
---@return table|nil
local function wireOf(raw, res)
    return decode(raw) or decode(res and res.body)
end

local function unexpectedResponse(stage, wire, res)
    local fields = {}
    for _idx, key in ipairs({ "token", "link", "status", "login_status", "cookie", "script", "error" }) do
        fields[#fields + 1] = key .. "=" .. type(wire and wire[key])
    end
    require("utils.log").warn("zhihu login unexpected response", stage,
        "HTTP", res and res.code or "-", "body_bytes",
        res and type(res.body) == "string" and #res.body or 0, table.concat(fields, " "))
    return _("知乎登录响应异常，请重新获取二维码")
end

---@param jar table<string, string>
---@param extra table|nil
---@return table
local function webHeaders(jar, extra)
    extra = extra or {}
    local headers = {
        ["User-Agent"] = UA,
        Accept = "*/*",
        Referer = WEB .. "/signin",
        Origin = WEB,
        ["x-requested-with"] = "fetch",
    }
    local cookie = cookieHeader(jar)
    if cookie then headers.Cookie = cookie end
    if extra.post and jar._xsrf then headers["x-xsrftoken"] = jar._xsrf end
    if extra.path then
        headers["x-zse-93"] = "101_3_3.0"
    end
    return headers
end

---@param session ZhihuQRSession
---@param wire table|nil
---@return ZhihuQRSession|nil
local function verification(session, wire)
    local detail = wire and wire.error
    if type(detail) ~= "table" or tonumber(detail.code) ~= 40352 then return nil end
    local redirect = detail.redirect
    session.challenge_id = type(redirect) == "string" and Text.urlDecode(redirect:match("[?&]session=([^&]+)")) or nil
    return session
end

--- 首页是文档导航，不带接口用的 fetch 头。302 也会下发 sec_token。
---@param jar table<string, string>
---@return table
local function documentHeaders(jar)
    local headers = {
        ["User-Agent"] = UA,
        Accept = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Accept-Language"] = "zh-CN,zh;q=0.9",
    }
    local cookie = cookieHeader(jar)
    if cookie then headers.Cookie = cookie end
    return headers
end

---@param res table|nil
---@return string|nil
local function unhumanPath(res)
    local loc = Request.headerAll(res, "Location")[1]
    if type(loc) ~= "string" or loc == "" then return nil end
    loc = loc:gsub("^https://www%.zhihu%.com", "")
    if not loc:match("^/account/unhuman[?/]") and loc ~= "/account/unhuman" then return nil end
    return loc
end

---@param cb fun(session: ZhihuQRSession|nil, err: string|nil, challenge: ZhihuQRSession|nil)
---@param session ZhihuQRSession|nil 验证后沿用原会话重新出码
---@return { cancel: fun() }
function Client.qrCreateAsync(cb, session)
    session = session or { jar = {} }
    local state = { cancelled = false, job = nil }
    local steps = {
        { path = "/signin", document = true },
        { path = "/udid", body = "{}" },
        { path = "/api/v3/oauth/captcha/v2?type=captcha_sign_in" },
        { path = "/api/v3/account/api/login/qrcode", body = "{}", create = true },
    }
    local function advance(index)
        local step = steps[index]
        if step.create and (not session.jar.d_c0 or not session.jar._xsrf) then
            cb(nil, _("知乎未下发登录会话，请重新获取二维码"))
            return
        end
        local options = {
            headers = step.document and documentHeaders(session.jar)
                or webHeaders(session.jar, { post = step.body ~= nil }),
            content_type = step.body and "application/json;charset=UTF-8" or nil,
            timeout = require("http.timeout").net(1),
        }
        local fired = false
        local function received(raw, err, res)
            fired = true
            if state.cancelled then return end
            state.job = nil
            absorb(session.jar, res)
            local wire = wireOf(raw, res)
            local path = step.path == "/signin" and unhumanPath(res)
            if path and tonumber(res.code) == 302 then
                table.insert(steps, index + 1, { path = path, document = true })
            elseif err or (wire and wire.error) then
                cb(nil, failMessage(wire, err), verification(session, wire))
                return
            end
            if index < #steps then advance(index + 1); return end
            if not wire or type(wire.token) ~= "string" or wire.token == ""
                or type(wire.link) ~= "string" or wire.link == "" then
                cb(nil, unexpectedResponse("create", wire, res))
                return
            end
            session.token = wire.token
            -- 网关会把接口路径追加为查询串；token 已在路径里。
            session.link = wire.link:gsub("%?/api/login/qrcode$", "")
            session.expires_at = tonumber(wire.expires_at)
            cb(session)
        end
        local job
        if step.body then
            job = Request.post(WEB .. step.path, step.body, options, received)
        else
            job = Request.get(WEB .. step.path, options, received)
        end
        if not fired then state.job = job end
    end
    advance(1)
    return { cancel = function()
        state.cancelled = true
        if state.job and state.job.cancel then state.job.cancel() end
    end }
end

--- 轮询结果：ok 已校验并保存；wait / scanned 继续；refresh 换码；expired 过期；nil 失败。
---@param session ZhihuQRSession
---@param cb fun(kind: string|nil, extra: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client.qrPollAsync(session, cb)
    local state = { cancelled = false, job = nil }
    local path = "/api/v3/account/api/login/qrcode/" .. Text.urlEncode(session.token) .. "/scan_info"
    local fired = false
    local job = Request.get(WEB .. path, {
        headers = webHeaders(session.jar, { path = path }),
        timeout = require("http.timeout").net(1),
    }, function(raw, err, res)
        fired = true
        if state.cancelled then return end
        state.job = nil
        absorb(session.jar, res)
        local wire = wireOf(raw, res)
        if err or (wire and wire.error) then
            local challenge = verification(session, wire)
            cb(challenge and "verify" or nil, challenge, failMessage(wire, err))
            return
        end
        if not wire then cb(nil, nil, unexpectedResponse("poll", wire, res)); return end
        remember(session.jar, wire.cookie)
        local status = tonumber(wire.status)
        local login_status = wire.login_status
        local renewed = wire.new_token or wire.newToken
        if login_status == "EXPIRED" or (login_status == nil and status == 5) then
            if type(renewed) == "table" and type(renewed.token) == "string" and renewed.token ~= ""
                and renewed.token ~= session.token and type(renewed.link) == "string" and renewed.link ~= "" then
                session.token = renewed.token
                session.link = renewed.link:gsub("%?/api/login/qrcode$", "")
                session.expires_at = tonumber(renewed.expires_at)
                cb("refresh", session)
            else
                cb("expired")
            end
            return
        end
        local oauth_confirmed = status == nil and type(wire.access_token) == "string" and wire.access_token ~= ""
        if login_status == "CONFIRMED" or (login_status == nil
            and (status == 2 or (status == 1 and session.jar.z_c0) or oauth_confirmed)) then
            if not session.jar.z_c0 then cb(nil, nil, unexpectedResponse("confirm", wire, res)); return end
            local cookie = cookieHeader(session.jar)
            local checked = false
            local check_job = Client.loginCheckAsync(cookie, function(ok, check_err)
                checked = true
                if state.cancelled then return end
                state.job = nil
                if not ok then cb(nil, nil, check_err); return end
                local settings = require("utils.settings")
                settings.getSource(SOURCE_ID).cookie = cookie
                settings.saveSource(SOURCE_ID)
                cb("ok")
            end)
            if not checked then state.job = check_job end
        elseif login_status == "SCANNED" or (login_status == nil and status == 1) then
            cb("scanned")
        elseif login_status == "WAITING" or (login_status == nil and status == 0) then
            cb("wait")
        else
            cb(nil, nil, unexpectedResponse("poll", wire, res))
        end
    end)
    if not fired then state.job = job end
    return { cancel = function()
        state.cancelled = true
        if state.job and state.job.cancel then state.job.cancel() end
    end }
end

---@param session ZhihuQRSession
---@param cb fun(config: { scripts: string[], session_id: string }|nil, err: string|nil)
---@return HttpJob
function Client.qrCaptchaAsync(session, cb)
    return Request.post(CAPTCHA, '{"appId":"' .. CAPTCHA_APP .. '","data":{}}', {
        headers = webHeaders(session.jar),
        content_type = "application/json",
        timeout = require("http.timeout").net(1),
    }, function(raw, err, res)
        absorb(session.jar, res)
        local wire = wireOf(raw, res)
        if err or not wire or wire.error then cb(nil, failMessage(wire, err)); return end
        local scripts = wire.script
        if type(scripts) ~= "table" or #scripts ~= 2
            or scripts[1] ~= "https://cstaticdun.126.net/load.min.js"
            or type(scripts[2]) ~= "string"
            or not scripts[2]:match("^https://captcha%.zhihu%.com/api/v1/captcha/js%?") then
            cb(nil, unexpectedResponse("captcha", wire, res))
            return
        end
        local id = scripts[2]:match("[?&]sessionId=([^&]+)")
        if not id then cb(nil, unexpectedResponse("captcha", wire, res)); return end
        cb({ scripts = scripts, session_id = Text.urlDecode(id) })
    end)
end

---@param session ZhihuQRSession
---@param session_id string 官方挑战标识，只由设备持有
---@param result string 用户完成控件后返回的 JSON 票据
---@param cb fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
function Client.qrVerifyAsync(session, session_id, result, cb)
    local state = { cancelled = false, job = nil }
    local appeal = WEB .. "/api/v4/anticrawl/new_captcha_appeal"
    local steps = {
        { url = CAPTCHA, method = "PUT", body = JSON.encode({
            appId = CAPTCHA_APP, sessionId = session_id, ticket = result,
        }) },
        { url = appeal, method = "POST",
            body = session.challenge_id and JSON.encode({ session = session.challenge_id }) or "{}" },
        { url = appeal .. "?session=" .. Text.urlEncode(session.challenge_id or ""), method = "GET" },
    }
    local function advance(index)
        local step = steps[index]
        local fired = false
        local headers = webHeaders(session.jar, { post = step.method ~= "GET" })
        if step.body then headers["Content-Type"] = "application/json" end
        local job = Request.request({
            url = step.url, method = step.method, body = step.body, headers = headers,
            timeout = require("http.timeout").net(1),
        }, function(res, err)
            fired = true
            if state.cancelled then return end
            state.job = nil
            absorb(session.jar, res)
            local wire = wireOf(nil, res)
            if err or not res or not Request.ok(res.code) or not wire or wire.error then
                cb(false, failMessage(wire, err))
                return
            end
            if index == 1 and wire.success ~= true then cb(false, _("验证失败，请重新验证")); return end
            if index == #steps then
                local ok = wire.code == 0 or wire.block_level == 0
                cb(ok, not ok and _("验证失败，请重新验证") or nil)
                return
            end
            advance(index + 1)
        end)
        if not fired then state.job = job end
    end
    advance(1)
    return { cancel = function()
        state.cancelled = true
        if state.job and state.job.cancel then state.job.cancel() end
    end }
end

return Client
