--[[--
通用图片组件：网络 URL（长期磁盘缓存）/ 本地路径

  Image.widget{
    src = "https://...",   -- 网络 URL → 缓存命中直接显；未命中先占位，
                           -- 下载完只刷新该占位组件
    -- src = "/abs/path.png"  -- 本地文件
    headers = { Authorization = "Bearer …" },  -- 仅网络请求
    width = n, height = n,
    alpha = true,
    fit = "fill",             -- "fill" | "letterbox"（封面：按框解码，禁止原图进内存）
    border = false,           -- letterbox 封面边框
    fallback = "…",           -- 未就绪/失败文案；空/省略则空白占位
    show_parent = desk,       -- 窗口级父；嵌套 setDirty 必须靠它
    on_ready = function(path) end,  -- 可选：下载并替换完成后
  }

UI 图标请用 ui.components.icon（Material Icons 字体），不要走本组件。

  Image.abortPending()
  Image.fetchAsync(url, headers, function(path, err) end)  -- 只下载不显示（刮削封面）

下载直写磁盘，网络图用 KOReader Turbo 事件循环。
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local ImageWidget = require("ui/widget/imagewidget")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local TextWidget = require("ui/widget/textwidget")
local md5 = require("ffi/sha2").md5
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local UI = require("ui.components.bookui")
local Paths = require("utils.paths")
local Request = require("http.request")

local Image = {}

local EXTS = { ".jpg", ".jpeg", ".png", ".webp", ".gif", ".svg" }
local dl_seq = 0
local jobs = {}

--- 登记在飞下载 job（{ cancel }）。
---@param job table|nil
local function rememberJob(job)
    if not job then
        return
    end
    jobs[#jobs + 1] = job
end

--- 从在飞列表移除 job。
---@param job table|nil
local function forgetJob(job)
    if not job then
        return
    end
    for i = #jobs, 1, -1 do
        if jobs[i] == job then
            table.remove(jobs, i)
        end
    end
end

--- 按文件头嗅探图片扩展名。
---@param path string
---@return string|nil
local function sniffExt(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local head = f:read(16) or ""
    f:close()
    if head:sub(1, 3) == "\255\216\255" then return ".jpg" end
    if head:sub(1, 8) == "\137PNG\r\n\26\n" then return ".png" end
    if head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WEBP" then return ".webp" end
    if head:sub(1, 6) == "GIF87a" or head:sub(1, 6) == "GIF89a" then return ".gif" end
    local lower = head:lower()
    if lower:find("<svg", 1, true) or lower:find("<?xml", 1, true) then
        return ".svg"
    end
    return nil
end

--- 是否 HTTP(S) URL。
---@param src any
---@return boolean
local function isHttp(src)
    return type(src) == "string" and (src:match("^https?://") ~= nil)
end

--- 网络图缓存路径前缀（无扩展名）。
---@param url string
---@return string
local function cacheBase(url)
    Paths.ensureLayout("image")
    return Paths.imageDir("image") .. "/" .. md5(url)
end

--- 截断占位文案。
---@param fb any
---@return string
local function truncFallback(fb)
    local label = fb or "?"
    if type(label) ~= "string" then
        label = tostring(label)
    end
    if #label > 24 then
        label = label:sub(1, 24) .. "…"
    end
    return label
end

--- 居中并可选加边框包裹子控件。
---@param child table
---@param w number
---@param h number
---@param border boolean|nil
---@return table
local function frame(child, w, h, border)
    local centered = CenterContainer:new{
        dimen = Geom:new{ w = w, h = h },
        child,
    }
    if not border then
        return centered
    end
    local line = UI.line()
    return FrameContainer:new{
        bordersize = line,
        color = UI.rule(),
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = h },
        centered,
    }
end

--- 空白或文案占位；border 时带边框（封面格子）。
---@param w number
---@param h number
---@param fb any
---@param border boolean|nil
---@return table
local function placeholder(w, h, fb, border)
    w = math.max(1, tonumber(w) or 1)
    h = math.max(1, tonumber(h) or 1)
    local child
    if type(fb) == "string" and fb ~= "" then
        child = TextWidget:new{
            text = truncFallback(fb),
            face = UI.face("xx_smallinfofont", 14),
            max_width = math.max(8, w - UI.sz(8)),
            fgcolor = UI.muted(),
        }
    else
        child = Widget:new{ dimen = Geom:new{ w = w, h = h } }
    end
    return frame(child, w, h, border)
end

--- 按 fit 模式解码文件；letterbox 禁止整图进内存。
---@param path string
---@param w number
---@param h number
---@param alpha boolean|nil
---@param fit string|nil
---@return table|nil
local function decodeFile(path, w, h, alpha, fit)
    local letterbox = fit == "letterbox"
    local ok, img = pcall(function()
        if letterbox then
            local RenderImage = require("ui/renderimage")
            local bb = RenderImage:renderImageFile(path, false, w, h)
            if not bb then
                error("renderImageFile failed")
            end
            return ImageWidget:new{
                image = bb,
                image_disposable = true,
                scale_factor = 1,
                alpha = alpha and true or false,
            }
        end
        return ImageWidget:new{
            file = path,
            width = w,
            height = h,
            alpha = alpha,
        }
    end)
    if ok and img then
        return img
    end
    logger.warn(letterbox and "book image letterbox failed" or "book image decode failed", path, img)
    return nil
end

--- 已缓存的网络图路径；未命中返回 nil。
---@param url string
---@return string|nil
local function cachedPath(url)
    if type(url) ~= "string" or url == "" then
        return nil
    end
    local base = cacheBase(url)
    for _, ext in ipairs(EXTS) do
        local path = base .. ext
        local attr = lfs.attributes(path)
        if attr and attr.mode == "file" and attr.size and attr.size > 0 then
            return path
        end
    end
    return nil
end

--- 异步下载到缓存；成功回调最终路径（已缓存则下一拍直接回调）。
---@param url string
---@param headers table|nil
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }
function Image.fetchAsync(url, headers, cb)
    local cached = cachedPath(url)
    if cached then
        UIManager:nextTick(function()
            cb(cached)
        end)
        return { cancel = function() end }
    end
    local base = cacheBase(url)
    dl_seq = dl_seq + 1
    local tmp = string.format("%s.%d.part", base, dl_seq)
    return Request.download({
        url = url,
        method = "GET",
        headers = headers,
        timeout = 60,
    }, tmp, function(ok, err)
        if not ok then
            pcall(os.remove, tmp)
            cb(nil, err or "download failed")
            return
        end
        local attr = lfs.attributes(tmp)
        if not attr or not attr.size or attr.size < 1 then
            pcall(os.remove, tmp)
            cb(nil, "empty")
            return
        end
        local ext = sniffExt(tmp)
        if not ext then
            local path = url:match("^[^%?#]+") or url
            local from_url = path:match("%.([%w]+)$")
            if from_url then
                from_url = "." .. from_url:lower()
                for _, e in ipairs(EXTS) do
                    if e == from_url then
                        ext = e
                        break
                    end
                end
            end
        end
        if not ext then
            pcall(os.remove, tmp)
            cb(nil, "unknown type")
            return
        end
        local final = base .. ext
        pcall(os.remove, final)
        if not os.rename(tmp, final) then
            pcall(os.remove, tmp)
            cb(nil, "rename failed")
            return
        end
        cb(final)
    end)
end

--- 解析为可读路径。HTTP 查缓存；绝对路径直接用；其余相对插件根。
---@param src string
---@return string|nil
local function resolve(src)
    if type(src) ~= "string" or src == "" then
        return nil
    end
    if isHttp(src) then
        return cachedPath(src)
    end
    if lfs.attributes(src, "mode") == "file" then
        return src
    end
    local path = UI.pluginRoot() .. src
    if lfs.attributes(path, "mode") == "file" then
        return path
    end
    return nil
end

--- 取消在飞下载（桌面关闭 / 清缓存）。
function Image.abortPending()
    local list = jobs
    jobs = {}
    for i = 1, #list do
        list[i].cancel()
    end
end

--- 嵌套占位不是 window-level widget；必须脏 show_parent。
--- WidgetContainer 不会把 dimen 写成屏幕绝对坐标，必须靠 paintTo 记下 _screen。
---@param box table
local function requestPaint(box)
    local host = box.show_parent
    if not host then
        host = UIManager:getTopmostVisibleWidget()
    end
    if not host then
        host = "all"
    end
    local region = box._screen
    if region then
        UIManager:setDirty(host, function()
            return "ui", box._screen
        end)
    else
        -- 尚未 paint（同步缓存命中等）：只能脏整窗，禁止用相对 dimen 瞎刷
        UIManager:setDirty(host, "ui")
    end
end

--- 解码并呈现图片，失败则占位。
---@param path string|nil
---@param w number
---@param h number
---@param alpha boolean|nil
---@param fit string|nil
---@param border boolean|nil
---@param fb any
---@return table
local function present(path, w, h, alpha, fit, border, fb)
    local inner_w, inner_h = w, h
    if border then
        local line = UI.line()
        inner_w = math.max(1, w - line * 2)
        inner_h = math.max(1, h - line * 2)
    end
    local img = path and decodeFile(path, inner_w, inner_h, alpha, fit)
    if img then
        return frame(img, w, h, border)
    end
    return placeholder(w, h, fb, border)
end

--- 未缓存网络图：固定尺寸占位，下载完只替换自身。
---@param url string
---@param headers table|nil
---@param w number
---@param h number
---@param alpha boolean|nil
---@param fit string|nil
---@param border boolean|nil
---@param fb any
---@param show_parent table|nil
---@param on_ready fun(path: string)|nil
---@return table
local function pendingBox(url, headers, w, h, alpha, fit, border, fb, show_parent, on_ready)
    local box = WidgetContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = w, h = h },
        align = "center",
        show_parent = show_parent,
        placeholder(w, h, fb, border),
    }

    --- 记录屏幕绝对位置；勿写回 dimen.x/y（WidgetContainer:paintTo 会再加一次）。
    ---@param bb any
    ---@param x number
    ---@param y number
    function box:paintTo(bb, x, y)
        self._screen = Geom:new{ x = x, y = y, w = self.dimen.w, h = self.dimen.h }
        WidgetContainer.paintTo(self, bb, x, y)
    end

    local alive = true
    local job

    --- 下载完成后替换占位内容。
    ---@param path string|nil
    local function apply(path)
        if not alive or not path then
            return
        end
        local ok, next_w = pcall(present, path, w, h, alpha, fit, border, fb)
        if not ok then
            logger.warn("book image apply boom", url, next_w)
            return
        end
        if box[1] and box[1].free then
            box[1]:free()
        end
        box[1] = next_w
        requestPaint(box)
        if type(on_ready) == "function" then
            pcall(on_ready, path)
        end
    end

    --- 释放占位并取消在飞下载。
    ---@param full any
    function box:free(full)
        alive = false
        if job then
            job.cancel()
            forgetJob(job)
            job = nil
        end
        WidgetContainer.free(self, full)
    end

    job = Image.fetchAsync(url, headers, function(path, err)
        forgetJob(job)
        job = nil
        if path then
            apply(path)
        else
            logger.warn("book image async failed", url, err)
        end
    end)
    rememberJob(job)
    return box
end

--- 构建图片 widget；网络未缓存时返回自更新占位。
---@param opts table|nil
---@return table
function Image.widget(opts)
    opts = opts or {}
    local src = opts.src
    local headers = opts.headers
    local w = math.max(1, tonumber(opts.width) or UI.iconSz())
    local h = math.max(1, tonumber(opts.height) or w)
    local alpha = opts.alpha
    if alpha == nil then
        alpha = true
    end
    local fit = opts.fit or "fill"
    local border = opts.border and true or false
    local fb = opts.fallback
    local show_parent = opts.show_parent
    local on_ready = opts.on_ready

    local path = resolve(src)
    if path then
        local ready = present(path, w, h, alpha, fit, border, fb)
        if ready then
            if type(on_ready) == "function" then
                -- 同步命中：下一拍回调，避免构建期重入
                UIManager:nextTick(function()
                    pcall(on_ready, path)
                end)
            end
            return ready
        end
    end
    if isHttp(src) then
        return pendingBox(src, headers, w, h, alpha, fit, border, fb, show_parent, on_ready)
    end
    return placeholder(w, h, fb, border)
end

return Image
