--[[--
本地书库客户端（仅异步）：配置、路径与方法装配。

数据流：扫描器只负责把目录状态写进 books 表（增/改/删 + 封面 PNG），
书库/筛选/搜索/最近阅读/统计一律直查数据库，不做内存缓存。
实现按职责拆在同目录：scan（本地目录扫盘 / 导入 / 移动 / 替换）、
webdav（WebDAV 书目同步与远端书操作）、remote_data（.Moon+ 进度 / 统计 / 笔记）、
common（共享原语）。子模块函数首参即 self，在这里装配为方法。

@module koplugin.book.source.local.client
--]]

local lfs = require("libs/libkoreader-lfs")
local Text = require("utils.text")
local _ = require("gettext")
local Webdav = require("http.webdav")
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
---@field dav WebdavClient
---@field _crashed table<string, boolean>|nil
---@field _enriched table<string, boolean>|nil
---@field _stats_seen table<string, string>|nil 统计按书已入库版本（stats_index.json 的内存副本）
local Client = {}

--- cfg 是 utils.settings 的共享表，设置页和远程配置会原地改它；dav 每次按 cfg 现造，不存快照。
Client.__index = function(self, key)
    if key == "dav" then
        local cfg = rawget(self, "cfg")
        return Webdav.new{
            url = cfg.webdav_url,
            username = cfg.webdav_username,
            password = cfg.webdav_password,
        }
    end
    return Client[key]
end

--- 从配置构造本地客户端。
---@param cfg table|nil
---@return LocalClient
function Client.new(cfg)
    return setmetatable({ cfg = cfg or {}, upload_failed = {} }, Client)
end

---@return boolean
function Client:isWebdav()
    return Text.trim(self.cfg.webdav_url or "") ~= ""
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
    return self:isWebdav() or Text.stripWhitespace(self.cfg.path) ~= ""
end

--- 本地路径是否有效（存在、是目录、且不在插件数据目录内）。
---@return boolean, string|nil
function Client:validatePath()
    if self:isWebdav() then
        if not self.cfg.webdav_url:match("^https?://") then
            return false, _("WebDAV 地址必须以 http:// 或 https:// 开头")
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
