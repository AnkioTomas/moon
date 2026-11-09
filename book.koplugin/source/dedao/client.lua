--[[--
得到网页接口。

登录可用短信或得到 App 扫码，会话由 Set-Cookie 建立。
短信候选会话归登录窗口所有，不覆盖正在使用的账号。书架是已购电子书。

@module source.dedao.client
--]]

local JSON = require("json")
local Mapper = require("source.dedao.mapper")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("l10n").get("source.dedao")

local Client = {}

local SOURCE_ID = "dedao"
local ORIGIN = "https://www.dedao.cn"
local LOGIN_EXPIRED = "得到登录已失效，请点「重新登录」，用得到 App 扫码。"

local PAGE = {
    density = 1,
    direction = 1,
    font_name = "yahei",
    font_scale = 1,
    font_size = 20,
    height = 1600,
    line_height = "2em",
    margin_bottom = 100,
    margin_left = 90,
    margin_right = 90,
    margin_top = 0,
    paragraph_space = "1em",
    platform = 0,
    width = 900,
}

local jar = {}

--- 同步回调也可能发起下一步，返回较晚的旧句柄不能覆盖它。
local function sequence()
    local state = { serial = 0, cancelled = false }
    function state.cancel()
        state.cancelled = true
        state.serial = state.serial + 1
        if state.job then state.job.cancel() end
        state.job = nil
    end
    function state.run(start, ...)
        if state.cancelled then return end
        state.serial = state.serial + 1
        local serial = state.serial
        state.job = nil
        local job = start(...)
        if state.cancelled then
            if job then job.cancel() end
        elseif state.serial == serial then
            state.job = job
        end
    end
    return state
end

---@param header string|nil
---@param login_jar table<string, string>|nil
local function remember(header, login_jar)
    local target = login_jar or jar
    if type(header) ~= "string" or header == "" then return end
    for part in header:gmatch("[^;]+") do
        local name, value = part:match("^%s*([^=;%s]+)=([^%s].*)$")
        if not name then name, value = part:match("^%s*([^=;%s]+)=(.*)$") end
        if name and value and name ~= "Path" and name ~= "Domain" and name ~= "Expires"
            and name ~= "Max-Age" and name ~= "SameSite" then
            target[name] = value
        end
    end
end

function Client.reset()
    jar = {}
end

function Client.load()
    Client.reset()
    remember(require("utils.settings").getSource(SOURCE_ID).cookie)
end

---@param login_jar table<string, string>|nil
---@return string|nil
function Client.cookie(login_jar)
    local target = login_jar or jar
    local names = {}
    for name in pairs(target) do names[#names + 1] = name end
    table.sort(names)
    if #names == 0 then return nil end
    local parts = {}
    for _idx, name in ipairs(names) do parts[#parts + 1] = name .. "=" .. target[name] end
    return table.concat(parts, "; ")
end

---@return boolean
function Client.loggedIn()
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    return cfg.logged_in == true and cfg.cookie ~= nil and cfg.cookie ~= ""
end

---@param login_jar table<string, string>|nil
function Client.persist(login_jar)
    local settings = require("utils.settings")
    if login_jar then jar = login_jar end
    settings.getSource(SOURCE_ID).cookie = Client.cookie(login_jar)
    settings.saveSource(SOURCE_ID)
end

---@param res table|nil
---@param login_jar table<string, string>|nil
local function absorb(res, login_jar)
    if not res then return end
    for _idx, line in ipairs(Request.headerAll(res, "Set-Cookie")) do remember(line, login_jar) end
end

---@param login_jar table<string, string>|nil
---@return string|nil
local function csrf(login_jar)
    return (login_jar or jar).csrfToken
end

---@param extra table|nil
---@param login_jar table<string, string>|nil
---@return table
local function headers(extra, login_jar)
    local out = {
        ["Xi-DT"] = "web",
        Accept = "application/json",
    }
    local token = csrf(login_jar)
    if token then out["Xi-Csrf-Token"] = token end
    local cookie = Client.cookie(login_jar)
    if cookie then out.Cookie = cookie end
    for key, value in pairs(extra or {}) do out[key] = value end
    return out
end

---@param wire table
---@param authed boolean
---@return table|nil
---@return string|nil
local function payload(wire, authed)
    local head = type(wire.h) == "table" and wire.h or nil
    local code = tonumber(head and head.c or wire.errCode)
    if not code then return nil, _("响应无效") end
    if code ~= 0 then
        if authed and code == 401 then
            return nil, require("source.auth").expire(SOURCE_ID, _(LOGIN_EXPIRED))
        end
        local message = head and head.e
        return nil, type(message) == "string" and message ~= "" and message or _("请求失败")
    end
    if authed and code == 0 then require("source.auth").ok(SOURCE_ID) end
    if wire.c ~= nil then return wire.c end
    return wire
end

---@param method string
---@param path string
---@param body string|nil
---@param extra table|nil
---@param content_type string|nil
---@param cb fun(body: any, err: string|nil, res: table|nil)
---@param login_jar table<string, string>|nil
---@return HttpJob
local function call(method, path, body, extra, content_type, cb, login_jar)
    local url = path:find("^https?://") and path or ORIGIN .. path
    local target = login_jar or jar
    local account_cookie = not login_jar and require("utils.settings").getSource(SOURCE_ID).cookie
    local opts = {
        accept = "application/json",
        headers = headers(extra, target),
        timeout = require("http.timeout").net(),
    }
    if content_type then opts.content_type = content_type end
    local function done(raw, err, res)
        absorb(res, target)
        local authed = not login_jar and Client.loggedIn()
            and account_cookie == require("utils.settings").getSource(SOURCE_ID).cookie
        if authed and res and tonumber(res.code) == 401 then
            cb(nil, require("source.auth").expire(SOURCE_ID, _(LOGIN_EXPIRED)), res)
            return
        end
        if not raw then
            local message = err and tostring(err):lower() or ""
            local timed_out = message:find("timeout", 1, true) or message:find("timed out", 1, true)
            require("utils.log").warn("dedao request failed", method, path:match("^[^?]+"),
                timed_out and "timeout" or "network_error", "timeout_seconds", opts.timeout,
                "status", res and tonumber(res.code))
            cb(nil, err and tostring(err) or _("请求失败"), res)
            return
        end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok or type(wire) ~= "table" then cb(nil, _("响应无效"), res); return end
        local data, reason = payload(wire, authed)
        cb(data, reason, res)
    end
    if method == "POST" then return Request.post(url, body, opts, done) end
    return Request.get(url, opts, done)
end

---@param cb fun(ok: boolean|nil, err: string|nil)
---@param login_jar table<string, string>|nil
---@return HttpJob
function Client.bootstrapAsync(cb, login_jar)
    if not login_jar then Client.load() end
    if csrf(login_jar) then return require("source.base").defer(cb, true) end
    local target = login_jar or jar
    return Request.get(ORIGIN .. "/", {
        headers = headers(nil, target),
        accept = "text/html",
        timeout = require("http.timeout").net(),
    }, function(_raw, err, res)
        absorb(res, target)
        if not csrf(target) then cb(nil, err and tostring(err) or _("请求失败")); return end
        if not login_jar and target == jar then Client.persist() end
        cb(true)
    end)
end

---@param cb fun(token: string|nil, err: string|nil)
---@param login_jar table<string, string>|nil
---@return { cancel: fun() }
function Client.accessTokenAsync(cb, login_jar)
    local handle = sequence()
    handle.run(Client.bootstrapAsync, function(ok, err)
        if handle.cancelled then return end
        if not ok then cb(nil, err); return end
        handle.run(Request.post, ORIGIN .. "/loginapi/getAccessToken", "", {
            headers = headers(nil, login_jar),
            accept = "application/json",
            content_type = "application/json",
            timeout = require("http.timeout").net(0.5),
        }, function(raw, reason, res)
            if handle.cancelled then return end
            absorb(res, login_jar)
            if not raw then cb(nil, reason and tostring(reason) or _("获取二维码失败")); return end
            local decoded, wire = pcall(JSON.decode, raw)
            local token = decoded and wire or Text.trim(raw)
            if type(token) == "table" then
                local data, err = payload(token, false)
                reason = err
                token = type(data) == "table" and data.token or data
            end
            if type(token) ~= "string" or token == "" then cb(nil, reason or _("获取二维码失败")); return end
            cb(token)
        end)
    end, login_jar)
    return handle
end

---@class DedaoSMSLoginSession
---@field current fun(): boolean 本次登录尝试仍属于当前账号
---@field oauth string
---@field jar table<string, string>
---@field phone string
---@class DedaoSMSChallenge
---@field session DedaoSMSLoginSession
---@field captcha_id string

---@param session DedaoSMSLoginSession
---@param captcha table|nil
---@param cb fun(ok: boolean|nil, err: string|nil, captcha_id: string|nil)
function Client.sendSessionCodeAsync(session, captcha, cb)
    return call("POST", "/oauth/api/embedded/auth_code/send", JSON.encode({
        areaCode = "86", phone = session.phone, sysCode = "4", pname = "", scene = "", captcha = captcha,
    }), { ["X-Oauth-Access-Token"] = session.oauth }, "application/json", function(body, err)
        local data = type(body) == "table" and body.data or nil
        if type(data) ~= "table" then cb(nil, err or _("发送验证码失败")); return end
        if data.needCaptcha then
            if type(data.captchaId) ~= "string" or data.captchaId == "" then
                cb(nil, _("响应无效"))
                return
            end
            cb(nil, nil, data.captchaId)
            return
        end
        cb(true)
    end, session.jar)
end

---@param phone string
---@param cb fun(session: DedaoSMSLoginSession|nil, err: string|nil, challenge: DedaoSMSChallenge|nil)
---@return { cancel: fun() }
function Client.sendCodeAsync(phone, cb)
    local current = require("source.auth").beginLogin(SOURCE_ID)
    local login_jar = {}
    local handle = sequence()
    handle.run(Client.accessTokenAsync, function(token, err)
        if handle.cancelled then return end
        if not current() then cb(nil, _("账号已变化，请重新登录")); return end
        if not token then cb(nil, err); return end
        local session = { oauth = token, jar = login_jar, phone = phone, current = current }
        handle.run(Client.sendSessionCodeAsync, session, nil, function(ok, reason, captcha_id)
            if handle.cancelled then return end
            if not current() then cb(nil, _("账号已变化，请重新登录")); return end
            if captcha_id then
                cb(nil, nil, { session = session, captcha_id = captcha_id })
                return
            end
            if not ok then cb(nil, reason); return end
            cb(session)
        end)
    end, login_jar)
    return handle
end

---@param login_jar table<string, string>
---@param cb fun(user: table|nil, err: string|nil)
function Client.checkLoginAsync(login_jar, cb)
    return call("GET", "/api/pc/user/info", nil, nil, nil, function(user, reason)
        if type(user) ~= "table" or type(user.uid_hazy) ~= "string" or user.uid_hazy == "" then
            cb(nil, reason or _("登录失败"))
            return
        end
        cb(user)
    end, login_jar)
end

---@param login_jar table<string, string>
---@param cb fun(ok: boolean|nil, err: string|nil)
---@param current (fun(): boolean)|nil
function Client.confirmLoginAsync(login_jar, cb, current)
    current = current or require("source.auth").beginLogin(SOURCE_ID)
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    local previous, previous_uid = cfg.cookie, cfg.uid
    return Client.checkLoginAsync(login_jar, function(user, reason)
        if not current() or cfg.cookie ~= previous or cfg.uid ~= previous_uid then
            cb(nil, _("账号已变化，请重新登录")); return
        end
        if not user then cb(nil, reason); return end
        if (cfg.uid or cfg.cookie or cfg.logged_in) and cfg.uid ~= user.uid_hazy then
            local cleared = require("source.logout").clear(SOURCE_ID, function()
                cfg.cookie, cfg.uid, cfg.logged_in = nil, nil, nil
                require("utils.settings").saveSource(SOURCE_ID)
                Client.reset()
            end)
            if not cleared then cb(nil, _("准备本地同步失败")); return end
        end
        cfg.uid, cfg.logged_in = user.uid_hazy, true
        Client.persist(login_jar)
        cb(true)
    end)
end

---@param session DedaoSMSLoginSession
---@param code string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Client.smsLoginAsync(session, code, cb)
    local handle = sequence()
    handle.run(call, "POST", "/oauth/api/embedded/auth_code/check", JSON.encode({
        code = code, autoRegister = true, withUser = false, channelType = "iget_web",
        authByGW = true, expireTime = "2592000",
    }), { ["X-Oauth-Access-Token"] = session.oauth }, "application/json", function(body, err)
        if handle.cancelled then return end
        local data = type(body) == "table" and body.data or nil
        if type(data) ~= "table" then cb(nil, err or _("登录失败")); return end
        if type(data.errorMessage) == "string" and data.errorMessage ~= "" then cb(nil, data.errorMessage); return end
        handle.run(Client.confirmLoginAsync, session.jar, function(ok, reason)
            if not handle.cancelled then cb(ok, reason) end
        end, session.current)
    end, session.jar)
    return handle
end

---@param oauth string
---@param cb fun(code: string|nil, err: string|nil)
---@return HttpJob
function Client.qrCreateAsync(oauth, cb, login_jar)
    return call("GET", "/oauth/api/embedded/qrcode", nil, { ["X-Oauth-Access-Token"] = oauth }, nil, function(body, err)
        local data = type(body) == "table" and body.data or nil
        local code = type(data) == "table" and data.qrCodeString or nil
        if type(code) ~= "string" or code == "" then cb(nil, err or _("获取二维码失败")); return end
        cb(code)
    end, login_jar)
end

---@param oauth string
---@param code string
---@param cb fun(wire: table|nil, err: string|nil)
---@return HttpJob
function Client.qrPollAsync(oauth, code, cb, login_jar)
    return call("POST", "/oauth/api/embedded/qrcode/check_login", JSON.encode({
        qrCode = code, keepLogin = true,
    }), { ["X-Oauth-Access-Token"] = oauth }, "application/json", function(body, err)
        if type(body) ~= "table" or body.data == nil then cb(nil, err or _("请求失败")); return end
        cb(body, err)
    end, login_jar)
end

local function authed(cb)
    Client.load()
    if Client.loggedIn() then return nil end
    return require("source.base").defer(cb, nil, _("未登录得到"))
end

---@param cb fun(body: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:shelfSyncAsync(cb)
    local denied = authed(cb)
    if denied then return denied end
    local handle, rows, seen = sequence(), {}, {}
    local function nextPage(page)
        handle.run(call, "POST", "/api/hades/v2/product/list", JSON.encode({
            category = "ebook",
            display_group = true,
            filter = "all",
            filter_complete = 0,
            group_id = 0,
            order = "study",
            page = page,
            page_size = 18,
            sort_type = "desc",
        }), nil, "application/json", function(body, err)
            if handle.cancelled then return end
            if type(body) ~= "table" or type(body.list) ~= "table" then cb(nil, err or _("响应无效")); return end
            local added = 0
            for _idx, row in ipairs(body.list) do
                if type(row) ~= "table" or type(row.enid) ~= "string" or row.enid == "" then
                    cb(nil, _("响应无效"))
                    return
                end
                if not seen[row.enid] then
                    seen[row.enid] = true
                    rows[#rows + 1], added = row, added + 1
                end
            end
            if body.is_more == true or body.is_more == 1 then
                if added == 0 then cb(nil, _("响应无效")); return end
                nextPage(page + 1)
                return
            end
            cb({ list = rows, is_more = false })
        end)
    end
    nextPage(1)
    return handle
end

---@param stable_id string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return HttpJob|{ cancel: fun() }
function Client:addToShelfAsync(stable_id, cb)
    local denied = authed(cb)
    if denied then return denied end
    return call("POST", "/api/pc/ebook2/v1/bookshelf/add", JSON.encode({
        book_enids = { stable_id }, ptype = 2,
    }), nil, "application/json", function(body, err)
        local result = type(body) == "table" and (body.data or body) or nil
        local count = type(result) == "table" and tonumber(result.n) or nil
        if not count or count <= 0 then cb(nil, err or _("请求失败")); return end
        cb(true)
    end)
end

---@param stable_id string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return HttpJob|{ cancel: fun() }
function Client:removeFromShelfAsync(stable_id, cb)
    local denied = authed(cb)
    if denied then return denied end
    return call("POST", "/api/pc/hades/v1/product/pcremove", JSON.encode({
        data = { { pid = stable_id, ptype = 2 } },
    }), nil, "application/json", function(body, err)
        local result = type(body) == "table" and (body.data or body) or nil
        local count = type(result) == "table" and tonumber(result.n) or nil
        if not count or count < 0 then cb(nil, err or _("请求失败")); return end
        cb(true)
    end)
end

---@param keyword string
---@param cb fun(body: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client.searchAsync(keyword, cb, page)
    local handle = sequence()
    handle.run(Client.bootstrapAsync, function(ok, err)
        if handle.cancelled then return end
        if not ok then cb(nil, err); return end
        handle.run(call, "POST", "/api/search/pc/tophits", JSON.encode({
            content = keyword, page = page or 1, page_size = 20, search_type = 0, tab_type = 2,
        }), nil, "application/json", function(body, reason)
            if handle.cancelled then return end
            if type(body) ~= "table" or type(body.data) ~= "table" or type(body.data.moduleList) ~= "table" then
                cb(nil, reason or _("响应无效"))
                return
            end
            cb(body)
        end)
    end)
    return handle
end

---@param stable_id string
---@param cb fun(body: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client.detailAsync(stable_id, cb)
    local handle = sequence()
    handle.run(Client.bootstrapAsync, function(ok, err)
        if handle.cancelled then return end
        if not ok then cb(nil, err); return end
        handle.run(call, "GET", "/pc/ebook2/v1/pc/detail?" .. Text.formEncode({ id = stable_id, ptype = 2 }), nil, nil, nil, function(body, reason)
            if not handle.cancelled then cb(body, reason) end
        end)
    end)
    return handle
end

---@param stable_id string
---@param cb fun(token: string|nil, err: string|nil)
---@return HttpJob|{ cancel: fun() }
function Client.readTokenAsync(stable_id, cb)
    local denied = authed(cb)
    if denied then return denied end
    return call("POST", "/api/pc/ebook2/v1/pc/read/token", JSON.encode({ id = stable_id }), nil, "application/json", function(body, err)
        local token = type(body) == "table" and body.token or nil
        if type(token) ~= "string" or token == "" then cb(nil, err or _("请求失败")); return end
        cb(token)
    end)
end

---@param stable_id string
---@param cb fun(info: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client.bookInfoAsync(stable_id, cb)
    local handle = sequence()
    handle.run(Client.readTokenAsync, stable_id, function(token, err)
        if handle.cancelled then return end
        if not token then cb(nil, err); return end
        handle.run(call, "GET", "/ebk_web/v1/get_book_info?" .. Text.formEncode({ token = token }), nil, nil, nil, function(body, reason)
            if not handle.cancelled then cb(body, reason) end
        end)
    end)
    return handle
end

---@param token string
---@param chapter_id string
---@param index integer
---@param cb fun(body: table|nil, err: string|nil)
---@return HttpJob
local function pages(token, chapter_id, index, cb)
    return call("POST", "/ebk_web_go/v2/get_pages", JSON.encode({
        chapter_id = chapter_id,
        config = PAGE,
        count = 20,
        index = index,
        offset = 0,
        orientation = 0,
        token = token,
    }), nil, "application/json", cb)
end

---@param stable_id string
---@param chapter_id string
---@param cb fun(text: string|nil, err: string|nil, kind: "unpaid"|nil)
---@return { cancel: fun() }
function Client.contentAsync(stable_id, chapter_id, cb)
    local handle = sequence()
    handle.run(Client.readTokenAsync, stable_id, function(token, err)
        if handle.cancelled then return end
        if not token then cb(nil, err); return end
        local parts = {}
        local function nextIndex(index, guard)
            if guard > 40 then cb(nil, _("响应无效")); return end
            handle.run(pages, token, chapter_id, index, function(body, reason)
                if handle.cancelled then return end
                if type(body) ~= "table" then
                    if reason == "user no legal!" then cb(nil, _("本章未购买"), "unpaid"); return end
                    cb(nil, reason or _("响应无效"))
                    return
                end
                local list = body.pages
                if type(list) ~= "table" then cb(nil, _("响应无效")); return end
                for _idx, page in ipairs(list) do
                    local text = type(page) == "table" and Mapper.pageText(page.svg) or nil
                    if text == nil then cb(nil, _("响应无效")); return end
                    if text ~= "" then parts[#parts + 1] = text end
                end
                local last = list[#list]
                if body.is_end == true or (type(last) == "table" and last.is_last == true) then
                    if #parts == 0 then cb(nil, _("响应无效")); return end
                    cb(table.concat(parts, "\n\n"))
                    return
                end
                if #list == 0 then cb(nil, _("响应无效")); return end
                nextIndex(index + #list, guard + 1)
            end)
        end
        nextIndex(0, 1)
    end)
    return handle
end

---@param query table
---@param cb fun(body: table|nil, err: string|nil)
function Client.browseFiltersAsync(query, cb)
    local handle = sequence()
    handle.run(Client.bootstrapAsync, function(ok, err)
        if handle.cancelled then return end
        if not ok then cb(nil, err); return end
        handle.run(call, "POST", "/pc/label/v2/algo/pc/filter/list", JSON.encode(query), nil, "application/json", function(body, reason)
            if not handle.cancelled then cb(body, reason) end
        end)
    end)
    return handle
end

---@param query table
---@param page integer
---@param cb fun(body: table|nil, err: string|nil)
function Client.browsePageAsync(query, page, cb)
    local data = {}
    for key, value in pairs(query) do data[key] = value end
    data.page = page - 1
    return call("POST", "/pc/label/v2/algo/pc/product/list", JSON.encode(data), nil, "application/json", cb)
end

---@param stable_id string
---@param cb fun(body: table|nil, err: string|nil)
function Client.reviewsAsync(stable_id, cb)
    local handle = sequence()
    handle.run(Client.bootstrapAsync, function(ok, err)
        if handle.cancelled then return end
        if not ok then cb(nil, err); return end
        local rows, seen = {}, {}
        local function nextPage(page)
            handle.run(call, "POST", "/pc/ebook2/v1/comment/list", JSON.encode({
                enid = stable_id, page = page, page_size = 20, sort = "like_count", ptype = 2,
            }), nil, "application/json", function(body, reason)
                if handle.cancelled then return end
                local total = type(body) == "table" and tonumber(body.total) or nil
                if not total or total < 0 or type(body.list) ~= "table" then
                    cb(nil, reason or _("响应无效"))
                    return
                end
                local added = 0
                for _idx, row in ipairs(body.list) do
                    if type(row) ~= "table" or type(row.note_id_hazy) ~= "string" then
                        cb(nil, _("响应无效"))
                        return
                    end
                    if not seen[row.note_id_hazy] then
                        seen[row.note_id_hazy] = true
                        rows[#rows + 1], added = row, added + 1
                    end
                end
                if #rows < math.min(total, 60) then
                    if added == 0 then cb(nil, _("响应无效")); return end
                    nextPage(page + 1)
                    return
                end
                cb({ list = rows, total = total })
            end)
        end
        nextPage(1)
    end)
    return handle
end

---@param stable_id string
---@param cb fun(item: table|nil, err: string|nil)
---@return HttpJob|{ cancel: fun() }
function Client.progressAsync(stable_id, cb)
    local denied = authed(cb)
    if denied then return denied end
    return call("POST", "/api/pc/ebook2/v1/pc/getread", JSON.encode({ id = stable_id }), nil, "application/json", function(body, err)
        if type(body) ~= "table" then cb(nil, err); return end
        cb(body.data or body)
    end)
end

---@param stable_id string
---@param chapter_id string
---@param summary string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return HttpJob|{ cancel: fun() }
function Client.putProgressAsync(stable_id, chapter_id, summary, cb)
    local denied = authed(cb)
    if denied then return denied end
    return call("POST", "/api/pc/ebook2/v1/pc/addread", JSON.encode({
        findex = chapter_id, windex = 0, id = stable_id, summary = summary,
    }), nil, "application/json", function(body, err)
        cb(body and true or nil, err)
    end)
end

return Client
