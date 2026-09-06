--[[--
拷贝漫画 App API 客户端。

协议对齐 kComics：``COPY/3.0.0`` + ``/api/v3/*``，返回 JSON wire。

@module koplugin.book.source.copymanga.client
--]]

local JSON = require("json")
local Text = require("utils.text")
local _ = require("gettext")

local Client = {}
Client.__index = Client

local DEFAULT_BASE_URL = "https://api.copy202601.com"
local LEGACY_BASE_URLS = {
    ["https://copy4000.com"] = true,
    ["http://copy4000.com"] = true,
}

Client.DEFAULT_BASE_URL = DEFAULT_BASE_URL

---@param url any
---@return string
function Client.normalizeBaseUrl(url)
    url = Text.rtrimSlashes(Text.stripWhitespace(url))
    if url == "" or LEGACY_BASE_URLS[url] then
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

---@param cfg table|nil
---@return CopymangaClient
function Client:new(cfg)
    cfg = cfg or {}
    local token = cfg.token
    if type(token) ~= "string" then token = "" end
    return setmetatable({
        base_url = Client.normalizeBaseUrl(cfg.base_url),
        token = token,
    }, self)
end

---@return boolean
function Client:configured()
    return self.base_url:match("^https?://[^/]+$") ~= nil
end

---@param raw string|nil
---@param err string|nil
---@return table|nil, string|nil
local function decodeWire(raw, err)
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

---@param path string
---@param cb fun(wire: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:_getJson(path, cb)
    return require("http.request").get(self.base_url .. path, {
        accept = "application/json",
        headers = Client.headers(self.token),
        allow_redirects = true,
        block_timeout = 60,
    }, function(raw, err)
        local wire, decode_err = decodeWire(raw, err)
        cb(wire, decode_err)
    end)
end

---@param keyword string
---@param page number|nil
---@param page_size number|nil
---@param cb fun(wire: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:searchAsync(keyword, page, page_size, cb)
    page = math.max(1, math.floor(tonumber(page) or 1))
    page_size = math.max(1, math.min(50, math.floor(tonumber(page_size) or 20)))
    local offset = (page - 1) * page_size
    local path = "/api/v3/search/comic?platform=1&q_type=&offset="
        .. offset .. "&limit=" .. page_size .. "&q=" .. Text.urlEncode(keyword)
    return self:_getJson(path, cb)
end

---@param page number|nil
---@param page_size number|nil
---@param cb fun(wire: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:discoverAsync(page, page_size, cb)
    page = math.max(1, math.floor(tonumber(page) or 1))
    page_size = math.max(1, math.min(50, math.floor(tonumber(page_size) or 20)))
    local offset = (page - 1) * page_size
    local path = "/api/v3/comics?free_type=1&ordering=-datetime_updated&offset="
        .. offset .. "&limit=" .. page_size .. "&platform=1"
    return self:_getJson(path, cb)
end

---@param stable_id string
---@param cb fun(wire: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:detailAsync(stable_id, cb)
    return self:_getJson("/api/v3/comic2/" .. Text.urlEncode(stable_id) .. "?platform=1", cb)
end

--- 按分组分页拉全量章节行（uuid / name / group_*）。
---@param stable_id string
---@param groups { path_word: string, name: string }[]|nil
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return { cancel: fun() }
function Client:chaptersAsync(stable_id, groups, cb)
    if type(groups) ~= "table" or #groups == 0 then
        groups = { { path_word = "default", name = "默认" } }
    end
    local cancelled, active = false, nil
    local rows, gi = {}, 1
    local offset, limit = 0, 100

    local function fail(err)
        active = nil
        if not cancelled then cb(nil, err) end
    end

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
            if not wire then fail(err); return end
            local root = type(wire.results) == "table" and wire.results or {}
            local list = root.list or {}
            for _, row in ipairs(list) do
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
    return {
        cancel = function()
            cancelled = true
            if active and active.cancel then active.cancel() end
        end,
    }
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
    if self.token == "" then
        cb(nil, _("请先登录拷贝漫画账号"))
        return { cancel = function() end }
    end
    if type(comic_id) ~= "string" or comic_id == "" then
        cb(nil, _("无效书籍"))
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
            timeout = 30,
        },
        function(raw, err)
            local wire, decode_err = decodeWire(raw, err)
            cb(wire, decode_err)
        end
    )
end

--- 分页拉取收藏漫画（需登录）。
---@param offset integer
---@param limit integer
---@param cb fun(wire: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:collectAsync(offset, limit, cb)
    if self.token == "" then
        cb(nil, _("请先登录拷贝漫画账号"))
        return { cancel = function() end }
    end
    offset = math.max(0, math.floor(tonumber(offset) or 0))
    limit = math.max(1, math.min(50, math.floor(tonumber(limit) or 50)))
    local path = "/api/v3/member/collect/comics?free_type=1&limit="
        .. limit .. "&offset=" .. offset .. "&ordering=-datetime_updated"
    return self:_getJson(path, cb)
end

--- 拉全量收藏列表。
---@param cb fun(wire: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:collectAllAsync(cb)
    local cancelled = false
    local active
    local books = {}
    local offset, limit = 0, 50

    local function fail(err)
        active = nil
        if not cancelled then cb(nil, err) end
    end

    local function step()
        if cancelled then return end
        active = self:collectAsync(offset, limit, function(wire, err)
            active = nil
            if cancelled then return end
            if not wire then fail(err); return end
            local root = type(wire.results) == "table" and wire.results or {}
            local list = root.list or {}
            for _, row in ipairs(list) do
                books[#books + 1] = row
            end
            local total = tonumber(root.total) or #books
            offset = offset + #list
            if #list == 0 or offset >= total then
                cb({ results = { list = books, total = #books } })
                return
            end
            step()
        end)
    end

    step()
    return {
        cancel = function()
            cancelled = true
            if active and active.cancel then active.cancel() end
        end,
    }
end

return Client
