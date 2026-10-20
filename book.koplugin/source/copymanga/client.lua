--[[--
拷贝漫画 App API 客户端。

协议对齐 kComics：``COPY/3.0.0`` + ``/api/v3/*``，返回 JSON wire。

@module koplugin.book.source.copymanga.client
--]]

local JSON = require("json")
local Text = require("utils.text")
local _ = require("gettext")
local Auth = require("source.auth")

---@class CopymangaClient
---@field base_url string
---@field token string
local Client = {}
Client.__index = Client

local DEFAULT_BASE_URL = "https://api.copy202601.com"

Client.DEFAULT_BASE_URL = DEFAULT_BASE_URL

---@return string
function Client.normalizeBaseUrl(url)
    url = Text.rtrimSlashes(Text.stripWhitespace(url))
    if url == "" then
        return DEFAULT_BASE_URL
    end
    return url
end

--- App 请求头。登录与章节接口都靠这组字段识别客户端。
---@param token string|nil
---@return table
function Client.headers(token)
    local headers = {
        ["User-Agent"] = "COPY/3.0.0",
        ["version"] = "2025.08.15",
        ["platform"] = "1",
        ["webp"] = "1",
        ["region"] = "1",
    }
    if type(token) == "string" and token ~= "" then
        headers["Authorization"] = "Token " .. token
    end
    return headers
end

---@param cfg { base_url: string|nil, token: string|nil }
---@return CopymangaClient
function Client:new(cfg)
    return setmetatable({
        base_url = Client.normalizeBaseUrl(cfg.base_url),
        token = cfg.token or "",
    }, self)
end

---@return boolean
function Client:configured()
    return self.base_url:match("^https?://[^/]+$") ~= nil
end

--- 解 App 接口回包：code 200 才算成功，210 是风控。登录也走这里。
---@param raw string|nil
---@param err string|nil
---@return table|nil, string|nil
function Client.decode(raw, err)
    if not raw then return nil, err end
    local ok, wire = pcall(JSON.decode, raw)
    if not ok or type(wire) ~= "table" then
        return nil, _("响应无效")
    end
    local code = tonumber(wire.code)
    if code == 210 then
        return nil, _("账号被风控，请稍后再试")
    end
    if code ~= 200 then
        return nil, wire.message or _("请求失败")
    end
    return wire
end

--- 进行中的自动重登：等待者回调列表；nil = 空闲。全进程只发一次登录，免得并发 401 各自登录、互相挤掉令牌。
---@type fun(ok: boolean|nil, err: string|nil, rejected: boolean|nil)[]|nil
local relogin_waiters

--- 用本地保存的账号密码重登（单飞）。没存密码时立即 cb(nil, nil, true)。
--- 不随单个请求取消：登录结果要分给所有等待者。
---@param cb fun(ok: boolean|nil, err: string|nil, rejected: boolean|nil)
local function relogin(cb)
    if relogin_waiters then
        relogin_waiters[#relogin_waiters + 1] = cb
        return
    end
    local Auth = require("source.copymanga.auth")
    local username, password = Auth.credentials()
    if not username then
        cb(nil, nil, true)
        return
    end
    relogin_waiters = { cb }
    Auth.loginAsync(username, password, function(ok, err, rejected)
        local waiters = relogin_waiters or {}
        relogin_waiters = nil
        for _idx, waiter in ipairs(waiters) do waiter(ok, err, rejected) end
    end)
end

--- 设置里的最新令牌（别的实例重登后写进去的），没有就用本实例的。
---@return string
function Client:_latestToken()
    local token = require("utils.settings").getSource("copymanga").token
    if type(token) == "string" and token ~= "" then self.token = token end
    return self.token
end

--- GET JSON。令牌失效（HTTP 401，如在别处登录后被挤掉）时用本地保存的账号密码重登一次再重试。
--- 别的请求已经换过令牌时直接用新令牌重试，不再登录。重登被服务端拒绝才提示重新登录，网络错误原样回传。
---@param path string
---@param cb fun(wire: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:_getJson(path, cb)
    local expired = _("拷贝漫画登录已失效，请在设置里重新登录")
    local active, cancelled
    local function send(may_relogin)
        local sent = self:_latestToken()
        active = require("http.request").get(self.base_url .. path, {
            accept = "application/json",
            headers = Client.headers(sent),
            allow_redirects = true,
            timeout = require("http.timeout").net(2),
            connect_timeout = require("http.timeout").net(1),
        }, function(raw, err, res)
            if cancelled then return end
            if not (res and res.code == 401) then
                cb(Client.decode(raw, err))
                return
            end
            if not may_relogin then
                cb(nil, Auth.expire("copymanga", expired))
                return
            end
            if self:_latestToken() ~= sent then
                send(false)
                return
            end
            active = nil
            relogin(function(ok, login_err, rejected)
                if cancelled then return end
                if ok then Auth.ok("copymanga"); send(false); return end
                cb(nil, rejected and Auth.expire("copymanga", expired) or (login_err or _("请求失败")))
            end)
        end)
    end
    send(true)
    return { cancel = function()
        cancelled = true
        if active then active.cancel() end
    end }
end

---@param stable_id string
---@param cb fun(wire: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:detailAsync(stable_id, cb)
    return self:_getJson("/api/v3/comic2/" .. Text.urlEncode(stable_id) .. "?platform=1", cb)
end

---@param keyword string
---@param cb fun(wire: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:searchAsync(keyword, cb)
    return self:_getJson("/api/v3/search/comic?limit=30&offset=0&platform=1&q_type=&q=" .. Text.urlEncode(keyword), cb)
end

--- 排行榜一页（20 部）。audience 为 male / female，nil 是全部；date_type 1 日 2 周 3 月 4 总。
---@param date_type string
---@param audience string|nil
---@param offset integer
---@param cb fun(wire: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:rankAsync(date_type, audience, offset, cb)
    local path = "/api/v3/ranks?limit=20&type=1&platform=1&offset=" .. offset .. "&date_type=" .. date_type
    if audience then path = path .. "&audience_type=" .. audience end
    return self:_getJson(path, cb)
end

--- 云端浏览记录（需登录）。browse 为 null 表示从未读过。
---@param stable_id string
---@param cb fun(wire: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:getProgressAsync(stable_id, cb)
    return self:_getJson(
        "/api/v3/comic2/" .. Text.urlEncode(stable_id) .. "/query?platform=1",
        cb
    )
end

--- 按分组分页拉全量章节行（uuid / name / group_*）。
---@param stable_id string
---@param groups { path_word: string, name: string }[] 见 Mapper.groups（至少有默认组）
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return { cancel: fun() }
function Client:chaptersAsync(stable_id, groups, cb)
    local cancelled, active = false, nil
    local rows, gi = {}, 1
    local offset, limit = 0, 100

    local function step()
        if cancelled then return end
        local group = groups[gi]
        if not group then
            cb(rows)
            return
        end
        local path = "/api/v3/comic/" .. Text.urlEncode(stable_id)
            .. "/group/" .. Text.urlEncode(group.path_word)
            .. "/chapters?limit=" .. limit .. "&offset=" .. offset .. "&platform=1"
        active = self:_getJson(path, function(wire, err)
            active = nil
            if cancelled then return end
            if not wire then cb(nil, err); return end
            local root = type(wire.results) == "table" and wire.results or {}
            local list = root.list or {}
            for _idx, row in ipairs(list) do
                if type(row) == "table" and type(row.uuid) == "string" and row.uuid ~= "" then
                    rows[#rows + 1] = {
                        uuid = row.uuid,
                        name = row.name,
                        group_path = group.path_word,
                        group_name = group.name,
                    }
                end
            end
            local total = tonumber(root.total) or 0
            offset = offset + #list
            if #list == 0 or offset >= total then
                gi = gi + 1
                offset = 0
            end
            step()
        end)
    end

    step()
    return { cancel = function()
            cancelled = true
            if active then active.cancel() end
        end }
end

---@param stable_id string
---@param chapter_uid string
---@param cb fun(wire: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:chapterAsync(stable_id, chapter_uid, cb)
    local path = "/api/v3/comic/" .. Text.urlEncode(stable_id)
        .. "/chapter2/" .. Text.urlEncode(chapter_uid) .. "?platform=1"
    return self:_getJson(path, cb)
end

--- 收藏或取消收藏（需登录）。comic_id 是 comic2 返回的 uuid，不是 path_word。
---@param comic_id string
---@param collect boolean
---@param cb fun(wire: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:setCollectAsync(comic_id, collect, cb)
    -- 自动重登后新 token 只写进设置，这里先取最新的，免得拿旧 token 收藏失败。
    if self:_latestToken() == "" then
        cb(nil, _("请先登录拷贝漫画账号"))
        return { cancel = function() end }
    end
    local body = Text.formEncode({
        comic_id = comic_id,
        is_collect = collect and "1" or "0",
        authorization = "Token " .. self.token,
    })
    return require("http.request").post(
        self.base_url .. "/api/v3/member/collect/comic",
        body,
        {
            accept = "application/json",
            headers = Client.headers(self.token),
            content_type = "application/x-www-form-urlencoded;charset=utf-8",
            timeout = require("http.timeout").net(1),
            connect_timeout = require("http.timeout").net(1),
        },
        function(raw, err)
            cb(Client.decode(raw, err))
        end
    )
end

-- 收藏列表每页条数（接口上限 50）。
local COLLECT_PAGE = 50

--- 分页拉全量收藏（需登录），回调收藏行数组（每行 ``{ comic = {...} }``）。
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return { cancel: fun() }
function Client:collectAllAsync(cb)
    if self:_latestToken() == "" then
        cb(nil, _("请先登录拷贝漫画账号"))
        return { cancel = function() end }
    end
    local cancelled, rows, offset = false, {}, 0
    ---@type { cancel: fun() }
    local active

    local function step()
        active = self:_getJson("/api/v3/member/collect/comics?free_type=1&limit=" .. COLLECT_PAGE
            .. "&offset=" .. offset .. "&ordering=-datetime_updated", function(wire, err)
            if cancelled then return end
            if not wire then cb(nil, err); return end
            local root = type(wire.results) == "table" and wire.results or {}
            local list = root.list or {}
            for _idx, row in ipairs(list) do
                rows[#rows + 1] = row
            end
            offset = offset + #list
            if #list == 0 or offset >= (tonumber(root.total) or 0) then
                cb(rows)
                return
            end
            step()
        end)
    end

    step()
    return { cancel = function()
            cancelled = true
            active.cancel()
        end }
end

return Client
