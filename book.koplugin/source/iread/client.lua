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
local _ = require("gettext")

local Client = {}

local SOURCE_ID = "iread"
Client.BASE = "https://iread.ankio.net"

--- 个人 Token；没登录返回 nil。
---@return string|nil
function Client.token()
    local token = require("utils.settings").getSource(SOURCE_ID).token
    if type(token) ~= "string" or token == "" then return nil end
    return token
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
    elseif value ~= nil then
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
---@param token string 发请求时用的 Token
---@return any|nil data, string|nil err
function Client.decode(raw, err, token)
    if not raw then return nil, err and tostring(err) or _("请求失败") end
    local ok, wire = pcall(JSON.decode, raw)
    if not ok or type(wire) ~= "table" then return nil, _("响应无效") end
    local code = tonumber(wire.code)
    if code == 200 then
        if token == Client.token() then require("source.auth").ok(SOURCE_ID) end
        return wire.data == nil and {} or wire.data
    end
    if (code == 401 or code == 403) and token == Client.token() then
        return nil, require("source.auth").expire(SOURCE_ID, _("iRead 登录已失效，请重新填写个人 Token"))
    end
    return nil, type(wire.msg) == "string" and wire.msg ~= "" and wire.msg or _("请求失败")
end

---@param path string
---@param form table<string, any>
---@param token string
---@param ratio number 超时倍率
---@param cb fun(data: any|nil, err: string|nil, res: table|nil)
---@param session string|nil 服务端会话 Cookie（搜索结果存在会话里，轮询必须带回）
---@return { cancel: fun() }
local function post(path, form, token, ratio, cb, session)
    return Request.post(Client.BASE .. path, encode(form), {
        accept = "application/json",
        headers = { Authorization = "Bearer " .. token, Cookie = session },
        content_type = "application/x-www-form-urlencoded",
        timeout = require("http.timeout").net(ratio),
    }, function(raw, err, res)
        local data, decode_err = Client.decode(raw, err, token)
        cb(data, decode_err, res)
    end)
end

--- 带已保存 Token 的请求；没登录直接报错。
---@param path string
---@param form table<string, any>
---@param ratio number
---@param cb fun(data: any|nil, err: string|nil, res: table|nil)
---@param session string|nil
---@return { cancel: fun() }
local function call(path, form, ratio, cb, session)
    local token = Client.token()
    if not token then return require("source.base").defer(cb, nil, _("未登录 iRead")) end
    return post(path, form, token, ratio, cb, session)
end

--- 校验 Token 并取账号信息（设置页用，Token 由调用方显式给）。
---@param token string
---@param cb fun(user: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client.userAsync(token, cb)
    return post("/user/home", {}, token, 0.5, function(data, err)
        if type(data) ~= "table" or data.nickname == nil then cb(nil, err or _("iRead 账号信息为空")); return end
        cb(data)
    end)
end

--- 个人书架（服务端书记录原行）。空书架要另验登录态。
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return { cancel: fun() }
function Client.shelfAsync(cb)
    local job
    job = call("/book/list", {}, 0.5, function(data, err)
        if type(data) ~= "table" then cb(nil, err); return end
        if #data > 0 then cb(data); return end
        job = call("/user/home", {}, 0.5, function(user, user_err)
            if type(user) ~= "table" then cb(nil, user_err); return end
            cb({})
        end)
    end)
    return { cancel = function() job.cancel() end }
end

--- 目录：章节对象数组，顺序即阅读顺序。
---@param row table 书架行
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return { cancel: fun() }
function Client.chaptersAsync(row, cb)
    return call("/book/chapters", row, 1, function(data, err)
        if type(data) ~= "table" or #data == 0 then cb(nil, err or _("iRead 目录为空")); return end
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
    local body = {}
    for key, value in pairs(row) do body[key] = value end
    body.durChapterIndex = pos.index
    body.durChapterPos = pos.offset
    body.durChapterTitle = pos.title or ""
    body.durChapterTime = os.time() * 1000
    return call("/book/process", body, 0.5, function(data, err) cb(data ~= nil or nil, err) end)
end

local SEARCH_INTERVAL = 2
local SEARCH_TRIES = 30

--- 搜索：官网的协议是「提交 → 轮询」，两步要用同一个会话 Cookie（否则取结果 500）。POST /book/search 返回 task（各书源并行搜），
--- 再每 2 秒 POST /book/search/result 取增量 result[] 直到 remaining 为 0。回调完整行数组（同书架行）。
---@param keyword string
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return { cancel: fun() }
function Client.searchAsync(keyword, cb)
    local UIManager = require("ui/uimanager")
    local job, tick, done = nil, nil, false
    local rows, tries = {}, 0
    local function poll(task, session)
        tries = tries + 1
        job = call("/book/search/result", { task = task }, 0.5, function(data, err)
            if done then return end
            if type(data) ~= "table" then cb(nil, err); return end
            for _idx, row in ipairs(data.result or {}) do rows[#rows + 1] = row end
            if (tonumber(data.remaining) or 0) == 0 or tries >= SEARCH_TRIES then
                done = true
                cb(rows)
                return
            end
            tick = function() poll(task, session) end
            UIManager:scheduleIn(SEARCH_INTERVAL, tick)
        end, session)
    end
    job = call("/book/search", { bookname = keyword }, 0.5, function(data, err, res)
        if done then return end
        if type(data) ~= "table" or type(data.task) ~= "string" then cb(nil, err or _("请求失败")); return end
        local set_cookie = Request.header(res, "Set-Cookie")
        local session = type(set_cookie) == "table" and set_cookie[1] or set_cookie
        poll(data.task, session and session:match("^([^;]+)"))
    end)
    return {
        cancel = function()
            done = true
            if tick then UIManager:unschedule(tick) end
            job.cancel()
        end,
    }
end

--- 把书移出书架。/book/favourite 是开关，调用方必须先确认书还在书架上。
---@param row table
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Client.removeAsync(row, cb)
    return call("/book/favourite", row, 0.5, function(data, err) cb(data ~= nil or nil, err) end)
end

return Client
