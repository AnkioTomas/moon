--[[--
通用图片组件：icons/ 相对名 / 网络 URL（长期磁盘缓存）

  Image.widget{
    src = "settings.svg",     -- icons/ 相对名
    -- src = "https://...",   -- 网络 URL → 缓存命中直接显；未命中先占位，
                              -- 下载完经 Flight 只刷新该占位组件
    headers = { Authorization = "Bearer …" },  -- 仅网络请求
    width = n, height = n,
    alpha = true,
    fallback = "…",   -- 未就绪/失败时显示文案；空/省略则空白占位
  }

  Image.ensureAsync(url, headers)
  Image.cachedPath(url)
  Image.resolve(src)
  Image.abortPending()

下载直写磁盘，禁止整图进内存。单飞/waiter 见 moon.flight。
--]]

local Geom = require("ui/geometry")
local ImageWidget = require("ui/widget/imagewidget")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local http = require("socket.http")
pcall(require, "ssl.https")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local md5 = require("ffi/sha2").md5
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
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

local function cacheBase(url)
    Paths.ensureLayout()
    return Paths.imageDir() .. "/" .. md5(url)
end

local function mergeHeaders(extra)
    local headers = {
        ["Accept"] = "*/*",
        ["User-Agent"] = socketutil.USER_AGENT,
        ["Connection"] = "close",
    }
    if type(extra) == "table" then
        for k, v in pairs(extra) do
            if v ~= nil then
                headers[k] = v
            end
        end
    end
    return headers
end

local function decodeFile(path, w, h, alpha)
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

--- 已缓存的网络图路径；未命中返回 nil
function Image.cachedPath(url)
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
    local code
    socketutil:set_timeout(10, 30)
    local ok_req, req_err = pcall(function()
        code = socket.skip(1, http.request({
            url = url,
            method = "GET",
            headers = mergeHeaders(headers),
            sink = ltn12.sink.file(file),
        }))
    end)
    socketutil:reset_timeout()
    if not ok_req then
        pcall(function() file:close() end)
        pcall(os.remove, tmp)
        return nil, tostring(req_err)
    end
    if code == socketutil.TIMEOUT_CODE
        or code == socketutil.SSL_HANDSHAKE_CODE
        or code == socketutil.SINK_TIMEOUT_CODE then
        pcall(os.remove, tmp)
        return nil, "timeout"
    end
    local status = tonumber(code)
    if not status or status < 200 or status >= 300 then
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

--- 未缓存网络图：固定尺寸占位，下载完只替换自身。
local function pendingBox(url, headers, w, h, alpha, fb)
    logger.dbg("book image pending", url, w, h, fb)
    local child
    if type(fb) == "string" and fb ~= "" then
        child = UI.text{ text = fb, size = 12 }
    else
        child = Widget:new{ dimen = Geom:new{ w = w, h = h } }
    end

    local box = WidgetContainer:new{
        dimen = Geom:new{ w = w, h = h },
        align = "center",
        child,
    }

    local unwatch = Flight.watch(url, function(path)
        logger.dbg("book image apply", url, path)
        local img = decodeFile(path, w, h, alpha)
        if not img then
            return
        end
        if box[1] and box[1].free then
            box[1]:free()
        end
        box[1] = img
        UIManager:setDirty(box, "ui")
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

--- 构建 ImageWidget；网络未缓存时返回自更新占位。
-- @param opts table|nil
-- @param opts.src string|nil  icons/ 相对名或 http(s) URL
-- @param opts.headers table|nil  仅网络请求
-- @param opts.width number|nil  默认 UI.iconSz()
-- @param opts.height number|nil  默认与 width 相同
-- @param opts.alpha boolean|nil  默认 true
-- @param opts.fallback string|nil  未就绪文案；非空显示文案，空/省略则空白占位
-- @return widget|nil
function Image.widget(opts)
    opts = opts or {}
    local src = opts.src
    local headers = opts.headers
    local w = opts.width or UI.iconSz()
    local h = opts.height or w
    local alpha = opts.alpha
    if alpha == nil then
        alpha = true
    end
    local fb = opts.fallback

    local path = Image.resolve(src)
    if path then
        local img = decodeFile(path, w, h, alpha)
        if img then
            logger.dbg("book image widget ready", src, path)
            return img
        end
    end
    if isHttp(src) then
        return pendingBox(src, headers, w, h, alpha, fb)
    end
    logger.dbg("book image widget empty", src, fb)
    if type(fb) == "string" and fb ~= "" then
        return UI.text{ text = fb, size = 12 }
    end
    return nil
end

return Image
