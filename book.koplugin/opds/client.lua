--[[--
OPDS 目录 HTTP wire：Atom feed / OpenSearch 描述拉取与书籍下载（HTTP Basic，仅异步）。

@module koplugin.book.opds.client
--]]

local Header = require("http.header")
local Request = require("http.request")
local Text = require("utils.text")

local ACCEPT = "application/atom+xml, application/opds+json, application/opensearchdescription+xml;q=0.9, "
    .. "application/xml;q=0.8, application/json;q=0.8, */*;q=0.5"
-- 目录翻页 / 返回上级常回到刚看过的 feed，短缓存即可免去重复请求。
local FEED_TTL = 5 * 60

---@class OpdsClient
---@field cfg { url: string|nil, username: string|nil, password: string|nil }
local Client = {}
Client.__index = Client

---@param cfg table|nil settings/opds.lua
---@return OpdsClient
function Client.new(cfg)
    return setmetatable({ cfg = cfg or {} }, Client)
end

--- 目录根地址；未配置为空串。
---@return string
function Client:rootUrl()
    return Text.trim(self.cfg.url)
end

---@return boolean
function Client:configured()
    return self:rootUrl() ~= ""
end

---@param url string|nil
---@return string|nil
local function originOf(url)
    return tostring(url or ""):match("^(%a[%w+.-]*://[^/?#]+)")
end

--- 封面请求头：只对目录同源地址带 Basic 凭据，第三方图床不泄露账号。
---@param url string|nil
---@return table|nil
function Client:coverHeaders(url)
    local user = self.cfg.username
    if not url or not user or user == "" or originOf(url) ~= originOf(self:rootUrl()) then return nil end
    return { Authorization = "Basic " .. Text.base64Encode(user .. ":" .. (self.cfg.password or "")) }
end

--- GET 一份 feed / OpenSearch 描述。
---@param url string
---@param cb fun(body: string|nil, err: any, res: table|nil)
---@return HttpJob
function Client:getAsync(url, cb)
    return Request.get(url, {
        accept = ACCEPT,
        cache_ttl = FEED_TTL,
        allow_redirects = true,
        user = self.cfg.username,
        password = self.cfg.password,
    }, cb)
end

--- 下载书籍文件到 dest（Request.download 先写 .part 再改名）。
---@param url string
---@param dest string
---@param on_progress fun(bytes: number, total: number|nil)|nil
---@param cb fun(ok: boolean, err: any, res: table|nil)
---@return HttpJob
function Client:downloadAsync(url, dest, on_progress, cb)
    return Request.download({
        url = url,
        headers = Header.forDownload(),
        timeout = 300,
        allow_redirects = true,
        auth_username = self.cfg.username,
        auth_password = self.cfg.password,
        on_progress = on_progress,
    }, dest, cb)
end

return Client
