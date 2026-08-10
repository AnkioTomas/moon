--[[--
封面：下载缓存 + 按格子尺寸解码缩略图（禁止原图像素进内存）

@module koplugin.book.cover
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local ImageWidget = require("ui/widget/imagewidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local UI = require("bookui")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local Cover = {}

local EXTS = { ".jpg", ".jpeg", ".png", ".webp", ".gif" }

-- 缓存名与书籍文件名一致：保留中文/空格等，只取 basename，禁止路径穿越
local function cacheName(filename)
    filename = tostring(filename or "unknown")
    filename = filename:match("([^/\\]+)$") or filename
    filename = filename:gsub("%.%.", "_"):gsub("%z", "")
    if filename == "" then
        filename = "unknown"
    end
    return filename
end

local function sniffExt(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local head = f:read(16) or ""
    f:close()
    if head:sub(1, 3) == "\255\216\255" then return ".jpg" end
    if head:sub(1, 8) == "\137PNG\r\n\26\n" then return ".png" end
    if head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WEBP" then return ".webp" end
    if head:sub(1, 6) == "GIF87a" or head:sub(1, 6) == "GIF89a" then return ".gif" end
    return nil
end

local function isImagePath(path)
    return sniffExt(path) ~= nil
end

function Cover.pathFor(plugin, filename)
    return plugin:coverCacheDir() .. "/" .. cacheName(filename)
end

function Cover.cachedPath(plugin, filename)
    if not filename or filename == "" or not plugin then
        return nil
    end
    local base = Cover.pathFor(plugin, filename)
    for _, ext in ipairs(EXTS) do
        local path = base .. ext
        local attr = lfs.attributes(path)
        if attr and attr.mode == "file" and attr.size and attr.size > 64 and isImagePath(path) then
            return path
        end
    end
    -- 兼容无后缀旧缓存
    local bare = base
    local attr = lfs.attributes(bare)
    if attr and attr.mode == "file" and attr.size and attr.size > 64 then
        local ext = sniffExt(bare)
        if ext then
            local final = bare .. ext
            pcall(os.rename, bare, final)
            if lfs.attributes(final, "mode") == "file" then
                return final
            end
        else
            pcall(os.remove, bare)
        end
    end
    return nil
end

--- 下载封面到缓存目录；成功返回最终路径
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
    if not plugin or not plugin.coverCacheDir then
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

function Cover.setIdleHandler(fn)
    Cover._idle_handler = fn
    Cover._epoch = (Cover._epoch or 0) + 1
end

--- 桌面关闭时停掉队列，避免回到 FM 后异步回调踩死对象
function Cover.stopAll()
    Cover._queue = {}
    Cover._queued = {}
    Cover._busy = false
    Cover._pending_refresh = false
    Cover._idle_handler = nil
    Cover._epoch = (Cover._epoch or 0) + 1
end

local function scheduleIdleNotify()
    if Cover._idle_scheduled then
        return
    end
    Cover._idle_scheduled = true
    local epoch = Cover._epoch or 0
    UIManager:scheduleIn(0.8, function()
        Cover._idle_scheduled = false
        if epoch ~= (Cover._epoch or 0) then
            return
        end
        if Cover._pending_refresh and Cover._idle_handler then
            Cover._pending_refresh = false
            pcall(Cover._idle_handler)
        end
    end)
end

local function pump()
    Cover._queue = Cover._queue or {}
    local job = table.remove(Cover._queue, 1)
    if not job then
        Cover._busy = false
        scheduleIdleNotify()
        return
    end
    Cover._busy = true
    local epoch = Cover._epoch or 0
    UIManager:scheduleIn(0.02, function()
        if epoch ~= (Cover._epoch or 0) then
            Cover._busy = false
            return
        end
        local ok, path = pcall(Cover.ensure, job.api, job.plugin, job.filename)
        if Cover._queued then
            Cover._queued[job.filename] = nil
        end
        if not ok then
            logger.warn("book cover ensure boom", job.filename, path)
            path = nil
        end
        if path then
            Cover._pending_refresh = true
            logger.info("book cover ready", job.filename)
            if job.callback then
                pcall(job.callback, path)
            end
            scheduleIdleNotify()
        else
            logger.warn("book cover miss", job.filename)
        end
        Cover._busy = false
        pump()
    end)
end

function Cover.ensureAsync(api, plugin, filename, callback)
    if not filename or filename == "" or not plugin then
        return
    end
    if Cover.cachedPath(plugin, filename) then
        return
    end
    Cover._queue = Cover._queue or {}
    Cover._queued = Cover._queued or {}
    if Cover._queued[filename] then
        return
    end
    Cover._queued[filename] = true
    table.insert(Cover._queue, {
        api = api,
        plugin = plugin,
        filename = filename,
        callback = callback,
    })
    if not Cover._busy then
        pump()
    end
end

function Cover.placeholder(w, h, title)
    local label = title or "?"
    -- 按字符粗截，避免中文按字节截断
    if type(label) == "string" and #label > 24 then
        label = label:sub(1, 24) .. "…"
    end
    local border = UI.line()
    return FrameContainer:new{
        bordersize = border,
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
                max_width = math.max(8, w - UI.sz(8)),
                fgcolor = Blitbuffer.gray(0.35),
            },
        },
    }
end

--- 按目标框等比解码并居中（letterbox），禁止拉伸变形。
--- 禁止 ImageWidget{file=, scale_factor=0}：那会先整图进内存，图书馆一页直接 OOM。
function Cover.widget(path, w, h, title)
    w = math.max(1, tonumber(w) or 1)
    h = math.max(1, tonumber(h) or 1)
    if path and lfs.attributes(path, "mode") == "file" and isImagePath(path) then
        local border = UI.line()
        local inner_w = math.max(1, w - border * 2)
        local inner_h = math.max(1, h - border * 2)
        local ok, img = pcall(function()
            local RenderImage = require("ui/renderimage")
            local bb = RenderImage:renderImageFile(path, false, inner_w, inner_h)
            if not bb then
                error("renderImageFile failed")
            end
            -- 用位图自身尺寸；scale_factor=1 不再二次拉伸填满格子
            return ImageWidget:new{
                image = bb,
                image_disposable = true,
                scale_factor = 1,
                alpha = false,
            }
        end)
        if ok and img then
            return FrameContainer:new{
                bordersize = border,
                color = Blitbuffer.gray(0.55),
                padding = 0,
                margin = 0,
                background = Blitbuffer.COLOR_WHITE,
                dimen = Geom:new{ w = w, h = h },
                CenterContainer:new{
                    dimen = Geom:new{ w = w, h = h },
                    img,
                },
            }
        end
        logger.warn("book cover thumbnail failed", path, img)
    end
    return Cover.placeholder(w, h, title)
end

return Cover
