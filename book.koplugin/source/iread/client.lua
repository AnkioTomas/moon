--[[--
iRead（iread.ankio.net）HTTP 客户端（仅异步）。

鉴权是个人 Token（`Authorization: Bearer <64 位十六进制>`，在网站「个人 Token」页创建）；接口一律 POST 表单，
回包是 `{ code, msg, data }`，`code == 200` 才算成功。注意服务端对无效 Token 不报 401，而是当游客处理，
所以书架为空时要另调 /user/home 确认登录态，免得把「Token 失效」当成「书架被清空」。

书架行（BookDetailModel）就是服务端的书记录：章节、正文、进度接口都要把整行原样带回去，
所以这里的请求都以书架行为参数。

@module koplugin.book.source.iread.client
--]]

local JSON = require("json")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("l10n").get("source.iread")

local Client = {}

local SOURCE_ID = "iread"
Client.BASE = "https://iread.ankio.net"

---@class IReadCredential
---@field token string|nil 个人 Token（Bearer）
---@field cookie string|nil 网页登录 Cookie 请求头

--- 已保存的登录凭据，Token 优先；没登录返回 nil。
---@return IReadCredential|nil
function Client.credential()
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    if type(cfg.token) == "string" and cfg.token ~= "" then return { token = cfg.token } end
    if type(cfg.cookie) == "string" and cfg.cookie ~= "" then return { cookie = cfg.cookie } end
    return nil
end

--- 发请求用的凭据是不是当前已保存的那份（校验新凭据时的回包不能动已保存的登录态）。
---@param cred IReadCredential
---@return boolean
local function isCurrent(cred)
    local saved = Client.credential()
    if not saved then return cred.token == nil and cred.cookie == nil end
    return saved ~= nil and saved.token == cred.token and saved.cookie == cred.cookie
end

--- 嵌套表按 PHP 的 `a[b]` 写法摊平成表单键（数组用 0 基下标，PHP 侧才是列表）；布尔 / 数字转字符串，nil 丢弃。
---@param out table<string, string>
---@param key string
---@param value any
local function flatten(out, key, value)
    if type(value) == "table" then
        local is_list = #value > 0
        for k, v in pairs(value) do
            flatten(out, key .. "[" .. (is_list and (k - 1) or tostring(k)) .. "]", v)
        end
    elseif value ~= nil and value ~= JSON.util.null then
        out[key] = tostring(value)
    end
end

---@param form table<string, any>
---@return string
local function encode(form)
    local flat = {}
    for key, value in pairs(form) do flatten(flat, key, value) end
    return Text.formEncode(flat)
end

--- 解回包：返回 data。401 / 403 视为登录失效。
---@param raw string|nil
---@param err any
---@param cred IReadCredential 发请求时用的凭据
---@return any|nil data, string|nil err
function Client.decode(raw, err, cred)
    if err then return nil, tostring(err) end
    if not raw then return nil, _("请求失败") end
    local ok, wire = pcall(JSON.decode, raw, JSON.decode.simple)
    if not ok or type(wire) ~= "table" then return nil, _("响应无效") end
    local code = tonumber(wire.code)
    if code == 200 then
        return wire.data == nil and {} or wire.data
    end
    if (code == 401 or code == 403) and (cred.token or cred.cookie) and isCurrent(cred) then
        return nil, require("source.auth").expire(SOURCE_ID, _("请按这个做：\n1. 点这个提示上的「重新登录」。没有按钮就打开「设置 → 书库 → 账号 → iRead → iRead 账号」。\n2. 用电脑浏览器打开 https://iread.ankio.net/user/token ，登录你的账号。\n3. 在页面上新建一个个人 Token，复制它。\n4. 回到月读的输入框，把 Token 贴进去，点「登录」。\n\n如果平时用的是浏览器扩展，不要新建 Token，改做下面这些：\n")
            .. require("source.cookie_login").relogin(_("iRead"), "https://iread.ankio.net/user/token"))
    end
    return nil, type(wire.msg) == "string" and wire.msg ~= "" and wire.msg or _("请求失败")
end

---@param path string
---@param form table<string, any>
---@param cred IReadCredential
---@param ratio number 超时倍率
---@param cb fun(data: any|nil, err: string|nil, res: table|nil)
---@param session string|nil 服务端会话 Cookie（搜索结果存在会话里，轮询必须带回）
---@return { cancel: fun() }
local function post(path, form, cred, ratio, cb, session)
    local cookie = session and require("source.cookie_login").parse((cred.cookie or "") .. "; " .. session)
        or cred.cookie
    return Request.post(Client.BASE .. path, encode(form), {
        accept = "application/json",
        headers = { Cookie = cookie, Authorization = cred.token and ("Bearer " .. cred.token),
            ["X-Requested-With"] = "XMLHttpRequest" },
        content_type = "application/x-www-form-urlencoded",
        timeout = require("http.timeout").net(ratio),
    }, function(raw, err, res)
        local data, decode_err = Client.decode(raw, err, cred)
        cb(data, decode_err, res)
    end)
end

--- 读取接口允许游客；已登录时使用用户配置的书源。
---@param path string
---@param form table<string, any>
---@param ratio number
---@param cb fun(data: any|nil, err: string|nil, res: table|nil)
---@param session string|nil
---@return { cancel: fun() }
local function call(path, form, ratio, cb, session)
    local cred = Client.credential() or {}
    return post(path, form, cred, ratio, function(data, err, res)
        if not isCurrent(cred) then cb(nil, _("登录状态已变化，请重试")); return end
        cb(data, err, res)
    end, session)
end

--- 校验凭据并取账号信息（设置页用，凭据由调用方显式给）。
---@param cred IReadCredential
---@param cb fun(user: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client.userAsync(cred, cb)
    return post("/user/home", {}, cred, 0.5, function(data, err)
        if type(data) ~= "table" or type(data.nickname) ~= "string" or data.nickname == "" then
            cb(nil, err or _("iRead 账号信息为空")); return
        end
        if isCurrent(cred) then require("source.auth").ok(SOURCE_ID) end
        cb(data)
    end)
end

--- 列表响应必须是连续数组；坏行不能被 ipairs 静默丢掉并参与书架对账。
---@param rows any
---@param field string
---@return boolean
local function validRows(rows, field)
    if type(rows) ~= "table" then return false end
    local count = 0
    for key, row in pairs(rows) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0
            or type(row) ~= "table" or type(row[field]) ~= "string" or row[field] == "" then return false end
        count = count + 1
    end
    return count == #rows
end

--- 个人书架（服务端书记录原行）。空书架要另验登录态。
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return { cancel: fun() }
function Client.shelfAsync(cb)
    local cred = Client.credential()
    if not cred then return require("source.base").defer(cb, nil, _("未登录 iRead")) end
    local job, cancelled, pending = nil, false, true
    local first = post("/book/list", {}, cred, 0.5, function(data, err)
        pending = false
        if cancelled then return end
        if not isCurrent(cred) then cb(nil, _("登录状态已变化，请重试")); return end
        if not validRows(data, "name") then cb(nil, err or _("响应无效")); return end
        if #data > 0 then
            require("source.auth").ok(SOURCE_ID)
            cb(data); return
        end
        job = Client.userAsync(cred, function(user, user_err)
            if cancelled then return end
            if not isCurrent(cred) then cb(nil, _("登录状态已变化，请重试")); return end
            if not user then cb(nil, user_err); return end
            cb({})
        end)
    end)
    if pending then job = first end
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
end

--- 目录：章节对象数组，顺序即阅读顺序。
---@param row table 书架行
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return { cancel: fun() }
function Client.chaptersAsync(row, cb)
    return call("/book/chapters", row, 1, function(data, err)
        if not validRows(data, "title") then cb(nil, err or _("响应无效")); return end
        if #data == 0 then cb(nil, _("iRead 目录为空")); return end
        cb(data)
    end)
end

--- 一章正文（纯文本）。chapter_raw 是目录里原样保存的章节 JSON，index 是 0 基章序号。
---@param row table
---@param chapter_raw string
---@param index integer
---@param cb fun(text: string|nil, err: string|nil)
---@return { cancel: fun() }
function Client.contentAsync(row, chapter_raw, index, cb)
    return call("/book/chapter", { book = JSON.encode(row), chapter = chapter_raw, index = index }, 1,
        function(data, err)
            local text = type(data) == "table" and data.content
            if type(text) ~= "string" or text == "" then cb(nil, err or _("iRead 章节内容为空")); return end
            cb(text)
        end)
end

--- 上报阅读位置：服务端用整行覆盖记录，所以带回原行，只改位置字段。
---@param row table
---@param pos { index: integer, title: string|nil, offset: integer }
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Client.saveProgressAsync(row, pos, cb)
    if not Client.credential() then return require("source.base").defer(cb, nil, _("未登录 iRead")) end
    local body = {}
    for key, value in pairs(row) do body[key] = value end
    body.durChapterIndex = pos.index
    body.durChapterPos = pos.offset
    body.durChapterTitle = pos.title or ""
    body.durChapterTime = os.time() * 1000
    local cancelled, job, pending = false, nil, true
    local first = call("/book/process", body, 0.5, function(data, err)
        pending = false
        if cancelled then return end
        if data == nil then cb(nil, err); return end
        job = Client.shelfAsync(function(rows, reason)
            if cancelled then return end
            if not rows then cb(nil, reason); return end
            for _idx, saved in ipairs(rows) do
                if saved.name == row.name and tonumber(saved.durChapterIndex) == pos.index
                    and tonumber(saved.durChapterPos) == pos.offset then cb(true); return end
            end
            cb(nil, _("iRead 阅读进度更新未生效"))
        end)
    end)
    if pending then job = first end
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
end

local SEARCH_INTERVAL = 2
local SEARCH_TRIES = 30

--- 搜索：官网的协议是「提交 → 轮询」，两步要用同一个会话 Cookie（否则取结果 500）。POST /book/search 返回 task（各书源并行搜），
--- 再每 2 秒 POST /book/search/result 取增量 result[] 直到 remaining 为 0。回调完整行数组（同书架行）。
---@param form table<string, any> 提交表单（搜索是 bookname，发现是 type / url / id）
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return { cancel: fun() }
local function runAsync(form, cb)
    local cred = Client.credential() or {}
    local UIManager = require("ui/uimanager")
    local job, tick, done = nil, nil, false
    local rows, seen, tries = {}, {}, 0
    local function finish(data, err)
        done = true
        cb(data, err)
    end
    local function poll(task, session)
        if done then return end
        if not isCurrent(cred) then finish(nil, _("登录状态已变化，请重试")); return end
        tries = tries + 1
        local pending = true
        local inner = post("/book/search/result", { task = task }, cred, 0.5, function(data, err)
            pending = false
            if done then return end
            if not isCurrent(cred) then finish(nil, _("登录状态已变化，请重试")); return end
            local remaining = type(data) == "table" and tonumber(data.remaining)
            if not remaining or remaining < 0 or remaining % 1 ~= 0 or not validRows(data.result, "name") then
                finish(nil, err or _("响应无效")); return
            end
            for _idx, row in ipairs(data.result) do
                if not seen[row.name] then
                    seen[row.name] = true
                    rows[#rows + 1] = row
                end
            end
            if remaining == 0 then finish(rows); return end
            if tries >= SEARCH_TRIES then finish(nil, _("iRead 搜索超时，请重试")); return end
            tick = function() poll(task, session) end
            UIManager:scheduleIn(SEARCH_INTERVAL, tick)
        end, session)
        if pending then job = inner end
    end
    local pending = true
    local first = post("/book/search", form, cred, 0.5, function(data, err, res)
        pending = false
        if done then return end
        if not isCurrent(cred) then finish(nil, _("登录状态已变化，请重试")); return end
        if type(data) ~= "table" or type(data.task) ~= "string" or data.task == "" then
            finish(nil, err or _("响应无效")); return
        end
        local cookies = {}
        for _idx, value in ipairs(Request.headerAll(res, "Set-Cookie")) do
            cookies[#cookies + 1] = value:match("^([^;]+)")
        end
        poll(data.task, table.concat(cookies, "; "))
    end)
    if pending then job = first end
    return {
        cancel = function()
            done = true
            if tick then UIManager:unschedule(tick) end
            if job then job.cancel() end
        end,
    }
end

---@param keyword string
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return { cancel: fun() }
function Client.searchAsync(keyword, cb)
    return runAsync({ bookname = keyword }, cb)
end

--- 书源「发现」页的一个入口（规则里的 url 模板），回包同搜索。
---@param source_id integer
---@param url string
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return { cancel: fun() }
function Client.exploreAsync(source_id, url, cb)
    return runAsync({ type = "explore", url = url, id = source_id }, cb)
end

--- 服务端当次挑出的一个书源的发现规则（每次调用换一个）。
---@param cb fun(rules: table[]|nil, err: string|nil)
---@return { cancel: fun() }
function Client.exploreRulesAsync(cb)
    return call("/kindle/exploreRules", {}, 0.5, function(rules, err)
        if not validRows(rules, "bookSourceName") then cb(nil, err or _("响应无效")); return end
        for _idx, rule in ipairs(rules) do
            if type(rule.id) ~= "number" or rule.id < 1 or rule.id % 1 ~= 0
                or rule.exploreUrl ~= nil and not validRows(rule.exploreUrl, "title") then
                cb(nil, _("响应无效")); return
            end
            for _entry_idx, entry in ipairs(rule.exploreUrl or {}) do
                if type(entry.url) ~= "string" then cb(nil, _("响应无效")); return end
            end
        end
        cb(rules)
    end)
end

--- 切换收藏状态。调用方必须先读书架判断是否需要切换，并在写后确认状态。
---@param row table
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Client.favouriteAsync(row, cb)
    if not Client.credential() then return require("source.base").defer(cb, nil, _("未登录 iRead")) end
    return call("/book/favourite", row, 0.5, function(data, err) cb(data ~= nil or nil, err) end)
end

return Client
