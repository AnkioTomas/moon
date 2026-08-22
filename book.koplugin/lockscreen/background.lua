--[[--
锁屏图片资源管理。

本模块只处理通用资源生命周期：路径解析、图片校验、每日下载、失败重试。
具体主体通过 asset 描述资源，不在这里为某个主体写特例。

@module koplugin.book.lockscreen.background
--]]

local lfs = require("libs/libkoreader-lfs")
local Request = require("http.request")
local Paths = require("utils.paths")
local MoonSettings = require("utils.settings")
local Layout = require("lockscreen.layout")

local M = {}

local IMAGE_EXTS = {
    png = true,
    jpg = true,
    jpeg = true,
    webp = true,
}

local FIXED_PATHS = {
    custom = "/custom.png",
    bing = "/bing.jpg",
}

--- 只做文件层检查；网络资源还需要经过 isValidImage 的解码检查。
---@param path string|nil
---@return boolean
local function fileOk(path)
    if type(path) ~= "string" or path == "" then return false end
    local attr = lfs.attributes(path)
    return attr ~= nil and attr.mode == "file" and (attr.size or 0) > 8
end

--- 真实解码图片，拒绝 HTML、JSON 和损坏的图片文件。
---@param path string|nil
---@return boolean
function M.isValidImage(path)
    if not fileOk(path) then return false end
    local RenderImage = require("ui/renderimage")
    local decoded, image = pcall(RenderImage.renderImageFile, RenderImage, path, false, 1, 1)
    if not decoded or not image then return false end
    if type(image.free) == "function" then pcall(image.free, image) end
    return true
end

--- 解析资源描述中的路径；path 可以是字符串或无参函数。
---@param asset table|nil
---@return string|nil
function M.resolve(asset)
    if type(asset) ~= "table" then return nil end
    if type(asset.path) == "function" then return asset.path() end
    return asset.path
end

--- 构造每日更新资源。主体只需提供 id、路径和请求函数。
---@param opts table
---@return table
function M.daily(opts)
    local id = assert(opts.id)
    return {
        id = id,
        path = assert(opts.path),
        request = assert(opts.request),
        daily = true,
        network = true,
        direct = opts.direct == true,
    }
end

--- 返回锁屏资源的统一缓存表。
---
--- 每日标记和文件夹选择都放在同一个动态表中；新增资源不需要再改设置
--- 模块登记一个新的顶层键。
---@return table
local asset_cache
local function assetCache()
    if asset_cache then return asset_cache end
    local settings = MoonSettings.get()
    if type(settings.lock_screen_asset_cache) ~= "table" then
        settings.lock_screen_asset_cache = {}
    end
    asset_cache = settings.lock_screen_asset_cache
    return asset_cache
end

--- 返回当前阅读书籍的本地封面。
---@return string|nil
local function coverPath()
    local book = require("lockscreen.components.current").book()
    local path = book and book.cover
    return fileOk(path) and path or nil
end

--- 文件夹壁纸目录。
local FOLDER_DIR = Paths.screensaverDir() .. "/wallpapers"

local folder_cache = {}

--- 目录未变化时复用已排序的图片路径；修改目录后自动重新扫描。
---@return table|nil
local function folderFiles()
    local attr = lfs.attributes(FOLDER_DIR)
    if not attr or attr.mode ~= "directory" then
        folder_cache = {}
        return nil
    end
    local signature = attr.modification or attr.change or attr.size or attr
    if folder_cache.signature == signature and folder_cache.files then
        return folder_cache.files
    end

    local files = {}
    for name in lfs.dir(FOLDER_DIR) do
        if name ~= "." and name ~= ".." then
            local ext = name:match("%.([^.]+)$")
            if ext and IMAGE_EXTS[ext:lower()] then
                local path = FOLDER_DIR .. "/" .. name
                if fileOk(path) then files[#files + 1] = path end
            end
        end
    end
    table.sort(files)
    folder_cache = { signature = signature, files = files }
    return files
end

--- 扫描文件夹并按日复用一张稳定图片。
---@return string|nil
local function folderPick()
    local cache = assetCache()
    local day = Layout.dayKey()
    local entry = cache.folder
    if type(entry) == "table" and entry.day == day and fileOk(entry.path) then
        return entry.path
    end
    local files = folderFiles()
    if not files or #files == 0 then return nil end
    local pick = files[(os.time() % #files) + 1]
    cache.folder = { day = day, path = pick }
    MoonSettings.save()
    return pick
end

local BACKGROUNDS = {
    bing = M.daily{
        id = "bing",
        path = function() return Paths.screensaverDir() .. FIXED_PATHS.bing end,
        request = function()
            return {
                url = "https://api.ankio.net/bing",
                method = "GET",
                allow_redirects = true,
                timeout = 60,
            }
        end,
    },
    custom = {
        id = "custom",
        path = function() return Paths.screensaverDir() .. FIXED_PATHS.custom end,
    },
    cover = { id = "cover", path = coverPath, refresh_on_resume = true },
    folder = { id = "folder", path = folderPick },
    none = { id = "none" },
}

--- 判断背景设置值是否合法；主体资源不属于背景设置项。
---@param mode string|nil
---@return boolean
function M.validMode(mode)
    return BACKGROUNDS[mode] ~= nil
end

--- 返回用户选择的背景资源；非法值回退到必应。
---@param mode string|nil
---@return table
function M.background(mode)
    return BACKGROUNDS[mode] or BACKGROUNDS.bing
end

--- 判断每日资源是否已经拿到今天的有效图片。
---@param asset table|nil
---@return boolean
function M.isFresh(asset)
    if type(asset) ~= "table" or not asset.daily then return true end
    local cache = assetCache()
    local entry = cache[asset.id]
    return type(entry) == "table" and entry.day == Layout.dayKey()
        and M.isValidImage(M.resolve(asset))
end

--- 清除资源日期标记，让下一次准备重新尝试下载。
---@param asset table|nil
---@return nil
function M.invalidate(asset)
    if type(asset) ~= "table" or not asset.daily then return end
    local cache = assetCache()
    if cache[asset.id] ~= nil then
        cache[asset.id] = nil
        MoonSettings.save()
    end
end

--- 下载每日图片；成功才更新日期标记，失败时保留旧图并继续重试。
---@param asset table
---@param cb fun(path: string|nil, err: string|nil)
---@return table|nil
local function ensureDaily(asset, cb)
    local path = M.resolve(asset)
    local day = Layout.dayKey()
    if not path then
        cb(nil, asset.id .. " background path unavailable")
        return nil
    end
    if M.isFresh(asset) then
        cb(path)
        return nil
    end

    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        local valid = M.isValidImage(path)
        cb(valid and path or nil, valid and nil or asset.id .. " background unavailable")
        return nil
    end

    Paths.ensureScreensaverDir()
    local cancelled = false
    local tmp = path .. ".part"
    local request_job = Request.download(asset.request(), tmp, function(ok)
        if cancelled then
            os.remove(tmp)
            return
        end
        if ok and M.isValidImage(tmp) and os.rename(tmp, path)
                and M.isValidImage(path) then
            local cache = assetCache()
            cache[asset.id] = { day = day }
            MoonSettings.save()
            cb(path)
            return
        end

        os.remove(tmp)
        M.invalidate(asset)
        if M.isValidImage(path) then
            cb(path)
        else
            cb(nil, asset.id .. " background download failed")
        end
    end)
    return {
        cancel = function()
            cancelled = true
            if request_job and request_job.cancel then request_job.cancel() end
        end,
    }
end

--- 准备任意资源；每日下载和本地资源共用同一入口。
---@param asset table|nil
---@param cb fun(path: string|nil, err: string|nil)
---@return table|nil
function M.ensure(asset, cb)
    if type(asset) ~= "table" or asset.id == "none" then
        cb(nil)
        return nil
    end
    if asset.daily then return ensureDaily(asset, cb) end
    local path = M.resolve(asset)
    cb(fileOk(path) and path or nil)
    return nil
end

return M
