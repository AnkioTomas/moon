--[[--
WebDAV 协议客户端包装 http.webdav（仅异步）

@module koplugin.book.source.webdav.client
--]]

local Webdav = require("http.webdav")

local Client = {}
Client.__index = Client

--- 从配置构造 WebDAV 客户端。
---@param cfg table|nil
---@return WebdavClient
function Client.new(cfg)
    cfg = cfg or {}
    local self = setmetatable({
        cfg = cfg,
        _dav = Webdav.new{
            url = cfg.url,
            username = cfg.username,
            password = cfg.password,
        },
    }, Client)
    return self
end

--- 是否已配置 URL 与用户名。
---@return boolean
function Client:configured()
    local url = (self.cfg.url or ""):gsub("%s+", "")
    local user = (self.cfg.username or ""):gsub("%s+", "")
    return url ~= "" and user ~= ""
end

function Client:pingAsync(cb)
    return self._dav:pingAsync(cb)
end

function Client:listAsync(path, cb)
    return self._dav:listAsync(path, cb)
end

function Client:downloadAsync(remote_path, temp_path, on_progress, cb)
    return self._dav:getAsync(remote_path, temp_path, {
        on_progress = on_progress,
    }, cb)
end

return Client
