--[[--
第三方插件安装：从 moon-store 返回的 Release zip 资产下载安装，复用 utils.plugin_install
的路径安全、暂存与回滚机制。解压后拒绝覆盖月读核心（book.koplugin），并把真实安装目录名回传给调用方。

@module koplugin.book.features.marketplace.install
--]]

local InstallCore = require("utils.plugin_install")
local Installed = require("features.marketplace.installed")
local Catalog = require("features.marketplace.catalog")
local Paths = require("utils.paths")
local Job = require("workers.job")
local Request = require("http.request")

local MarketInstall = {}

local MAX_ARCHIVE_BYTES = 50 * 1024 * 1024
local busy = false
local job_handle

--- KOReader 插件目录（月读的同级目录）。禁止把第三方插件写进 book.koplugin 内部。
---@param plugin_root string
---@return string|nil
---@return string|nil err
function MarketInstall.pluginsParent(plugin_root)
    if type(plugin_root) ~= "string" or plugin_root == "" then
        return nil, "plugin_root"
    end
    local parent = plugin_root:match("^(.*)/[^/]+$")
    if not parent or parent == "" then return nil, "plugin_root" end
    return parent
end

---@param name any
---@return boolean
function MarketInstall.isReservedName(name)
    return Installed.RESERVED_DIRS[name] == true
end

--- 资产文件名：只允许 zip 基名，不能带路径。
---@param value any
---@return boolean
function MarketInstall.isAssetName(value)
    if type(value) ~= "string" then return false end
    if value:find("[/\\]") or value:find("%.%.") or value:find("%z") then return false end
    return value:lower():match("^[%w][%w._-]*%.zip$") ~= nil
end

---@param url any
---@return boolean
local function isSafeHttpUrl(url)
    if type(url) ~= "string" or url == "" then return false end
    if url:find("[%s%c]") then return false end
    return url:match("^https?://[^/]+/") ~= nil
end

--- 提取插件可用的 Release zip 资产列表（支持单包与多包自选）。
---@param plugin table|nil
---@return table[]
function MarketInstall.assets(plugin)
    if type(plugin) ~= "table" then return {} end
    local out, seen = {}, {}
    local function add(name, url)
        if not isSafeHttpUrl(url) then return end
        local clean_name = MarketInstall.isAssetName(name) and name or nil
        if not clean_name then
            local tail = url:match("/([^/?#]+)$")
            if MarketInstall.isAssetName(tail) then clean_name = tail end
        end
        if not clean_name or seen[url] then return end
        seen[url] = true
        out[#out + 1] = { name = clean_name, url = url }
    end
    if type(plugin.release_assets) == "table" then
        for _idx, row in ipairs(plugin.release_assets) do
            if type(row) == "table" then add(row.name, row.url) end
        end
    end
    if #out == 0 and type(plugin.release_url) == "string" and plugin.release_url ~= "" then
        add(plugin.release_asset, plugin.release_url)
    end
    return out
end

--- 根据插件条目与选定资产生成安装计划。失败返回稳定错误码。
---@param plugin table
---@param asset table
---@param plugin_root string
---@return table|nil plan
---@return string|nil err
function MarketInstall.plan(plugin, asset, plugin_root)
    if type(plugin) ~= "table" then return nil, "no_release" end
    if type(asset) ~= "table" or not MarketInstall.isAssetName(asset.name) then
        return nil, "asset"
    end
    if not isSafeHttpUrl(asset.url) then
        return nil, "unsafe_url"
    end
    local parent, parent_err = MarketInstall.pluginsParent(plugin_root)
    if not parent then return nil, parent_err end
    local meta = type(plugin.meta) == "table" and plugin.meta or nil
    if MarketInstall.isReservedName(plugin.repo)
        or (meta and (MarketInstall.isReservedName(meta.plugin) or MarketInstall.isReservedName(meta.name))) then
        return nil, "reserved"
    end
    local slug = tostring(plugin.repo or plugin.uid or asset.name):gsub("[^%w._-]", "_")
    local version = Catalog.catalogVersion(plugin) or ""
    return {
        url = asset.url,
        asset_name = asset.name,
        version = version,
        tag = tostring(plugin.release_tag or ""),
        title = Catalog.displayTitle(plugin) or asset.name,
        uid = plugin.uid,
        parent = parent,
        archive = "marketplace-" .. slug .. ".zip",
        digest_missing = true,
    }
end

function MarketInstall.cancel()
    if job_handle and job_handle.cancel then job_handle:cancel() end
    job_handle = nil
    busy = false
end

--- 下载并安装。成功回调 cb(true, installed_dir_name)；失败回调 cb(false, err)。
--- 测试可注入 download / run，避免真实拉取或解压外部包。
---@param plan table
---@param opts { download?: function, run?: function, on_progress?: function }|nil
---@param cb fun(ok: boolean, detail: string|nil)
function MarketInstall.perform(plan, opts, cb)
    opts = opts or {}
    if busy then
        cb(false, "busy")
        return
    end
    if type(plan) ~= "table" or not isSafeHttpUrl(plan.url) then
        cb(false, "unsafe_url")
        return
    end
    busy = true
    Paths.ensureDir(Paths.root())
    local archive = Paths.root() .. "/" .. plan.archive
    os.remove(archive)
    os.remove(archive .. ".part")

    local function done(ok, detail)
        os.remove(archive)
        os.remove(archive .. ".part")
        job_handle = nil
        busy = false
        cb(ok, detail)
    end

    local function runInstall()
        if opts.run then
            local ok, detail = opts.run(archive, plan)
            if ok == false or ok == nil then
                done(false, detail or "install_failed")
            else
                done(true, type(detail) == "string" and detail or nil)
            end
            return
        end
        job_handle = Job.run(function()
            local installed, detail = InstallCore.run(archive, plan.parent, nil, {
                verify = function(name)
                    if MarketInstall.isReservedName(name) or not Installed.isPluginDir(name) then
                        return "reserved"
                    end
                end,
            })
            if not installed then error(detail, 0) end
            return detail
        end, {
            name = "marketplace.install",
            kind = "heavy",
            timeout = 120,
            on_done = function(installed_name) done(true, installed_name) end,
            on_failed = function(err) done(false, tostring(err):match("[^\n]*")) end,
        })
    end

    local download = opts.download or function(url, dest, dcb)
        return Request.download({
            url = url,
            timeout = require("http.timeout").net(10),
            allow_redirects = true,
            resume = false,
            max_bytes = MAX_ARCHIVE_BYTES,
            on_progress = opts.on_progress,
        }, dest, dcb)
    end
    job_handle = download(plan.url, archive, function(ok, err)
        if not ok then
            done(false, err or "download")
            return
        end
        runInstall()
    end)
end

return MarketInstall
