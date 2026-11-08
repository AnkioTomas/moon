--[[--
18ta 匿名 HTTP 客户端（只走 http.request）。

站点 WAF 对首个请求回 403 并下发会话 Cookie（Set-Cookie），带上 Cookie 后放行；
Cookie 随每个响应刷新。站内搜索维护中，不接；只有分类书库、书籍详情、章节正文。

@module source.18ta.client
--]]

local Request = require("http.request")
local Mapper = require("source.18ta.mapper")
local _ = require("l10n").get("source.18ta")

local BASE = "https://www.18ta.com"
local TIMEOUT = require("http.timeout").net(1)
local UA = "Mozilla/5.0"

---@class T18taClient
---@field cookies table<string, string>
local Client = {}
Client.__index = Client

---@return T18taClient
function Client.new()
    return setmetatable({ cookies = {} }, Client)
end

--- 把响应里的 Set-Cookie 收进本地 Cookie 表。
---@param res table|nil
---@return boolean 是否收到新 Cookie
function Client:absorbCookies(res)
    local got = false
    for _idx, line in ipairs(Request.headerAll(res, "Set-Cookie")) do
        local name, value = line:match("^%s*([^=;%s]+)=([^;]*)")
        if name then
            self.cookies[name] = value
            got = true
        end
    end
    return got
end

---@return table<string, string>
function Client:requestHeaders()
    local headers = { ["User-Agent"] = UA }
    local parts = {}
    for name, value in pairs(self.cookies) do
        parts[#parts + 1] = name .. "=" .. value
    end
    if #parts > 0 then
        headers.Cookie = table.concat(parts, "; ")
    end
    return headers
end

--- GET（WAF 兜底：403 且拿到 Cookie 时重发一次）。
---@param path string 站内路径（/ 开头）或完整 URL
---@param cb fun(body: string|nil, err: string|nil, res: table|nil)
---@return { cancel: fun() }
function Client:get(path, cb)
    path = path:gsub("^https://www%.18ta%.com/", "/")
    if not path:match("^/[^/]") then
        return require("source.base").defer(cb, nil, _("响应无效"))
    end
    local url = BASE .. path
    local job, cancelled, finished = nil, false, false
    local function finish(body, err, res)
        if cancelled or finished then return end
        finished = true
        cb(body, err, res)
    end
    local function request(retry)
        local pending = true
        local inner = Request.get(url, {
            headers = self:requestHeaders(), timeout = TIMEOUT, cache_ttl = 0,
        }, function(body, err, res)
            pending = false
            if cancelled or finished then return end
            job = nil
            local got = self:absorbCookies(res)
            if not body and res and res.code == 403 and got and not retry then
                request(true)
                return
            end
            finish(body, err, res)
        end)
        if pending then job = inner end
    end
    request(false)
    return {
        cancel = function()
            cancelled = true
            if job then job.cancel() end
        end,
    }
end

--- 分类书库一页：/sort/<cat>/<page>.html
---@param node string
---@param page integer
---@param cb fun(body: string|nil, err: string|nil)
---@return { cancel: fun() }
function Client:listAsync(node, page, cb)
    return self:get(Mapper.storePage(node, page), cb)
end

--- 书籍详情页（含目录）：/akshtml<id>.html
---@param book_id string
---@param cb fun(body: string|nil, err: string|nil)
---@return { cancel: fun() }
function Client:bookAsync(book_id, cb)
    return self:get("/akshtml" .. book_id .. ".html", cb)
end

--- 章节正文页。href 取自目录（/aks/<group>/<id>/<ch>.html）或完整 URL。
---@param path string
---@param cb fun(body: string|nil, err: string|nil)
---@return { cancel: fun() }
function Client:chapterAsync(path, cb)
    return self:get(path, cb)
end

--- 一章可能拆成多页；只在同章所有页成功后交付正文。
---@param path string
---@param cb fun(html: string|nil, err: string|nil)
---@return { cancel: fun() }
function Client:contentAsync(path, cb)
    local handle, parts = {}, {}
    local function fetch(current)
        local pending = true
        local inner = self:chapterAsync(current, function(html, err)
            pending = false
            if handle.cancelled then return end
            handle.inner = nil
            if not html then cb(nil, err); return end
            local body = Mapper.chapterContent(html)
            if not body then cb(nil, _("阅读章节内容为空")); return end
            local next_path, next_err = Mapper.chapterNext(html, current)
            if next_err then cb(nil, next_err); return end
            parts[#parts + 1] = body
            if next_path then fetch(next_path); return end
            cb(table.concat(parts, "\n"))
        end)
        if pending then handle.inner = inner end
    end
    fetch(path)
    function handle.cancel()
        handle.cancelled = true
        if handle.inner then handle.inner.cancel() end
    end
    return handle
end

return Client
