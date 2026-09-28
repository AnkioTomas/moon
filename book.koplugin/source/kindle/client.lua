--[[--
Kindle 源 wire：借道 kindle.koplugin 的模块读 Kindle 书目、准备可读文件。

书目 = Kindle 系统库 /var/local/cc.db（kindle.koplugin 的 ccdb_scanner，只读）；
KFX 转 EPUB / DRM 取钥 = kindle.koplugin 的 cache_manager（同步、可能跑几分钟，只能在子进程调用）。
缓存目录与 kindle.koplugin 共用，两边打开同一本书得到同一个物理路径，
它自己的阅读位置回写 Kindle 也照常生效。

KOReader 加载插件后把各插件目录并入 package.path，所以这里按 kindle.koplugin 的模块名直接 require；
未安装或未启用该插件时 require 失败，本源不可用。

@module koplugin.book.source.kindle.client
--]]

local Client = {}

Client.CC_DB_PATH = "/var/local/cc.db"

---@type boolean|nil
local available

--- kindle.koplugin 已加载且 Kindle 书目库存在。插件增删需重启 KOReader，结果按进程缓存。
---@return boolean
function Client.available()
    if available == nil then
        available = require("libs/libkoreader-lfs").attributes(Client.CC_DB_PATH, "mode") == "file"
            and pcall(require, "lua/ccdb_scanner")
            and pcall(require, "lua/cache_manager")
    end
    return available
end

--- kindle.koplugin 的设置（缓存目录跟它一致）。
---@return table
local function kindleSettings()
    local settings = {}
    for k, v in pairs(G_reader_settings:readSetting("kindle_plugin") or {}) do
        settings[k] = v
    end
    if not settings.cache_dir then
        settings.cache_dir = require("datastorage"):getFullDataDir() .. "/cache/kindle.koplugin"
    end
    return settings
end

---@return table
local function cacheManager()
    local settings = kindleSettings()
    local helper = require("lua/helper_client"):new()
    helper:setSettings(settings)
    local manager = require("lua/cache_manager"):new(helper)
    manager:setSettings(settings)
    return manager
end

--- 读 Kindle 书目。条目字段见 kindle.koplugin ccdb_scanner（id="cc:<uuid>"、open_mode=convert/direct/blocked）。
---@return table[]|nil books
---@return string|nil err
function Client.scan()
    return require("lua/ccdb_scanner"):new():scan()
end

--- 已可直接打开的物理路径：direct 即原文件；convert 仅当转换缓存新鲜；其余 nil。
---@param kbook table Kindle 书目条目
---@return string|nil
function Client.readyPath(kbook)
    if kbook.open_mode == "direct" then
        return kbook.source_path
    end
    if kbook.open_mode ~= "convert" then
        return nil
    end
    local fresh, epub_path = cacheManager():isFresh(kbook)
    return fresh and epub_path or nil
end

--- 转换 / 取钥并返回 EPUB 路径。阻塞，只能在 workers.job 子进程里调用。
---@param kbook table
---@return string|nil path
---@return string|nil code kindle.koplugin 的失败码（drm / conversion_failed …）
function Client.prepare(kbook)
    return cacheManager():ensureCachedEpub(kbook)
end

--- kindle.koplugin 失败码 → 它自带的提示文案。
---@param code string|nil
---@return string
function Client.reasonText(code)
    return require("lua/virtual_library").getBlockedReasonText(nil, { block_reason = code })
end

return Client
