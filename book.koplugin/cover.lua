--[[--
封面缓存与安全 ImageWidget 构造（pcall，坏图不崩）

@module koplugin.book.cover
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local UI = require("bookui")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local Cover = {}

local function safeName(filename)
    return (filename or "unknown"):gsub("[^%w%._%-]+", "_")
end

function Cover.pathFor(plugin, filename)
    -- 无后缀：downloadCover 会按魔数改成 .jpg/.png
    return plugin:coverCacheDir() .. "/" .. safeName(filename)
end

function Cover.ensure(api, plugin, filename)
    if not filename or filename == "" then
        return nil
    end
    local base = Cover.pathFor(plugin, filename)
    for _, ext in ipairs({ ".jpg", ".jpeg", ".png", ".webp", ".gif", "" }) do
        local path = base .. ext
        local attr = lfs.attributes(path)
        if attr and attr.mode == "file" and attr.size and attr.size > 64 then
            return path
        end
    end
    if not api or not api.configured or not api:configured() then
        return nil
    end
    local ok, final_or_err = api:downloadCover(filename, base)
    if not ok then
        logger.dbg("book cover download failed", filename, final_or_err)
        return nil
    end
    -- downloadCover 成功时第二个返回值是最终路径
    if type(final_or_err) == "string" and lfs.attributes(final_or_err, "mode") == "file" then
        return final_or_err
    end
    for _, ext in ipairs({ ".jpg", ".png", ".webp", ".gif" }) do
        local path = base .. ext
        if lfs.attributes(path, "mode") == "file" then
            return path
        end
    end
    return nil
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
