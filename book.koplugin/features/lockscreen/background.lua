--[[--
锁屏图片资源管理。

本地背景（自定义 / 封面 / 文件夹）在这里解析；海报墙自绘。必应 / 摸鱼日报 / 今日报纸图归 online，
这里只读路径、问 ensureImage。整屏铺底的都是背景，主体组件只画在背景之上。

@module koplugin.book.features.lockscreen.background
--]]

local lfs = require("libs/libkoreader-lfs")
local Image = require("utils.image")
local Paths = require("utils.paths")
local MoonSettings = require("utils.settings")
local logger = require("utils.log")
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
    if not path then return false end
    local attr = lfs.attributes(path)
    return attr ~= nil and attr.mode == "file" and (attr.size or 0) > 8
end

--- 解析资源描述中的路径；path 是无参函数，没有 path 的资源（none）返回 nil。
---@param asset table
---@return string|nil
function M.resolve(asset)
    return asset.path and asset.path()
end

--- 用户选的自定义图；没选过用 .moon/screensaver/custom.png（升级前的唯一位置）。
---@return string
function M.customImage()
    return MoonSettings.get("features.lockscreen").lock_screen_custom_image
        or Paths.screensaverDir() .. "/custom.png"
end

--- 用户选的壁纸文件夹；没选过用 .moon/screensaver/wallpapers（升级前的唯一位置）。
---@return string
function M.folder()
    return MoonSettings.get("features.lockscreen").lock_screen_folder
        or Paths.screensaverDir() .. "/wallpapers"
end

--- 返回当前阅读书籍的本地封面。
---@return string|nil
local function coverPath()
    local book = require("features.lockscreen.components.current").book()
    local path = book and book.cover
    return fileOk(path) and path or nil
end

local folder_cache = {}

--- 目录及其修改时间未变时复用已排序的图片路径。
---@param dir string
---@return string[]
local function folderFiles(dir)
    local modification = lfs.attributes(dir, "modification")
    if not modification then return {} end
    if folder_cache.dir == dir and folder_cache.modification == modification then
        return folder_cache.files
    end
    local files = {}
    for name in lfs.dir(dir) do
        local path = dir .. "/" .. name
        if Image.suffix(name) and fileOk(path) then files[#files + 1] = path end
    end
    table.sort(files)
    folder_cache = { dir = dir, modification = modification, files = files }
    return files
end

--- 每次锁屏换一张：按 lock_cycles 轮换，不落盘。唤醒后 +1，下次合成取下一张。
---@return string|nil
local function folderPick()
    local files = folderFiles(M.folder())
    if #files == 0 then return nil end
    local cycle = require("features.lockscreen.cycle").lock_cycles
    return files[(cycle % #files) + 1]
end

-- 背景描述：path 给图（contain 整图缩进，缺省铺满裁切），blocks 给自绘铺底，
-- endpoint 是 online 的在线图，cache_key 是 path 之外让组合图失效的内容摘要。
local BACKGROUNDS = {
    bing = {
        id = "bing",
        label = _("必应壁纸"),
        path = function() return require("online.bing"):imageFile() end,
        endpoint = "bing",
        network = true,
    },
    myrl = {
        id = "myrl",
        label = _("摸鱼日报"),
        path = function() return require("online.myrl"):imageFile() end,
        endpoint = "myrl",
        network = true,
        -- 日报是一整张长图，裁掉就缺内容。
        contain = true,
    },
    paper = {
        id = "paper",
        label = _("今日报纸"),
        path = function() return require("online.paper"):imageFile() end,
        endpoint = "paper",
        network = true,
    },
    danxiangli = {
        id = "danxiangli",
        label = _("单向历"),
        -- 本地自绘日历页；农历读摸鱼日报缓存（ensure 不阻塞），没有就不画。
        blocks = function(rect) return require("features.lockscreen.danxiangli").blocks(rect) end,
        cache_key = function() return require("features.lockscreen.danxiangli").cache_key() end,
    },
    typo = {
        id = "typo",
        label = _("文字海报"),
        blocks = function(rect) return require("features.lockscreen.typo").blocks(rect) end,
        cache_key = function() return require("features.lockscreen.typo").cache_key() end,
    },
    custom = { id = "custom", label = _("自定义"), path = M.customImage },
    cover = {
        id = "cover",
        label = _("当前阅读书籍封面"),
        path = coverPath,
        -- 封面还没落到本地时按 retry 桶重试；有文件后 path 进 dayKey，不再靠次数。
        cache_key = function()
            return require("features.lockscreen.cycle").retry(not coverPath())
        end,
    },
    folder = {
        id = "folder",
        label = _("文件夹壁纸"),
        path = folderPick,
        -- 与 folderPick 同源：锁一次键变一次，唤醒后才会重合成。
        cache_key = function()
            return tostring(require("features.lockscreen.cycle").lock_cycles)
        end,
    },
    poster = {
        id = "poster",
        label = _("海报墙"),
        blocks = function(rect) return require("features.lockscreen.poster").blocks(rect) end,
        cache_key = function() return require("features.lockscreen.poster").cache_key() end,
    },
    insight = {
        id = "insight",
        label = _("统计页面"),
        blocks = function(rect) return require("features.lockscreen.insight").blocks(rect) end,
        cache_key = function() return require("features.lockscreen.insight").cache_key() end,
    },
    none = { id = "none", label = _("无") },
}

local BACKGROUND_IDS = { "custom", "bing", "myrl", "paper", "danxiangli", "cover", "folder", "poster", "typo", "insight", "none" }

--- 第三方锁屏背景。插件未加载完时列表为空，第二返回值为假。
--- 不合格的条目记日志跳过。没提供 backgrounds 的插件直接跳过。
---@return table[] backgrounds, boolean ready
local function externalBackgrounds()
    local External = require("utils.external")
    local items, ready = External.collect("lockscreen")
    local out, seen = {}, {}
    for id in pairs(BACKGROUNDS) do seen[id] = true end
    for _idx, item in ipairs(items) do
        local list = External.try(item.id .. " lockscreen backgrounds", item.mod.backgrounds)
        if type(list) ~= "table" or list.id then
            if list ~= nil then
                logger.error("feature external lockscreen rejected: backgrounds must return a list", item.id)
            end
        else
            for _i, raw in ipairs(list) do
                local id = type(raw) == "table" and External.prefix(item.id, raw.id)
                local paintable = type(raw) == "table"
                    and (type(raw.blocks) == "function" or type(raw.path) == "function")
                local why = not id and "background needs id"
                    or seen[id] and "duplicate id"
                    or type(raw.label) ~= "string" and "background needs label"
                    or not paintable and "background needs blocks or path"
                if why then
                    logger.error("feature external lockscreen rejected", item.id, why)
                else
                    seen[id] = true
                    local label = id .. " blocks"
                    out[#out + 1] = {
                        id = id,
                        label = raw.label,
                        contain = raw.contain == true,
                        network = raw.network == true,
                        cache_key = type(raw.cache_key) == "function" and function()
                            return External.try(id .. " cache_key", raw.cache_key)
                        end or nil,
                        path = type(raw.path) == "function" and function()
                            return External.try(id .. " path", raw.path)
                        end or nil,
                        blocks = type(raw.blocks) == "function" and function(rect)
                            local result = External.try(label, raw.blocks, rect)
                            if type(result) ~= "table" then return {} end
                            return result
                        end or nil,
                    }
                end
            end
        end
    end
    return out, ready
end

--- 按稳定 ID 查找背景。内置优先，再问已加载的第三方插件。
---@param mode string|nil
---@return table|nil
function M.find(mode)
    if BACKGROUNDS[mode] then return BACKGROUNDS[mode] end
    for _idx, asset in ipairs(externalBackgrounds()) do
        if asset.id == mode then return asset end
    end
end

--- 判断背景设置值是否合法。未加载的第三方 id 不算合法，调用方用 resolvable 决定要不要留着。
---@param mode string|nil
---@return boolean
function M.validMode(mode)
    return M.find(mode) ~= nil
end

--- 插件还在加载时，认不出的 id 先留着，避免开机把第三方背景冲成必应。
---@param mode string|nil
---@return boolean
function M.resolvable(mode)
    if M.find(mode) then return true end
    local _, ready = externalBackgrounds()
    return not ready
end

--- 返回用户选择的背景资源；非法值回退到必应。
---@param mode string|nil
---@return table
function M.background(mode)
    return M.find(mode) or BACKGROUNDS.bing
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
        options[#options + 1] = { text = BACKGROUNDS[id].label, value = id }
    end
    for _idx, asset in ipairs(externalBackgrounds()) do
        options[#options + 1] = { text = asset.label, value = asset.id }
    end
    return options
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
    if asset.endpoint then
        return require("online." .. asset.endpoint):ensureImage(cb)
    end
    local path = M.resolve(asset)
    cb(fileOk(path) and path or nil)
    return nil
end

return M
