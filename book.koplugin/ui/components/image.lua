--[[--
通用图片组件：icons/ 相对名 / 网络 URL（长期磁盘缓存）

  Image.widget{
    src = "settings.svg",     -- icons/ 相对名
    -- src = "https://...",   -- 网络 URL → 缓存命中直接显；未命中先占位，
                              -- 下载完经 Flight 只刷新该占位组件
    headers = { Authorization = "Bearer …" },  -- 仅网络请求
    width = n, height = n,
    alpha = true,             -- 图标默认 true；封面用 false
    fit = "fill",             -- "fill" | "letterbox"（封面：按框解码，禁止原图进内存）
    border = false,           -- letterbox 封面边框
    fallback = "…",           -- 未就绪/失败文案；空/省略则空白占位
    show_parent = desk,       -- 窗口级父；嵌套 setDirty 必须靠它
    on_ready = function(path) end,  -- 可选：下载并替换完成后
  }

  Image.ensureAsync(url, headers)
  Image.cachedPath(url)
  Image.resolve(src)
  Image.abortPending()

下载直写磁盘，禁止整图进内存。单飞/waiter 见 moon.flight。
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
local ltn12 = require("ltn12")
local md5 = require("ffi/sha2").md5
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local Header = require("http.header")
local Request = require("http.request")
local UI = require("ui.components.bookui")
local Paths = require("moon.paths")
local Flight = require("moon.flight")

local Image = {}

local EXTS = { ".jpg", ".jpeg", ".png", ".webp", ".gif", ".svg" }

Image._dl_seq = 0

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

local function isHttp(src)
    return type(src) == "string" and (src:match("^https?://") ~= nil)
end

local function cacheBase(url, source_id)
    Paths.ensureLayout(source_id)
    return Paths.imageDir(source_id) .. "/" .. md5(url)
end

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

--- 空白或文案占位；border 时带边框（封面格子）
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

--- 按目标框等比解码（letterbox）；禁止 ImageWidget{file=, scale_factor=0} 整图进内存
local function decodeLetterbox(path, w, h, alpha)
    local ok, img = pcall(function()
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
    end)
    if ok and img then
        logger.dbg("book image letterbox ok", path, w, h)
        return img
    end
    logger.warn("book image letterbox failed", path, img)
    return nil
end

local function decodeFill(path, w, h, alpha)
    local ok, img = pcall(function()
        return ImageWidget:new{
            file = path,
            width = w,
            height = h,
            alpha = alpha,
        }
    end)
    if ok and img then
        logger.dbg("book image decode ok", path, w, h)
        return img
    end
    logger.warn("book image decode failed", path, img)
    return nil
end

local function decodeFile(path, w, h, alpha, fit)
    if fit == "letterbox" then
        return decodeLetterbox(path, w, h, alpha)
    end
    return decodeFill(path, w, h, alpha)
end

local function wrapFrame(child, w, h, border)
    if not child then
        return nil
    end
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

--- 已缓存的网络图路径；未命中返回 nil
function Image.cachedPath(url)
    if type(url) ~= "string" or url == "" then
        return nil
    end
    local base = cacheBase(url)
    for _, ext in ipairs(EXTS) do
        local path = base .. ext
        local attr = lfs.attributes(path)
        if attr and attr.mode == "file" and attr.size and attr.size > 0 then
            logger.dbg("book image cache hit", url, path, attr.size)
            return path
        end
    end
    return nil
end

--- 同步下载到缓存；成功返回最终路径。直写 .part，禁止整图进 RAM。
local function download(url, headers)
    local cached = Image.cachedPath(url)
    if cached then
        return cached
    end
    logger.dbg("book image download start", url)
    local base = cacheBase(url)
    Image._dl_seq = Image._dl_seq + 1
    local tmp = string.format("%s.%d.part", base, Image._dl_seq)
    local file, err = io.open(tmp, "wb")
    if not file then
        return nil, err or "write failed"
    end
    local code, _, req_err = Request.send({
        url = url,
        method = "GET",
        headers = Header.forDownload(headers),
        sink = ltn12.sink.file(file),
    })
    if req_err then
        pcall(function() file:close() end)
        pcall(os.remove, tmp)
        return nil, req_err
    end
    if not Request.ok(code) then
        pcall(os.remove, tmp)
        return nil, "http " .. tostring(code)
    end
    local attr = lfs.attributes(tmp)
    if not attr or not attr.size or attr.size < 1 then
        pcall(os.remove, tmp)
        return nil, "empty"
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
        return nil, "unknown type"
    end
    local final = base .. ext
    pcall(os.remove, final)
    if not os.rename(tmp, final) then
        local rf = io.open(tmp, "rb")
        local wf = rf and io.open(final, "wb")
        if not (rf and wf) then
            if rf then rf:close() end
            pcall(os.remove, tmp)
            return nil, "rename failed"
        end
        while true do
            local chunk = rf:read(65536)
            if not chunk then break end
            wf:write(chunk)
        end
        wf:close()
        rf:close()
        pcall(os.remove, tmp)
    end
    logger.dbg("book image download ok", url, final, attr.size)
    return final
end

--- 解析为可读路径。HTTP 只查缓存；其余一律当 icons/ 相对名。
function Image.resolve(src)
    if type(src) ~= "string" or src == "" then
        return nil
    end
    if isHttp(src) then
        return Image.cachedPath(src)
    end
    local path = UI.iconDir() .. src
    if lfs.attributes(path, "mode") == "file" then
        logger.dbg("book image icon", src, path)
        return path
    end
    logger.dbg("book image resolve miss", src)
    return nil
end

--- 异步确保网络图入缓存；完成后经 Flight 通知该 url 的占位组件。
-- @param url string
-- @param headers table|nil
function Image.ensureAsync(url, headers)
    local cached = Image.cachedPath(url)
    if cached then
        logger.dbg("book image ensure cached", url, cached)
        Flight.resolve(url, cached)
        return
    end
    logger.dbg("book image ensure async", url)
    Flight.run(url, function()
        local path, err = download(url, headers)
        if not path then
            logger.warn("book image async failed", url, err)
        end
        return path, err
    end)
end

--- 取消在飞下载（桌面关闭 / 清缓存）
function Image.abortPending()
    logger.dbg("book image abort pending")
    Flight.abortAll()
end

--- 嵌套占位不是 window-level widget；必须脏 show_parent。
--- WidgetContainer 不会把 dimen 写成屏幕绝对坐标，必须靠 paintTo 记下 _screen。
local function requestPaint(box)
    if not box then
        return
    end
    local host = box.show_parent
    if not host then
        host = UIManager:getTopmostVisibleWidget()
    end
    if not host then
        host = "all"
    end
    local region = box._screen
    if region then
        logger.dbg("book image paint region", region.x, region.y, region.w, region.h)
        UIManager:setDirty(host, function()
            return "ui", box._screen
        end)
    else
        -- 尚未 paint（同步缓存命中等）：只能脏整窗，禁止用相对 dimen 瞎刷
        logger.dbg("book image paint full host")
        UIManager:setDirty(host, "ui")
    end
end

local function present(path, w, h, alpha, fit, border, fb)
    local inner_w, inner_h = w, h
    if border then
        local line = UI.line()
        inner_w = math.max(1, w - line * 2)
        inner_h = math.max(1, h - line * 2)
    end
    local img = path and decodeFile(path, inner_w, inner_h, alpha, fit)
    if img then
        return wrapFrame(img, w, h, border)
    end
    return placeholder(w, h, fb, border)
end

--- 未缓存网络图：固定尺寸占位，下载完只替换自身。
local function pendingBox(url, headers, w, h, alpha, fit, border, fb, show_parent, on_ready)
    logger.dbg("book image pending", url, w, h, fb)
    local box = WidgetContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = w, h = h },
        align = "center",
        show_parent = show_parent,
        placeholder(w, h, fb, border),
    }

    -- 记录屏幕绝对位置；勿写回 dimen.x/y（WidgetContainer:paintTo 会再加一次）
    function box:paintTo(bb, x, y)
        self._screen = Geom:new{ x = x, y = y, w = self.dimen.w, h = self.dimen.h }
        WidgetContainer.paintTo(self, bb, x, y)
    end

    local unwatch = Flight.watch(url, function(path)
        logger.dbg("book image apply", url, path)
        local ok, next_w = pcall(present, path, w, h, alpha, fit, border, fb)
        if not ok then
            logger.warn("book image apply boom", url, next_w)
            return
        end
        if not next_w then
            return
        end
        if box[1] and box[1].free then
            box[1]:free()
        end
        box[1] = next_w
        if not box.show_parent and show_parent then
            box.show_parent = show_parent
        end
        requestPaint(box)
        if type(on_ready) == "function" then
            pcall(on_ready, path)
        end
    end)

    function box:free(full)
        logger.dbg("book image pending free", url)
        if unwatch then
            unwatch()
            unwatch = nil
        end
        WidgetContainer.free(self, full)
    end

    Image.ensureAsync(url, headers)
    return box
end

--- 构建图片 widget；网络未缓存时返回自更新占位。
-- @param opts table|nil
-- @param opts.src string|nil
-- @param opts.headers table|nil
-- @param opts.width number|nil
-- @param opts.height number|nil
-- @param opts.alpha boolean|nil
-- @param opts.fit string|nil  "fill"|"letterbox"
-- @param opts.border boolean|nil
-- @param opts.fallback string|nil
-- @param opts.show_parent widget|nil  窗口级父（Desktop/Dialog）；不传则用 topmost/"all"
-- @param opts.on_ready fun(path: string)|nil  下载并替换完成后回调
-- @return widget|nil
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

    local path = Image.resolve(src)
    if path then
        local ready = present(path, w, h, alpha, fit, border, fb)
        if ready then
            logger.dbg("book image widget ready", src, path)
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
    logger.dbg("book image widget empty", src, fb)
    return placeholder(w, h, fb, border)
end

return Image
