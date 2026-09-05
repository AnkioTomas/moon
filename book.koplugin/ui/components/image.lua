--[[--
通用图片组件：网络 URL（长期磁盘缓存）/ 本地路径

布局（定宽高占位，异步替换内容）：
  +----------+     +----------+
  | fallback | →   |  image   |
  |  文案    |     |          |   border 时画框
  +----------+     +----------+

  Image.widget{
    src = "https://...",   -- 网络 URL → 缓存命中直接显；未命中先占位，
                           -- 下载完只刷新该占位组件
    -- src = "/abs/path.png"  -- 本地文件
    headers = { Authorization = "Bearer …" },  -- 仅网络请求
    width = n, height = n,
    alpha = true,
    border = false,           -- 是否画边框
    fallback = "…",           -- 未就绪/失败文案；空/省略则空白占位
    show_parent = desk,       -- 窗口级父；嵌套 setDirty 必须靠它
    on_ready = function(path) end,  -- 可选：下载并替换完成后
  }

UI 图标请用 ui.components.icon（Material Icons 字体），不要走本组件。

  Image.abortPending()
  Image.fetchAsync(url, headers, function(path, err) end)  -- 只下载不显示（刮削封面）

下载直写磁盘；下载与解码均异步，不在主线程解码图片。
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
local logger = require("utils.log")
local UI = require("ui.components.bookui")
local Paths = require("utils.paths")
local Request = require("http.request")
local JSON = require("json")
local Job = require("workers.job")

local Image = {}

local EXTS = { ".jpg", ".jpeg", ".png", ".webp", ".gif", ".svg" }
local dl_seq = 0
local decode_seq = 0
local jobs = {}
local download_queue = {}
local download_active_count = 0
local download_paused = false
local failed_urls = {}
local decode_queue = {}
local decode_active = {}
local decode_active_count = 0
local MAX_DOWNLOAD_JOBS = 5
local MAX_DECODE_JOBS = 5
local FAILED_URL_TTL = 5 * 60

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
    return Paths.imageRootDir() .. "/" .. md5(url)
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

--- 同步解码为定尺寸 BB，再包成 ImageWidget。
---@param path string
---@param w number
---@param h number
---@param alpha boolean|nil
---@return table|nil
local function decodeSync(path, w, h, alpha)
    local RenderImage = require("ui/renderimage")
    local bb = RenderImage:renderImageFile(path, false, w, h)
    if not bb then
        return nil
    end
    return ImageWidget:new{
        image = bb,
        image_disposable = true,
        scale_factor = 1,
        alpha = alpha and true or false,
    }
end

--- 子进程解码中间文件路径。
---@return string
local function decodeTmpPath()
    decode_seq = decode_seq + 1
    return Paths.cacheDir() .. "/image-decode-" .. tostring(os.time()) .. "-" .. tostring(decode_seq) .. ".bin"
end

--- 从序列化字符串重建 BB / ImageWidget（主进程，轻量）。
---@param data string|nil
---@param alpha boolean|nil
---@return table|nil
local function unmarshal(data, alpha)
    if type(data) ~= "string" or data == "" then
        return nil
    end
    local nl = data:find("\n", 1, true)
    if not nl then
        return nil
    end
    local ok, head = pcall(JSON.decode, data:sub(1, nl - 1))
    if not ok or type(head) ~= "table" then
        return nil
    end
    local pixels = data:sub(nl + 1)
    if #pixels ~= head.stride * head.h then
        return nil
    end
    local ok_bb, bb = pcall(Blitbuffer.fromstring, head.w, head.h, head.fmt, pixels, head.stride)
    if not ok_bb or not bb then
        return nil
    end
    return ImageWidget:new{
        image = bb,
        image_disposable = true,
        scale_factor = 1,
        alpha = alpha and true or false,
    }
end

--- 读取文件全部内容；失败返回 nil。
---@param path string|nil
---@return string|nil
local function readFile(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local data = f:read("*a")
    f:close()
    return data
end


--- 读回并删除子进程写出的中间文件。
---@param raw string|nil
---@return string|nil
local function readDecodedFile(raw)
    local data = readFile(raw)
    os.remove(raw)
    return data
end

--- 有限并发启动图片解码，避免批量 fork 卡 UI，也不会让整页封面逐张等待。
local function pumpDecodeQueue()
    if decode_active_count >= MAX_DECODE_JOBS then return end
    while decode_queue[1] and decode_queue[1].cancelled do
        table.remove(decode_queue, 1)
    end
    local task = table.remove(decode_queue, 1)
    if not task then return end
    decode_active[task] = true
    decode_active_count = decode_active_count + 1
    Paths.ensureCacheRoot()
    local tmp = decodeTmpPath()
    task.tmp = tmp

    local function finish(widget)
        if not decode_active[task] then return end
        decode_active[task] = nil
        decode_active_count = decode_active_count - 1
        task.job = nil
        task.done = true
        if not task.cancelled then task.cb(widget) end
        pumpDecodeQueue()
    end

    task.job = Job.run(function()
        local RenderImage = require("ui/renderimage")
        local Blitbuffer = require("ffi/blitbuffer")
        local bb = RenderImage:renderImageFile(task.path, false, task.w, task.h)
        if not bb then
            return nil
        end
        local header = JSON.encode({
            w = tonumber(bb.w),
            h = tonumber(bb.h),
            stride = tonumber(bb.stride),
            fmt = bb:getType(),
        })
        local pixels = Blitbuffer.tostring(bb)
        bb:free()
        local f = io.open(tmp, "wb")
        if f then
            f:write(header, "\n", pixels)
            f:close()
        end
        return tmp
    end, {
        name = "image.decode",
        on_done = function(result)
            finish(result and unmarshal(readDecodedFile(result), task.alpha) or nil)
        end,
        on_failed = function()
            os.remove(tmp)
            finish(nil)
        end,
        on_cancelled = function()
            os.remove(tmp)
            finish(nil)
        end,
    })
end

--- 在子进程解码图片为定尺寸 BB，序列化落中间文件后回主进程。
--- 解码任务有限并发，避免一页图片无限 fork，也避免串行加载拖慢封面。
---@param path string
---@param w number
---@param h number
---@param alpha boolean|nil
---@param cb fun(widget: table|nil)
---@return table 可 abort 的 job
local function decodeAsync(path, w, h, alpha, cb)
    local task = {
        path = path,
        w = w,
        h = h,
        alpha = alpha,
        cb = cb,
    }
    decode_queue[#decode_queue + 1] = task
    pumpDecodeQueue()
    return {
        abort = function()
            if task.done or task.cancelled then return end
            task.cancelled = true
            if decode_active[task] and task.job then
                task.job:abort()
            else
                pumpDecodeQueue()
            end
        end,
    }
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

--- 有限并发下载到缓存；成功回调最终路径（已缓存则下一拍直接回调）。
---@param url string
---@param headers table|nil
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }
local pumpDownloadQueue

--- 收口下载：失败清理临时文件，取消任务不回调。
---@param task table
---@param path string|nil
---@param err any
local function completeDownload(task, path, err)
    if not path then
        pcall(os.remove, task.tmp)
    end
    pumpDownloadQueue()
    if not task.cancelled then
        task.cb(path, err)
    end
end

---@param task table
---@param ok boolean
---@param err any
local function finishDownload(task, ok, err)
    if task.settled then return end
    task.settled = true
    if task.running then
        task.running = false
        download_active_count = download_active_count - 1
    end
    if task.cancelled then
        return completeDownload(task)
    end
    if not ok then
        if tostring(err):find("HTTP 404", 1, true) then
            failed_urls[task.url] = os.time() + FAILED_URL_TTL
        end
        return completeDownload(task, nil, err or "download failed")
    end
    local attr = lfs.attributes(task.tmp)
    if not attr or not attr.size or attr.size < 1 then
        return completeDownload(task, nil, "empty")
    end
    local ext = sniffExt(task.tmp)
    if not ext then
        local path = task.url:match("^[^%?#]+") or task.url
        local from_url = path:match("%.([%w]+)$")
        if from_url then
            from_url = "." .. from_url:lower()
            for _, candidate in ipairs(EXTS) do
                if candidate == from_url then
                    ext = candidate
                    break
                end
            end
        end
    end
    if not ext then
        return completeDownload(task, nil, "unknown type")
    end
    local final = task.base .. ext
    if not os.rename(task.tmp, final) then
        return completeDownload(task, nil, "rename failed")
    end
    completeDownload(task, final)
end

pumpDownloadQueue = function()
    if download_paused then return end
    while download_active_count < MAX_DOWNLOAD_JOBS do
        while download_queue[1] and download_queue[1].cancelled do
            table.remove(download_queue, 1)
        end
        local task = table.remove(download_queue, 1)
        if not task then return end
        task.running = true
        download_active_count = download_active_count + 1
        task.request = Request.download({
            url = task.url,
            method = "GET",
            headers = task.headers,
            timeout = 60,
            connect_timeout = 30,
        }, task.tmp, function(ok, err)
            finishDownload(task, ok, err)
        end)
    end
end

function Image.fetchAsync(url, headers, cb)
    local cached = cachedPath(url)
    if cached then
        UIManager:nextTick(function() cb(cached) end)
        return { cancel = function() end }
    end
    local retry_at = failed_urls[url]
    if retry_at and retry_at > os.time() then
        UIManager:nextTick(function() cb(nil, "HTTP 404") end)
        return { cancel = function() end }
    end
    failed_urls[url] = nil
    Paths.ensureImageRoot()
    local base = cacheBase(url)
    dl_seq = dl_seq + 1
    local tmp = string.format("%s.%d.part", base, dl_seq)
    local task = {
        url = url,
        headers = headers,
        cb = cb,
        base = base,
        tmp = tmp,
    }
    download_queue[#download_queue + 1] = task
    pumpDownloadQueue()
    return {
        cancel = function()
            if task.settled or task.cancelled then return end
            task.cancelled = true
            task.settled = true
            if task.running then
                task.running = false
                download_active_count = download_active_count - 1
                if task.request then task.request.cancel() end
            end
            pcall(os.remove, tmp)
            pumpDownloadQueue()
        end,
    }
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
    download_paused = true
    for i = 1, #list do
        list[i].cancel()
    end
    download_paused = false
    pumpDownloadQueue()
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

--- 同步解码并呈现（子进程内锁屏离屏渲染用）。
---@param path string|nil
---@param w number
---@param h number
---@param alpha boolean|nil
---@param border boolean|nil
---@param fb any
---@return table
local function presentSync(path, w, h, alpha, border, fb)
    local inner_w, inner_h = w, h
    if border then
        local line = UI.line()
        inner_w = math.max(1, w - line * 2)
        inner_h = math.max(1, h - line * 2)
    end
    local img = path and decodeSync(path, inner_w, inner_h, alpha)
    if img then
        return frame(img, w, h, border)
    end
    return placeholder(w, h, fb, border)
end

--- 通用异步图片框：定尺寸占位，下载/解码完成后只替换自身。
---@param src string|nil
---@param headers table|nil
---@param w number
---@param h number
---@param alpha boolean|nil
---@param border boolean|nil
---@param fb any
---@param show_parent table|nil
---@param on_ready fun(path: string)|nil
---@return table
local function asyncBox(src, headers, w, h, alpha, border, fb, show_parent, on_ready)
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

    local inner_w, inner_h = w, h
    if border then
        local line = UI.line()
        inner_w = math.max(1, w - line * 2)
        inner_h = math.max(1, h - line * 2)
    end

    local alive = true
    local job
    local decode_job

    --- 解码完成后替换占位内容。
    ---@param widget table|nil
    ---@param path string|nil
    local function apply(widget, path)
        if not alive or not widget then
            return
        end
        if box[1] and box[1].free then
            box[1]:free()
        end
        box[1] = frame(widget, w, h, border)
        requestPaint(box)
        if type(on_ready) == "function" then
            pcall(on_ready, path)
        end
    end

    --- 异步解码本地图片并替换占位；句柄存在 decode_job 里供 free 时中止。
    ---@param path string 本地图片路径
    local function decode(path)
        decode_job = decodeAsync(path, inner_w, inner_h, alpha, function(widget)
            decode_job = nil
            apply(widget, path)
        end)
    end

    --- 释放占位并取消在飞下载/解码。
    ---@param full any
    function box:free(full)
        alive = false
        if job then
            job.cancel()
            forgetJob(job)
            job = nil
        end
        if decode_job then
            decode_job.abort()
            decode_job = nil
        end
        WidgetContainer.free(self, full)
    end

    local path = resolve(src)
    if path then
        decode(path)
        return box
    end
    if isHttp(src) then
        job = Image.fetchAsync(src, headers, function(path, err)
            forgetJob(job)
            job = nil
            if path then
                decode(path)
            else
                logger.warn("book image async failed", src, err)
            end
        end)
        rememberJob(job)
    end
    return box
end

--- 构建图片 widget。默认异步解码；opts.sync=true 时同步解码（锁屏离屏渲染）。
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
    local border = opts.border and true or false
    local fb = opts.fallback
    local show_parent = opts.show_parent
    local on_ready = opts.on_ready

    if opts.sync then
        local path = resolve(src)
        if path then
            local ready = presentSync(path, w, h, alpha, border, fb)
            if ready then
                if type(on_ready) == "function" then
                    UIManager:nextTick(function()
                        pcall(on_ready, path)
                    end)
                end
                return ready
            end
        end
        return placeholder(w, h, fb, border)
    end

    return asyncBox(src, headers, w, h, alpha, border, fb, show_parent, on_ready)
end

return Image
