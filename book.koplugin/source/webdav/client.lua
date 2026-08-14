--[[--
WebDAV 协议客户端包装 http.webdav

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

--- 探测 WebDAV 连通性。
---@return boolean|nil, string|nil
function Client:ping()
    return self._dav:ping()
end

--- 列出远程目录条目。
---@param path string|nil
---@return table[]|nil, string|nil
function Client:list(path)
    return self._dav:list(path)
end

--- 下载远程文件到本地临时路径。
---@param remote_path string
---@param temp_path string
---@param on_progress fun(bytes: number)|nil
---@return boolean|nil, string|nil
function Client:download(remote_path, temp_path, on_progress)
    return self._dav:get(remote_path, temp_path, {
        on_progress = on_progress,
    })
end

return Client
