--[[--
拷贝漫画协议客户端：只返回 wire，不做领域转换（仅异步）。

@module koplugin.book.source.copymanga.client
--]]

local JSON = require("json")
local Auth = require("source.copymanga.auth")
local Text = require("utils.text")
local _ = require("gettext")
local T = require("ffi/util").template

local Client = {}
Client.__index = Client

local PLATFORM = "1"

--- 构造客户端。
---@param o table|nil
---@return CopymangaClient
function Client:new(o)
    o = o or {}
    setmetatable(o, self)
    return o
end

--- 是否可用：api_host 有内置默认，不要求用户手填。
---@return boolean
function Client:configured()
    return Auth.apiHost() ~= ""
end

---@param path string
---@param query table|nil
---@return string
function Client:_url(path, query)
    local host = Auth.apiHost()
    local url = "https://" .. host .. path
    if query and next(query) then
        url = url .. "?" .. Text.formEncode(query)
    end
    return url
end

--- 解析 JSON 响应；code!=200 时 err。
---@param res table|nil
---@param req_err any
---@return table|nil, string|nil
local function parseJson(res, req_err)
    if req_err then
        return nil, tostring(req_err)
    end
    local raw = Text.stripBom(res and res.body or "")
    local ok, data = pcall(JSON.decode, raw)
    if not ok or type(data) ~= "table" then
        return nil, _("响应不是 JSON")
    end
    local code = tonumber(data.code)
    if code == 401 then
        return nil, _("登录已过期")
    end
    if code and code ~= 200 then
        if code == 210 then
            return nil, _("账号被风控，请稍后再试")
        end
        return nil, data.message or data.msg or T(_("错误码 %1"), tostring(code))
    end
    return data
end

---@param method string
---@param path string
---@param opts table|nil
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:_jsonAsync(method, path, opts, cb)
    opts = opts or {}
    local cancelled = false
    local headers = Auth.headers(opts.token)
    local body
    if opts.body then
        if opts.form then
            body = Text.formEncode(opts.body)
            headers["Content-Type"] = "application/x-www-form-urlencoded;charset=utf-8"
        else
            local ok, encoded = pcall(JSON.encode, opts.body)
            if not ok then
                cb(nil, _("JSON 编码失败"))
                return { cancel = function() end }
            end
            body = encoded
            headers["Content-Type"] = "application/json"
        end
    end
    local job = require("http.request").request({
        url = self:_url(path, opts.query),
        method = method,
        headers = headers,
        body = body,
        timeout = opts.timeout or 30,
    }, function(res, err)
        if cancelled then return end
        local data, parse_err = parseJson(res, err)
        if data then
            cb(data)
        else
            cb(nil, parse_err)
        end
    end)
    return {
        cancel = function()
            cancelled = true
            if job and job.cancel then job.cancel() end
        end,
    }
end

function Client:searchAsync(keyword, limit, offset, cb)
    keyword = tostring(keyword or "")
    if keyword == "" then
        cb(nil, _("搜索关键词不能为空"))
        return { cancel = function() end }
    end
    return self:_jsonAsync("GET", "/api/v3/search/comic", {
        query = {
            limit = limit or 20,
            offset = offset or 0,
            q = keyword,
            q_type = "",
            platform = PLATFORM,
        },
    }, cb)
end

--- 书城默认列表（推荐流，无需登录）。
function Client:browseAsync(limit, offset, cb)
    return self:_jsonAsync("GET", "/api/v3/recs", {
        query = {
            pos = "3200102",
            limit = limit or 20,
            offset = offset or 0,
            platform = PLATFORM,
        },
    }, cb)
end

function Client:favoritesAsync(limit, offset, cb)
    return self:_jsonAsync("GET", "/api/v3/member/collect/comics", {
        query = {
            limit = limit or 36,
            offset = offset or 0,
            free_type = 1,
            ordering = "-datetime_updated",
        },
    }, cb)
end

function Client:comicInfoAsync(path_word, cb)
    path_word = tostring(path_word or "")
    return self:_jsonAsync("GET", "/api/v3/comic2/" .. path_word, {
        query = { platform = PLATFORM },
    }, cb)
end

function Client:chaptersAsync(path_word, group_path, offset, cb)
    path_word = tostring(path_word or "")
    group_path = tostring(group_path or "default")
    return self:_jsonAsync("GET",
        "/api/v3/comic/" .. path_word .. "/group/" .. group_path .. "/chapters", {
        query = { limit = 100, offset = offset or 0 },
    }, cb)
end

function Client:chapterAsync(path_word, chapter_uuid, cb)
    path_word = tostring(path_word or "")
    chapter_uuid = tostring(chapter_uuid or "")
    return self:_jsonAsync("GET",
        "/api/v3/comic/" .. path_word .. "/chapter2/" .. chapter_uuid, {
        query = { platform = PLATFORM },
    }, cb)
end

return Client
