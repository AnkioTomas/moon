--[[--
本地书库客户端（仅异步）：配置、路径与方法装配。

数据流：扫盘只把目录状态写进 books（增/改/删，文件名入库）；封面与引擎元数据另开补齐进程。
书库/筛选/搜索/最近阅读/统计一律直查数据库，不做内存缓存。
实现按职责拆在同目录：scan（本地目录扫盘 / 补齐 / 导入 / 移动 / 替换）、
webdav（网盘书目同步与远端书操作，传输在 dav / gdrive）、
remote_data（.Moon+ 进度 / 统计 / 笔记）、common（共享原语）。
子模块函数首参即 self，在这里装配为方法。

@module koplugin.book.source.local.client
--]]

local lfs = require("libs/libkoreader-lfs")
local Text = require("utils.text")
local _ = require("gettext")
local Webdav = require("source.local.dav")
local GDrive = require("source.local.gdrive")
local Paths = require("utils.paths")
local Common = require("source.local.common")
local Scan = require("source.local.scan")
local LocalWebdav = require("source.local.webdav")
local RemoteData = require("source.local.remote_data")

local SOURCE_ID = Common.SOURCE_ID
local rootPath, localRoot = Common.rootPath, Common.localRoot
local remoteRelativePath, coverPath = Common.remoteRelativePath, Common.coverPath

---@class LocalClient
---@field upload_failed table<string, number> 上传失败的冷却时间
---@field _uploading boolean|nil 是否正在上传
---@field cfg table
---@field dav WebdavClient|GDriveClient
---@field _crashed table<string, boolean>|nil 补齐时引擎崩过的路径（本进程）
---@field _enrich_job { cancel: fun() }|nil 在飞的封面/元数据补齐
---@field _enriched table<string, boolean>|nil 本进程已补齐过的远端书（按 stable_id）
---@field _stats_seen table<string, string>|nil 统计按书已入库版本（stats_index.json 的内存副本）
local Client = {}

--- 网盘凭据指纹：变了就换一个传输客户端（访问令牌和 Drive 文件 id 缓存在客户端上，不能每次现造），
--- 也是 webdav.lua 里 books.sync 读改写锁的键（WebDAV 看地址，Drive 看令牌，不能只看 webdav_url）。
---@return string
function Client:cloudStamp()
    local cfg = self.cfg
    return table.concat({
        cfg.cloud or "",
        cfg.webdav_url or "",
        cfg.webdav_username or "",
        cfg.webdav_password or "",
        cfg.gdrive_token or "",
        cfg.gdrive_client or "",
    }, "\0")
end

--- cfg 是 utils.settings 的共享表，设置页和远程配置会原地改它。
Client.__index = function(self, key)
    if key == "dav" then
        local stamp = Client.cloudStamp(self)
        local cached = rawget(self, "_dav")
        if cached and rawget(self, "_dav_stamp") == stamp then return cached end
        local built = self:_buildDav()
        rawset(self, "_dav", built)
        rawset(self, "_dav_stamp", stamp)
        return built
    end
    return Client[key]
end

--- 按 cloud 选传输。没写 cloud 但填了 WebDAV 地址的旧配置仍走 WebDAV。
---@return table
function Client:_buildDav()
    local kind = self:cloudKind()
    if kind == "gdrive" then return GDrive.new(self.cfg) end
    return Webdav.new{
        url = self.cfg.webdav_url,
        username = self.cfg.webdav_username,
        password = self.cfg.webdav_password,
    }
end

--- 从配置构造本地客户端。
---@param cfg table|nil
---@return LocalClient
function Client.new(cfg)
    return setmetatable({ cfg = cfg or {}, upload_failed = {} }, Client)
end

--- 当前网盘。`off` 显式关闭；空值且填了 WebDAV 地址时按 WebDAV（旧配置）。
--- 写了认不出的值（含已下线的 dropbox）也关闭，不改走 WebDAV。
---@return "webdav"|"gdrive"|nil
function Client:cloudKind()
    local kind = Text.trim(self.cfg.cloud or ""):lower()
    if kind == "off" then return nil end
    if kind == "webdav" or kind == "gdrive" then return kind end
    if kind ~= "" then return nil end
    if Text.trim(self.cfg.webdav_url or "") ~= "" then return "webdav" end
    return nil
end

---@return boolean
function Client:hasCloud()
    return self:cloudKind() ~= nil
end

---@return boolean
function Client:isWebdav()
    return self:cloudKind() == "webdav"
end

---@return string
function Client:webdavPath()
    local path = Text.trimSlashes(Text.trim(self.cfg.webdav_path or "Apps/Books"))
    return path ~= "" and path or "Apps/Books"
end

---@return string
function Client:webdavCacheRoot()
    return Paths.bookDir(SOURCE_ID) .. "/webdav"
end

--- WebDAV 书文件落地目录（打开时按需下载到这里）：配置了本地书库目录就是它，否则落插件缓存。
---@return string
function Client:webdavBookRoot()
    return localRoot(self) or self:webdavCacheRoot()
end

--- 是否 WebDAV 书。配置 WebDAV 后，按绝对路径登记的书（未收编 / 书库外打开）仍是纯本地书。
---@param stable_id string
---@return boolean
function Client.isRemote(stable_id)
    return remoteRelativePath(stable_id) ~= nil
end

--- 是否已配置本地路径。
---@return boolean
function Client:configured()
    return self:hasCloud() or Text.stripWhitespace(self.cfg.path) ~= ""
end

--- 本地路径是否有效（存在、是目录、且不在插件数据目录内）。网盘只校验自己的凭据。
---@return boolean, string|nil
function Client:validatePath()
    local kind = self:cloudKind()
    if kind == "webdav" then
        if not tostring(self.cfg.webdav_url or ""):match("^https?://") then
            return false, _("WebDAV 地址必须以 http:// 或 https:// 开头")
        end
        return true
    end
    if kind == "gdrive" then
        if Text.trim(self.cfg.gdrive_token or "") == "" then
            return false, _("未配置 Google Drive 刷新令牌")
        end
        local client_id, secret = Text.trim(self.cfg.gdrive_client or ""):match("^([^:]+):(.+)$")
        if not client_id or client_id == "" or not secret or secret == "" then
            return false, _("Google 客户端格式应为 ID:密钥")
        end
        return true
    end
    local path = rootPath(self.cfg)
    if path == "" then
        return false, _("未配置本地路径")
    end
    local moon_root = Paths.root()
    if path == moon_root or path:sub(1, #moon_root + 1) == moon_root .. "/" then
        return false, _("书库目录不能是插件数据目录")
    end
    local attr = lfs.attributes(path)
    if not attr then
        return false, _("路径不存在: ") .. path
    end
    if attr.mode ~= "directory" then
        return false, _("路径不是目录: ") .. path
    end
    return true
end

--- 封面缓存路径（已存在才返回；绝不现提取，coverRequest 在 UI 线程同步调用）。
---@param stable_id string
---@return string|nil
function Client:cachedCoverPath(stable_id)
    local path = coverPath(stable_id)
    if lfs.attributes(path, "mode") == "file" then
        return path
    end
    return nil
end

Client.importAsync = Scan.importAsync
Client.moveBook = Scan.moveBook
Client.indexOneAsync = Scan.indexOneAsync
Client.scanAsync = Scan.scanAsync

Client.scanWebdavAsync = LocalWebdav.scanWebdavAsync
Client.openWebdavAsync = LocalWebdav.openWebdavAsync
Client.pushBookAsync = LocalWebdav.pushBookAsync
Client.importWebdavAsync = LocalWebdav.importWebdavAsync
Client.testWebdavAsync = LocalWebdav.testWebdavAsync

Client.getProgressAsync = RemoteData.getProgressAsync
Client.putProgressAsync = RemoteData.putProgressAsync
Client.pushStatsAsync = RemoteData.pushStatsAsync
Client.pullStatsAsync = RemoteData.pullStatsAsync
Client.pushNotesAsync = RemoteData.pushNotesAsync
Client.pullNotesAsync = RemoteData.pullNotesAsync

return Client
