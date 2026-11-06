--[[--
书旗网页接口。

搜索、分类、目录、免费正文不登录。登录是手机验证码，滑块参数由远程页交回。
书架是一次书签同步，没有单独的增删接口。

@module source.shuqi.client
--]]

require("l10n").apply()
local JSON = require("json")
local Mapper = require("source.shuqi.mapper")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("gettext")

local Client = {}

local SOURCE_ID = "shuqi"
local NOVEL = "https://read.xiaoshuo1-sm.com/novel/i.php"
local CONTENT = "https://content.shuqireader.com"
local OCEAN = "https://ocean.shuqireader.com"
local BOOKMARK = "https://jbookmark.shuqireader.com/api/v1/sync/bookmarks"
local ANON_USER = "8000000"

local env = {}

function Client.reset()
    env = {}
end

function Client.load()
    Client.reset()
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    env.token = cfg.token
    env.user_id = cfg.user_id
    env.imei = cfg.imei
    env.umidtoken = cfg.umidtoken
    env.wua = cfg.wua
end

---@return boolean
function Client.loggedIn()
    if not env.token then Client.load() end
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    return cfg.logged_in == true and type(cfg.token) == "string" and cfg.token ~= ""
end

---@param session { token: string, user_id: string|nil, name: string }
---@param browser { fingerprint: string|nil, umidtoken: string|nil, wua: string|nil }|nil
function Client.persist(session, browser)
    local settings = require("utils.settings")
    local cfg = settings.getSource(SOURCE_ID)
    cfg.token = session.token
    cfg.user_id = session.user_id
    cfg.name = session.name
    cfg.logged_in = true
    if browser then
        cfg.imei = browser.fingerprint
        cfg.umidtoken = browser.umidtoken
        cfg.wua = browser.wua
    end
    settings.saveSource(SOURCE_ID)
    Client.load()
end

---@param cb fun(wire: table|nil, err: string|nil)
local function decode(cb)
    return function(raw, err)
        if not raw or raw == "" then cb(nil, err and tostring(err) or _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok or type(wire) ~= "table" then cb(nil, _("请求失败")); return end
        cb(wire)
    end
end

---@return table
local function opts()
    return {
        accept = "application/json",
        headers = { Accept = "application/json", Referer = "https://t.shuqi.com/" },
        timeout = require("http.timeout").net(1),
    }
end

---@param url string
---@param cb fun(wire: table|nil, err: string|nil)
local function get(url, cb)
    return Request.get(url, opts(), decode(cb))
end

---@param book_id string
---@return string timestamp
---@return table fields
local function contentFields(book_id)
    if env.token == nil then Client.load() end
    local timestamp = tostring(os.time())
    local user_id = env.user_id
    if type(user_id) ~= "string" or user_id == "" then user_id = ANON_USER end
    return timestamp, { user_id = user_id, bookId = book_id, timestamp = timestamp }
end

---@param keyword string
---@param cb fun(books: Book[]|nil, err: string|nil)
---@return HttpJob
function Client.searchAsync(keyword, cb)
    local timestamp = tostring(os.time())
    local url = NOVEL .. "?" .. Text.formEncode({
        ["do"] = "is_search",
        userId = ANON_USER,
        platform = "3",
        p = "3",
        q = keyword,
        page = "1",
        size = "20",
        filterMigu = "1",
        ver = "",
        timestamp = timestamp,
        sign = Mapper.searchSign(timestamp),
    })
    return get(url, function(wire, err)
        if not wire then cb(nil, err); return end
        local books, reason = Mapper.searchBooks(wire)
        if not books then cb(nil, reason or _("请求失败")); return end
        cb(books)
    end)
end

---@param cb fun(wire: table|nil, err: string|nil)
---@return HttpJob
function Client.categoriesAsync(cb)
    local timestamp = tostring(os.time())
    local url = CONTENT .. "/openapi/rankv2/class?" .. Text.formEncode({
        user_Id = ANON_USER,
        timestamp = timestamp,
        imei = "",
        sn = "",
        tk = "",
        platform = "3",
        p = "3",
        sign = Mapper.rankSign(timestamp),
    })
    return get(url, cb)
end

---@param tag string|nil
---@param cb fun(books: Book[]|nil, err: string|nil)
---@return HttpJob
function Client.rankAsync(tag, cb)
    local timestamp = tostring(os.time())
    local query = {
        ["do"] = "is_caterank",
        userId = ANON_USER,
        platform = "3",
        p = "3",
        page = "1",
        size = "20",
        filterMigu = "1",
        timestamp = timestamp,
        sign = Mapper.rankSign(timestamp),
    }
    if type(tag) == "string" and tag ~= "" then query.tag = tag end
    return get(NOVEL .. "?" .. Text.formEncode(query), function(wire, err)
        if not wire then cb(nil, err); return end
        local books, reason = Mapper.searchBooks(wire)
        if not books then cb(nil, reason or _("请求失败")); return end
        cb(books)
    end)
end

---@param book_id string
---@param cb fun(book: Book|nil, err: string|nil)
---@return HttpJob
function Client.detailAsync(book_id, cb)
    local _timestamp, fields = contentFields(book_id)
    fields.sign = Mapper.contentSign(fields)
    fields.platform = "0"
    return Request.post(CONTENT .. "/openapi/book/info", Text.formEncode(fields), opts(), function(raw, err)
        if not raw or raw == "" then cb(nil, err and tostring(err) or _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, raw)
        local book = ok and Mapper.detail(wire) or nil
        if not book then cb(nil, _("请求失败")); return end
        cb(book)
    end)
end

---@param book_id string
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
---@return HttpJob
function Client.chaptersAsync(book_id, cb)
    local _timestamp, fields = contentFields(book_id)
    fields.sign = Mapper.contentSign(fields)
    fields.platform = "0"
    local url = CONTENT .. "/openapi/book/chapterlist?" .. Text.formEncode(fields)
    return get(url, function(wire, err)
        if not wire then cb(nil, err); return end
        local toc = Mapper.chapters(wire)
        if not toc then cb(nil, _("请求失败")); return end
        cb(toc)
    end)
end

---@param url string|nil
---@param cb fun(text: string|nil, err: string|nil)
---@return HttpJob|nil
function Client.contentAsync(url, cb)
    if type(url) ~= "string" or url == "" then cb(nil, _("本章未购买")); return nil end
    return get(url, function(wire, err)
        if not wire then cb(nil, err); return end
        local text, reason = Mapper.chapterText(wire)
        if not text then cb(nil, reason and _(reason) or _("请求失败")); return end
        cb(text)
    end)
end

---@param fields table
---@return string
local function gatewayBody(fields)
    fields.sign = Mapper.gatewaySign(fields)
    fields.key = "sq_h5_gateway"
    return Text.formEncode(fields)
end

--- 发送登录短信。手机号只在设备上，滑块字符串由远程页交回。
---@param phone string
---@param captcha string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return HttpJob
function Client.sendCodeAsync(phone, captcha, cb)
    local timestamp = tostring(os.time())
    local fields = {
        mobile = phone,
        captcha = captcha,
        aliyunCheck = "1",
        type = "1010",
        userId = ANON_USER,
        platform = "0",
        appVer = "",
        placeId = "",
        timestamp = timestamp,
        sqSv = "1.0",
        _public = Text.formEncode({
            platform = "0",
            priority = "code",
            redirect_uri = "https://t.shuqi.com/myself",
        }),
    }
    return Request.post(OCEAN .. "/api/jaccount/sso/captcha/sendCode", gatewayBody(fields), opts(), function(raw, err)
        if not raw or raw == "" then cb(nil, err and tostring(err) or _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok then cb(nil, _("请求失败")); return end
        local sent, reason = Mapper.sent(wire)
        if not sent then cb(nil, reason or _("请求失败")); return end
        cb(true)
    end)
end

--- 验证码登录。browser 是远程页带回来的设备指纹，没有就空着。
---@param phone string
---@param code string
---@param browser { fingerprint: string|nil, umidtoken: string|nil, wua: string|nil }|nil
---@param cb fun(session: table|nil, err: string|nil)
---@return HttpJob
function Client.loginAsync(phone, code, browser, cb)
    local mark = browser or {}
    local fingerprint = type(mark.fingerprint) == "string" and mark.fingerprint or ""
    local fields = {
        imei = fingerprint,
        sn = fingerprint,
        umidtoken = type(mark.umidtoken) == "string" and mark.umidtoken or "",
        wua = type(mark.wua) == "string" and mark.wua or "",
        timestamp = tostring(os.time()),
        sqSv = "1.0",
        platform = "0",
        mobile = phone,
        vcode = code,
        loginToken = "",
        pageSource = "",
        appName = "sqH5",
        agent = "chrome",
    }
    return Request.post(OCEAN .. "/api/jaccount/sso/vcode/login", gatewayBody(fields), opts(), function(raw, err)
        if not raw or raw == "" then cb(nil, err and tostring(err) or _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok then cb(nil, _("登录失败")); return end
        local session, reason = Mapper.session(wire)
        if not session then cb(nil, reason or _("登录失败")); return end
        if not session.user_id then cb(nil, _("书旗账号缺少用户编号")); return end
        Client.persist(session, mark)
        cb(session)
    end)
end

---@param bookmark table[]
---@param cb fun(books: Book[]|nil, err: string|nil, wire: table|nil)
---@return HttpJob|nil
local function syncAsync(bookmark, cb)
    if not Client.loggedIn() then cb(nil, _("未登录书旗")); return nil end
    if type(env.user_id) ~= "string" or env.user_id == "" then
        cb(nil, _("书旗账号缺少用户编号"))
        return nil
    end
    -- 页面把 user.id 按数字放进 data.userid。字符串对不上账号，同步回空书架。
    -- 空表会被编成 {}。书签接口认 bookmark 是数组，对象的话直接回空书架。
    local marks = bookmark
    if JSON.util and JSON.util.InitArray then marks = JSON.util.InitArray(bookmark) end
    local data = JSON.encode({
        userid = tonumber(env.user_id) or env.user_id,
        t = os.time(),
        get_data = "1",
        bookmark = marks,
        coverType = "0",
        client_bid_set = {},
        placeid = "",
    })
    local body = Text.formEncode({
        platform = "0",
        imei = env.imei or "",
        sn = env.imei or "",
        tk = env.token,
        user_id = env.user_id,
        data = data,
    })
    local url = BOOKMARK .. "?" .. Text.formEncode({ ["_"] = tostring(os.time()), nom9 = "1" })
    return Request.post(url, body, opts(), function(raw, err)
        if not raw or raw == "" then
            cb(nil, err and tostring(err) or _("书旗登录已失效，请点「重新登录」，用手机验证码登录。"))
            return
        end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok then cb(nil, _("请求失败")); return end
        local books, reason = Mapper.shelf(wire)
        if not books then cb(nil, reason or _("书旗登录已失效，请点「重新登录」，用手机验证码登录。")); return end
        cb(books, nil, wire)
    end)
end

---@param cb fun(books: Book[]|nil, err: string|nil)
---@return HttpJob|nil
function Client.shelfAsync(cb)
    return syncAsync({}, cb)
end

---@param stable_id string
---@param action integer
---@param extra { title: string|nil, author: string|nil, cover: string|nil }|nil
---@param cb fun(ok: boolean|nil, err: string|nil)
local function changeAsync(stable_id, action, extra, cb)
    -- 页面 add_time 是 13 位毫秒，last_update 是秒字符串，书签行带书名。
    local now_ms = os.time() * 1000
    local row = {
        bid = tonumber(stable_id) or stable_id,
        action = action,
        percent = 0,
        source = 1,
        offset = 0,
        state = "",
        offsetType = "",
        add_time = now_ms,
        last_update = tostring(os.time()),
    }
    if type(extra) == "table" then
        if type(extra.title) == "string" and extra.title ~= "" then row.title = extra.title end
        if type(extra.author) == "string" and extra.author ~= "" then row.author = extra.author end
        if type(extra.cover) == "string" and extra.cover ~= "" then row.cover = extra.cover end
    end
    return syncAsync({ row }, function(books, err)
        if not books then cb(nil, err or (action == 3 and _("移出书旗书架失败") or _("加入书旗书架失败"))); return end
        cb(true)
    end)
end

---@param stable_id string
---@param cb fun(ok: boolean|nil, err: string|nil)
function Client.addAsync(stable_id, cb)
    return Client.detailAsync(stable_id, function(book)
        local extra = nil
        if book then
            extra = { title = book.title, author = book.authors, cover = book.cover }
        end
        changeAsync(stable_id, 1, extra, cb)
    end)
end

---@param stable_id string
---@param cb fun(ok: boolean|nil, err: string|nil)
function Client.removeAsync(stable_id, cb)
    return changeAsync(stable_id, 3, nil, cb)
end

--- 阅读位置和书架是同一条书签。拉取是空书签同步，按 bid 取 chapterid。
---@param stable_id string
---@param cb fun(mark: { chapter_id: string, title: string|nil, fraction: number }|nil, err: string|nil)
---@return HttpJob|nil
function Client.progressAsync(stable_id, cb)
    return syncAsync({}, function(books, err, wire)
        if not books then cb(nil, err); return end
        cb(Mapper.mark(wire, stable_id))
    end)
end

--- 更新阅读位置用 action 2。percent 是万分比，和网页 `(章序 / 总章数) * 10000` 一致。
--- 加入书架仍是 action 1，那时候还没有章节位置。
---@param stable_id string
---@param chapter_id string
---@param title string|nil
---@param fraction number
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return HttpJob|nil
function Client.putProgressAsync(stable_id, chapter_id, title, fraction, cb)
    local now = os.time() * 1000
    local percent = math.floor((tonumber(fraction) or 0) * 10000 + 0.5)
    if percent < 1 then percent = 1 end
    if percent > 10000 then percent = 10000 end
    local row = {
        bid = tonumber(stable_id) or stable_id,
        action = 2,
        percent = percent,
        source = 1,
        offset = 0,
        state = "",
        chapterid = tonumber(chapter_id) or chapter_id,
        cname = title or "",
        add_time = now,
        last_update = now,
    }
    return syncAsync({ row }, function(books, err)
        if not books then cb(nil, err or _("书旗进度保存失败")); return end
        cb(true)
    end)
end

return Client
