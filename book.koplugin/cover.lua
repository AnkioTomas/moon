--[[--
封面缓存与安全 ImageWidget 构造。
build 路径只用 cachedPath；ensure / ensureAsync 负责下载。

@module koplugin.book.cover
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local UI = require("bookui")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local Cover = {}

local function safeName(filename)
    return (filename or "unknown"):gsub("[^%w%._%-]+", "_")
end

local function isImagePath(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local head = f:read(16) or ""
    f:close()
    if head:sub(1, 3) == "\255\216\255" then return true end
    if head:sub(1, 8) == "\137PNG\r\n\26\n" then return true end
    if head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WEBP" then return true end
    if head:sub(1, 6) == "GIF87a" or head:sub(1, 6) == "GIF89a" then return true end
    return false
end

function Cover.pathFor(plugin, filename)
    return plugin:coverCacheDir() .. "/" .. safeName(filename)
end

--- 只查本地缓存，不发起网络请求
function Cover.cachedPath(plugin, filename)
    if not filename or filename == "" or not plugin then
        return nil
    end
    local base = Cover.pathFor(plugin, filename)
    for _, ext in ipairs({ ".jpg", ".jpeg", ".png", ".webp", ".gif", "" }) do
        local path = base .. ext
        local attr = lfs.attributes(path)
        if attr and attr.mode == "file" and attr.size and attr.size > 64 then
            if isImagePath(path) then
                return path
            end
            pcall(os.remove, path)
        end
    end
    return nil
end

function Cover.ensure(api, plugin, filename)
    local cached = Cover.cachedPath(plugin, filename)
    if cached then
        return cached
    end
    if not filename or filename == "" then
        return nil
    end
    if not api or not api.configured or not api:configured() then
        return nil
    end
    local base = Cover.pathFor(plugin, filename)
    local ok, final_or_err = api:downloadCover(filename, base)
    if not ok then
        logger.warn("book cover download failed", filename, final_or_err)
        return nil
    end
    if type(final_or_err) == "string"
        and lfs.attributes(final_or_err, "mode") == "file"
        and isImagePath(final_or_err) then
        return final_or_err
    end
    return nil
end

--- 后台下载；已有缓存则立刻 callback(path)
function Cover.ensureAsync(api, plugin, filename, callback)
    local cached = Cover.cachedPath(plugin, filename)
    if cached then
        if callback then callback(cached) end
        return
    end
    UIManager:scheduleIn(0, function()
        local path = Cover.ensure(api, plugin, filename)
        if callback then callback(path) end
    end)
end

function Cover.placeholder(w, h, title)
    local label = title or "?"
    if #label > 18 then
        label = label:sub(1, 18) .. "…"
    end
    return FrameContainer:new{
        bordersize = 1,
        color = Blitbuffer.gray(0.6),
        padding = 0,
        margin = 0,
        background = Blitbuffer.gray(0.92),
        dimen = Geom:new{ w = w, h = h },
        CenterContainer:new{
            dimen = Geom:new{ w = w, h = h },
            TextWidget:new{
                text = label,
                face = UI.face("xx_smallinfofont", 14),
                max_width = w - 8,
                fgcolor = Blitbuffer.gray(0.35),
            },
        },
    }
end

function Cover.widget(path, w, h, title)
    if path and lfs.attributes(path, "mode") == "file" and isImagePath(path) then
        local ok, img = pcall(function()
            local RenderImage = require("ui/renderimage")
            local ImageWidget = require("ui/widget/imagewidget")
            local bb = RenderImage:renderImageFile(path, false)
            if not bb then
                error("renderImageFile failed")
            end
            local widget = ImageWidget:new{
                image = bb,
                image_disposable = true,
                width = w - 2,
                height = h - 2,
                scale_factor = 0,
                alpha = false,
            }
            if widget._render then
                widget:_render()
            end
            return widget
        end)
        if ok and img then
            return FrameContainer:new{
                bordersize = 1,
                color = Blitbuffer.gray(0.55),
                padding = 0,
                margin = 0,
                dimen = Geom:new{ w = w, h = h },
                img,
            }
        end
        logger.warn("book cover widget failed", path)
    end
    return Cover.placeholder(w, h, title)
end

return Cover
