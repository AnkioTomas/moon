--[[--
封面缓存与安全 ImageWidget 构造（pcall，坏图不崩）

@module koplugin.book.cover
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local Cover = {}

local function safeName(filename)
    return (filename or "unknown"):gsub("[^%w%._%-]+", "_")
end

function Cover.pathFor(plugin, filename)
    return plugin:coverCacheDir() .. "/" .. safeName(filename) .. ".cover"
end

function Cover.ensure(api, plugin, filename)
    if not filename or filename == "" then
        return nil
    end
    local path = Cover.pathFor(plugin, filename)
    local attr = lfs.attributes(path)
    if attr and attr.mode == "file" and attr.size and attr.size > 64 then
        return path
    end
    if not api or not api.configured or not api:configured() then
        return nil
    end
    local ok, err = api:downloadCover(filename, path)
    if not ok then
        logger.dbg("book cover download failed", filename, err)
        return nil
    end
    return path
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
                face = Font:getFace("xx_smallinfofont", 12),
                max_width = w - 8,
                fgcolor = Blitbuffer.gray(0.35),
            },
        },
    }
end

function Cover.widget(path, w, h, title)
    if path and lfs.attributes(path, "mode") == "file" then
        local ok, img = pcall(function()
            local ImageWidget = require("ui/widget/imagewidget")
            local widget = ImageWidget:new{
                file = path,
                width = w - 2,
                height = h - 2,
                scale_factor = 0,
                alpha = false,
            }
            -- 提前渲染：坏图在这里炸，而不是 paintTo
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
