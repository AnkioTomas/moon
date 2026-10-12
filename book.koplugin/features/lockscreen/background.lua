--[[--
锁屏图片资源管理。

本地背景（自定义 / 封面 / 文件夹）在这里解析。必应 / 摸鱼日报图归 online，
这里只读路径、问 ensureImage。

@module koplugin.book.features.lockscreen.background
--]]

local lfs = require("libs/libkoreader-lfs")
local Image = require("utils.image")
local Paths = require("utils.paths")
local MoonSettings = require("utils.settings")
local Layout = require("features.lockscreen.layout")
local _ = require("gettext")

local M = {}

--- 返回本地日期；每日资源和组合缓存共用此时钟。
---@return string YYYY-MM-DD
function M.dayKey()
    local day = os.date("%Y-%m-%d")
    ---@cast day string
    return day
end

--- 只做文件层检查；在线图由 online 校验文件头，合成时解码失败再经 invalidate 重下。
---@param path string|nil
---@return boolean
local function fileOk(path)
    if type(path) ~= "string" or path == "" then return false end
    local attr = lfs.attributes(path)
    return attr ~= nil and attr.mode == "file" and (attr.size or 0) > 8
end

--- 解析资源描述中的路径；path 可以是字符串或无参函数。
---@param asset table
---@return string|nil
function M.resolve(asset)
    if type(asset.path) == "function" then return asset.path() end
    return asset.path
end

local asset_cache
--- 返回锁屏资源的统一缓存表。
---
--- 每日标记和文件夹选择都放在同一个动态表中；新增资源不需要再改设置
--- 模块登记一个新的顶层键。
---@return table
local function assetCache()
    if asset_cache then return asset_cache end
    local settings = MoonSettings.get("features.lockscreen")
    if type(settings.lock_screen_asset_cache) ~= "table" then
        settings.lock_screen_asset_cache = {}
    end
    asset_cache = settings.lock_screen_asset_cache
    return asset_cache
end

--- 返回当前阅读书籍的本地封面。
---@return string|nil
local function coverPath()
    local book = require("features.lockscreen.components.current").book()
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
        if Image.suffix(name) then
            local path = FOLDER_DIR .. "/" .. name
            if fileOk(path) then files[#files + 1] = path end
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
    local day = M.dayKey()
    local entry = cache.folder
    if type(entry) == "table" and entry.day == day and fileOk(entry.path) then
        return entry.path
    end
    local files = folderFiles()
    if not files or #files == 0 then return nil end
    local pick = files[(os.time() % #files) + 1]
    cache.folder = { day = day, path = pick }
    MoonSettings.save("features.lockscreen")
    return pick
end

local BACKGROUNDS = {
    bing = {
        id = "bing",
        label = _("必应壁纸"),
        path = function() return require("online.bing"):imageFile() end,
        endpoint = "bing",
        network = true,
    },
    custom = {
        id = "custom",
        label = _("自定义"),
        path = function() return Paths.screensaverDir() .. "/custom.png" end,
    },
    cover = { id = "cover", label = _("当前阅读书籍封面"), path = coverPath },
    folder = { id = "folder", label = _("文件夹壁纸"), path = folderPick },
    none = { id = "none", label = _("无") },
}

local BACKGROUND_IDS = { "custom", "bing", "cover", "folder", "none" }

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

--- 背景的显示名。
---@param mode string|nil
---@return string
function M.label(mode)
    return M.background(mode).label
end

--- 背景的设置页选项，顺序由 BACKGROUND_IDS 决定。
---@return {text: string, value: string}[]
function M.options()
    local options = {}
    for _idx, id in ipairs(BACKGROUND_IDS) do
        local background = BACKGROUNDS[id]
        options[#options + 1] = { text = background.label, value = id }
    end
    return options
end

--- 设置页副标题：告诉用户自定义图和文件夹壁纸该放哪里。
---@param mode string
---@return string|nil 其余背景无提示
function M.hint(mode)
    if mode == "custom" then
        local w, h = Layout.portraitSize()
        return string.format(".moon/screensaver/custom.png · %d × %d", w, h)
    end
    return mode == "folder" and ".moon/screensaver/wallpapers/" or nil
end

--- 在线图看 online 是否已拿到今天的文件；本地资源没有过期。
---@param asset table
---@return boolean
function M.isFresh(asset)
    if not asset.endpoint then return true end
    return require("online." .. asset.endpoint):imageReady()
end

--- 丢掉损坏的在线图，让下一次 ensure 重下。
---@param asset table
function M.invalidate(asset)
    if not asset.endpoint then return end
    require("online." .. asset.endpoint):invalidateImage()
end

--- 准备任意资源；在线图交给 online.ensureImage。
---@param asset table
---@param cb fun(path: string|nil, err: string|nil)
---@return table|nil
function M.ensure(asset, cb)
    if asset.id == "none" then
        cb(nil)
        return nil
    end
    if asset.endpoint then
        return require("online." .. asset.endpoint):ensureImage(cb)
    end
    local path = M.resolve(asset)
    cb(fileOk(path) and path or nil)
    return nil
end

return M
